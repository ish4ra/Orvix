// EXPERIMENTAL, NOT WIRED INTO THE APP.
//
// TorrentCheap (torrentcheap.com) has no published third-party API, its
// website signs users in with httpOnly session cookies (email/password or
// Google, with CAPTCHA), and its Terms forbid reverse-engineering the
// service. Orvix therefore ships no network transport for it: this file is
// the provider-side orchestration (validation, task flow, playback checks)
// written against an abstract [TorrentCheapGateway], exercised only by tests
// with a fake gateway.
//
// A real gateway may be added only after TorrentCheap provides, or approves,
// a documented client interface with a non-browser authentication model.
// Do not implement one by replaying the website's internal /api/tasks/*
// requests or by reusing browser cookies. See docs/TORRENTCHEAP_RESEARCH.md.

import 'dart:async';

import 'torrentcheap_hls.dart';
import 'torrentcheap_models.dart';

/// The operations Orvix needs from TorrentCheap. Each one corresponds to a
/// capability observed in the website's own client; none of the request or
/// response formats behind them are confirmed.
abstract class TorrentCheapGateway {
  Future<bool> isConnected();

  /// File list for a magnet before anything is downloaded.
  Future<TorrentCheapMagnetMetadata> fetchMagnetMetadata(String magnet);

  /// Starts a cloud task for the selected file indexes. Returns its id.
  Future<String> createTask(String magnet, List<int> selectedFileIndexes);

  Future<int> activeTaskCount();

  Future<List<TorrentCheapTask>> activeTasks();

  Future<List<TorrentCheapTask>> taskHistory();

  /// [folderId] null means the account's root folder.
  Future<TorrentCheapFolderPage> listFolder(
    String? folderId, {
    String? pageToken,
  });

  Future<TorrentCheapPlaybackSource> resolvePlayback(String fileId);
}

class TorrentCheapService {
  TorrentCheapService({
    TorrentCheapGateway? gateway,
    bool? enabled,
    TorrentCheapHlsProbe? probe,
    this.maxConcurrentTasks = 5,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  })  : _gateway = gateway,
        _enabled = enabled ?? experimentalBuildFlag,
        _probe = probe,
        _clock = clock ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  /// Off unless a developer builds with
  /// `--dart-define=ORVIX_EXPERIMENTAL_TORRENTCHEAP=true`. Even then there is
  /// no production gateway, so the service stays unavailable.
  static const experimentalBuildFlag =
      bool.fromEnvironment('ORVIX_EXPERIMENTAL_TORRENTCHEAP');

  /// Only stream URLs on these hosts are handed to the player.
  static const _trustedHostSuffix = 'torrentcheap.com';

  /// Treat a stream URL as expired this long before its stated expiry, so
  /// mpv does not open a URL that dies during start-up.
  static const _expiryMargin = Duration(seconds: 60);

  /// Per-account active-task limit. 5 was seen on one free account's UI and
  /// is not a documented guarantee.
  final int maxConcurrentTasks;

  final TorrentCheapGateway? _gateway;
  final bool _enabled;
  final TorrentCheapHlsProbe? _probe;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  bool get isAvailable => _enabled && _gateway != null;

  Future<bool> isConnected() async {
    if (!isAvailable) return false;
    return _guard(() => _gateway!.isConnected());
  }

  Future<TorrentCheapMagnetMetadata> lookupMagnet(String magnet) async {
    final gateway = await _connectedGateway();
    final infoHash = normalizedInfoHash(magnet);
    if (infoHash == null) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.invalidMagnet,
        'This is not a valid magnet link.',
      );
    }
    final metadata =
        await _guard(() => gateway.fetchMagnetMetadata(magnet.trim()));
    if (metadata.files.isEmpty) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.provider,
        'TorrentCheap found no files in this magnet.',
      );
    }
    return metadata;
  }

  /// Submits [magnet] with the chosen files. Returns the new task id.
  ///
  /// The active-task check is advisory: it saves a request when the account
  /// is clearly full, but the provider remains the authority.
  Future<String> submitMagnet(
    String magnet,
    TorrentCheapMagnetMetadata metadata,
    Iterable<int> selectedFileIndexes,
  ) async {
    final gateway = await _connectedGateway();
    final infoHash = normalizedInfoHash(magnet);
    if (infoHash == null) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.invalidMagnet,
        'This is not a valid magnet link.',
      );
    }
    if (infoHash != metadata.infoHash.toLowerCase()) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.invalidSelection,
        'The file list belongs to a different magnet.',
      );
    }

    final selection = selectedFileIndexes.toSet().toList()..sort();
    final known = metadata.files.map((f) => f.index).toSet();
    if (selection.isEmpty || !selection.every(known.contains)) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.invalidSelection,
        'Choose at least one file from this torrent.',
      );
    }

    final active = await _guard(gateway.activeTaskCount);
    if (active >= maxConcurrentTasks) {
      throw TorrentCheapException(
        TorrentCheapErrorKind.taskLimitReached,
        'TorrentCheap allows $maxConcurrentTasks active downloads. '
        'Wait for one to finish and try again.',
      );
    }

    final taskId = await _guard(() => gateway.createTask(magnet.trim(), selection));
    if (taskId.trim().isEmpty) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.provider,
        'TorrentCheap did not return a task.',
      );
    }
    return taskId;
  }

  /// A finished task for [infoHash] already in the account, if any. Lets
  /// Orvix reuse a download instead of spending quota on it again.
  Future<TorrentCheapTask?> findCompletedTask(String infoHash) async {
    final gateway = await _connectedGateway();
    final wanted = infoHash.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    final history = await _guard(gateway.taskHistory);
    for (final task in history) {
      if (task.isComplete && task.infoHash?.toLowerCase() == wanted) {
        return task;
      }
    }
    return null;
  }

  /// Current state of [taskId], looking in active tasks first and then in
  /// history (completed tasks move there).
  Future<TorrentCheapTask> taskStatus(String taskId) async {
    final gateway = await _connectedGateway();
    final active = await _guard(gateway.activeTasks);
    for (final task in active) {
      if (task.id == taskId) return task;
    }
    final history = await _guard(gateway.taskHistory);
    for (final task in history) {
      if (task.id == taskId) return task;
    }
    throw const TorrentCheapException(
      TorrentCheapErrorKind.notFound,
      'TorrentCheap no longer lists this download.',
    );
  }

  /// Polls [taskId] until it completes. Fails on provider error, on
  /// [timeout], or when progress has not moved for [stallAfter] polls.
  Future<TorrentCheapTask> waitForCompletion(
    String taskId, {
    Duration pollInterval = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 30),
    int stallAfter = 20,
    void Function(TorrentCheapTask task)? onProgress,
  }) async {
    final deadline = _clock().add(timeout);
    var lastProgress = -1.0;
    var unchangedPolls = 0;

    while (true) {
      final task = await taskStatus(taskId);
      onProgress?.call(task);
      if (task.isComplete) return task;
      if (task.isFailed) {
        throw TorrentCheapException(
          TorrentCheapErrorKind.provider,
          task.message?.trim().isNotEmpty == true
              ? 'TorrentCheap could not download this source: '
                  '${redactForLog(task.message!)}'
              : 'TorrentCheap could not download this source.',
        );
      }

      if (task.progress > lastProgress) {
        lastProgress = task.progress;
        unchangedPolls = 0;
      } else if (++unchangedPolls >= stallAfter) {
        throw const TorrentCheapException(
          TorrentCheapErrorKind.stalled,
          'TorrentCheap has made no progress on this source. It may have no '
          'active peers. Choose another source.',
        );
      }

      if (!_clock().isBefore(deadline)) {
        throw const TorrentCheapException(
          TorrentCheapErrorKind.timeout,
          'TorrentCheap is taking too long to download this source.',
        );
      }
      await _delay(pollInterval);
    }
  }

  /// Every entry in [folderId], following pagination. [maxPages] bounds a
  /// misbehaving transport that never stops returning tokens.
  Future<List<TorrentCheapCloudEntry>> listFolder(
    String? folderId, {
    int maxPages = 50,
  }) async {
    final gateway = await _connectedGateway();
    final entries = <TorrentCheapCloudEntry>[];
    String? token;
    final seenTokens = <String>{};
    for (var page = 0; page < maxPages; page++) {
      final result = await _guard(
        () => gateway.listFolder(folderId, pageToken: token),
      );
      entries.addAll(result.entries);
      token = result.nextPageToken;
      if (token == null || token.isEmpty || !seenTokens.add(token)) break;
    }
    return entries;
  }

  /// The video in [folderId] (searching sub-folders up to [maxDepth]) that
  /// best matches [preferredName], else the largest video.
  Future<TorrentCheapCloudEntry?> findPlayableVideo(
    String? folderId, {
    String? preferredName,
    int maxDepth = 3,
  }) async {
    final videos = <TorrentCheapCloudEntry>[];
    await _collectVideos(folderId, videos, maxDepth, <String>{});
    return pickVideo(videos, preferredName: preferredName);
  }

  Future<void> _collectVideos(
    String? folderId,
    List<TorrentCheapCloudEntry> into,
    int depthLeft,
    Set<String> visited,
  ) async {
    if (!visited.add(folderId ?? '')) return;
    for (final entry in await listFolder(folderId)) {
      if (entry.isVideo) {
        into.add(entry);
      } else if (entry.isFolder && depthLeft > 0) {
        await _collectVideos(entry.id, into, depthLeft - 1, visited);
      }
    }
  }

  static TorrentCheapCloudEntry? pickVideo(
    List<TorrentCheapCloudEntry> videos, {
    String? preferredName,
  }) {
    if (videos.isEmpty) return null;
    final wanted = preferredName?.trim().toLowerCase();
    if (wanted != null && wanted.isNotEmpty) {
      for (final video in videos) {
        if (video.name.toLowerCase() == wanted) return video;
      }
    }
    final sorted = List<TorrentCheapCloudEntry>.of(videos)
      ..sort((a, b) => (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0));
    return sorted.first;
  }

  /// A stream for [fileId] that is safe to give the player: https, on a
  /// TorrentCheap host, and not about to expire. Re-resolves once if the
  /// first answer is already stale. With a probe configured, also confirms
  /// the URL serves an HLS master playlist to this client.
  Future<TorrentCheapPlaybackSource> resolvePlayback(String fileId) async {
    final gateway = await _connectedGateway();
    var source = await _guard(() => gateway.resolvePlayback(fileId));
    if (source.isExpiredAt(_clock(), margin: _expiryMargin)) {
      source = await _guard(() => gateway.resolvePlayback(fileId));
      if (source.isExpiredAt(_clock(), margin: _expiryMargin)) {
        throw const TorrentCheapException(
          TorrentCheapErrorKind.streamExpired,
          'TorrentCheap returned an expired stream link.',
        );
      }
    }
    _checkTrustedStream(source.masterPlaylistUri);
    final probe = _probe;
    if (probe != null) await probe.inspect(source);
    return source;
  }

  static void _checkTrustedStream(Uri uri) {
    final host = uri.host.toLowerCase();
    final trusted =
        host == _trustedHostSuffix || host.endsWith('.$_trustedHostSuffix');
    if (uri.scheme != 'https' || !trusted) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.unsupportedStream,
        'TorrentCheap returned a stream link Orvix will not open.',
      );
    }
  }

  Future<TorrentCheapGateway> _connectedGateway() async {
    if (!isAvailable) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.unavailable,
        'TorrentCheap is not available in this build.',
      );
    }
    final gateway = _gateway!;
    if (!await _guard(gateway.isConnected)) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.notConnected,
        'Connect your TorrentCheap account first.',
      );
    }
    return gateway;
  }

  /// Passes provider exceptions through and turns anything else into a
  /// generic error whose message cannot leak a URL, cookie or magnet.
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on TorrentCheapException {
      rethrow;
    } on TimeoutException {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.timeout,
        'TorrentCheap did not respond in time.',
      );
    } catch (_) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.network,
        'TorrentCheap request failed.',
      );
    }
  }

  static final _btihPattern =
      RegExp(r'xt=urn:btih:([^&\s]+)', caseSensitive: false);
  static final _hexHash = RegExp(r'^[0-9a-fA-F]{40}$');
  static final _base32Hash = RegExp(r'^[A-Za-z2-7]{32}$');

  /// Lower-case hex v1 info hash of [magnet], or null when it is not a
  /// usable magnet link. Base32 hashes are converted to hex.
  static String? normalizedInfoHash(String magnet) {
    final value = magnet.trim();
    if (!value.toLowerCase().startsWith('magnet:?')) return null;
    final match = _btihPattern.firstMatch(value);
    if (match == null) return null;
    final hash = match.group(1)!;
    if (_hexHash.hasMatch(hash)) return hash.toLowerCase();
    if (_base32Hash.hasMatch(hash)) return _base32ToHex(hash.toUpperCase());
    return null;
  }

  static String _base32ToHex(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var bits = 0;
    var value = 0;
    final out = StringBuffer();
    for (final char in input.split('')) {
      value = (value << 5) | alphabet.indexOf(char);
      bits += 5;
      while (bits >= 8) {
        bits -= 8;
        out.write(((value >> bits) & 0xff).toRadixString(16).padLeft(2, '0'));
      }
      value &= (1 << bits) - 1;
    }
    return out.toString();
  }

  static final _magnetPattern =
      RegExp(r'magnet:\?[^\s"]+', caseSensitive: false);
  static final _urlQueryPattern =
      RegExp(r'(https?://[^\s"?#]+)[?#][^\s"]*', caseSensitive: false);
  static final _secretHeaderPattern = RegExp(
    r'((?:cookie|set-cookie|authorization|x-[a-z-]*token)\s*[:=]\s*)[^\r\n,;]+',
    caseSensitive: false,
  );
  static final _streamPathPattern =
      RegExp(r'(/files/video-stream/)[^/\s"]+', caseSensitive: false);

  /// Strips magnets, URL query strings, stream ids and credential headers
  /// from text before it reaches a log or an error message.
  static String redactForLog(String text) {
    return text
        .replaceAll(_magnetPattern, 'magnet:[redacted]')
        .replaceAllMapped(_urlQueryPattern, (m) => '${m.group(1)}?[redacted]')
        .replaceAllMapped(_streamPathPattern, (m) => '${m.group(1)}[redacted]')
        .replaceAllMapped(_secretHeaderPattern, (m) => '${m.group(1)}[redacted]');
  }
}
