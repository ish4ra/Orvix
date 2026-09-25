import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'platform_profile.dart';
import 'source_provider_service.dart';

class LocalTorrentException implements Exception {
  const LocalTorrentException(this.message);
  final String message;

  @override
  String toString() => message;
}

class LocalTorrentHealth {
  const LocalTorrentHealth({
    required this.metadataReady,
    required this.peers,
    required this.connections,
    required this.downloadSpeedBytesPerSecond,
  });

  final bool metadataReady;
  final int peers;
  final int connections;
  final double downloadSpeedBytesPerSecond;

  bool get hasActiveDownload => downloadSpeedBytesPerSecond > 0;

  String get speedLabel {
    final speed = downloadSpeedBytesPerSecond;
    if (speed <= 0) return '0 KB/s';
    if (speed >= 1024 * 1024) {
      return '${(speed / (1024 * 1024)).toStringAsFixed(speed >= 10 * 1024 * 1024 ? 1 : 2)} MB/s';
    }
    return '${(speed / 1024).toStringAsFixed(speed >= 1024 * 100 ? 0 : 1)} KB/s';
  }

  String get summary =>
      'metadata: ${metadataReady ? 'ready' : 'pending'}, '
      'peers: $peers, connections: $connections, speed: $speedLabel';
}

class LocalTorrentProbeResult {
  const LocalTorrentProbeResult({
    required this.playableNow,
    required this.bytesReceived,
    required this.elapsed,
    required this.firstByteLatency,
    required this.peers,
    required this.connections,
    required this.downloadSpeedBytesPerSecond,
    required this.sampleWindowsPassed,
  });

  final bool playableNow;
  final int bytesReceived;
  final Duration elapsed;
  final Duration? firstByteLatency;
  final int peers;
  final int connections;
  final double downloadSpeedBytesPerSecond;
  final int sampleWindowsPassed;

  String get speedLabel {
    final speed = downloadSpeedBytesPerSecond;
    if (speed <= 0) return '0 KB/s';
    if (speed >= 1024 * 1024) {
      return '${(speed / (1024 * 1024)).toStringAsFixed(speed >= 10 * 1024 * 1024 ? 1 : 2)} MB/s';
    }
    return '${(speed / 1024).toStringAsFixed(speed >= 100 * 1024 ? 0 : 1)} KB/s';
  }

  String get label {
    if (!playableNow) return 'No live data';
    final latencyMs = firstByteLatency?.inMilliseconds ?? 99999;
    if (sampleWindowsPassed >= 2 &&
        latencyMs <= 1800 &&
        downloadSpeedBytesPerSecond >= 1500 * 1024) {
      return 'Ready now';
    }
    if (sampleWindowsPassed >= 2 &&
        downloadSpeedBytesPerSecond >= 512 * 1024) {
      return 'Fast swarm';
    }
    if (bytesReceived > 0) return 'Live swarm';
    return 'Slow';
  }

  int get score {
    if (!playableNow) return -1000000000;
    final latencyMs = firstByteLatency?.inMilliseconds ?? 99999;
    var value = 1000000000;
    if (latencyMs <= 500) {
      value += 300000000;
    } else if (latencyMs <= 1200) {
      value += 220000000;
    } else if (latencyMs <= 2500) {
      value += 120000000;
    }
    value += (connections.clamp(0, 100) * 2000000);
    value += (peers.clamp(0, 200) * 500000);
    value +=
        (downloadSpeedBytesPerSecond.clamp(0, 12 * 1024 * 1024) ~/ 1024) *
            5000;
    value += sampleWindowsPassed * 180000000;
    value += bytesReceived.clamp(0, 1536 * 1024) * 100;
    return value;
  }
}

class LocalTorrentService {
  LocalTorrentService._();

  static final LocalTorrentService instance = LocalTorrentService._();

  static const String baseUrl = 'http://127.0.0.1:11470';
  static const String bundledExeName = 'orvix-stream-server.exe';
  static const String bundledMacName = 'orvix-stream-server';
  static const MethodChannel _androidChannel =
      MethodChannel('orvix/torrent_engine');

  /// The Windows build already contains media_kit's ffmpeg/ffprobe tools under
  /// tools\\ffmpeg\\bin. The local stream-server launches ffmpeg/ffprobe by
  /// command name, so prepend that bundled directory to the child PATH instead
  /// of depending on a system-wide FFmpeg installation.
  static Map<String, String> windowsStreamServerEnvironment(
    String appDirPath, {
    Map<String, String>? baseEnvironment,
  }) {
    final environment = Map<String, String>.from(
      baseEnvironment ?? Platform.environment,
    );
    final pathKey = environment.keys.firstWhere(
      (key) => key.toLowerCase() == 'path',
      orElse: () => 'Path',
    );
    final ffmpegBin = '$appDirPath\\tools\\ffmpeg\\bin';
    final currentPath = environment[pathKey]?.trim() ?? '';
    environment[pathKey] =
        currentPath.isEmpty ? ffmpegBin : '$ffmpegBin;$currentPath';
    return environment;
  }

  // Nuvio keeps a small public tracker fallback set in addition to provider
  // trackers. Stremio's server also accepts explicit peer-search sources.
  // Keeping these here makes startup less dependent on one stale addon tracker
  // while DHT/PeX remain enabled in the native engine.
  static const List<String> fallbackTrackers = <String>[
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.torrent.eu.org:451/announce',
  ];

  static String normalizeMagnetForEngine(String magnet) {
    final trimmed = magnet.trim();
    final queryIndex = trimmed.indexOf('?');
    if (queryIndex < 0) return trimmed;

    final prefix = trimmed.substring(0, queryIndex + 1);
    final parts = trimmed.substring(queryIndex + 1).split('&');
    final kept = <String>[];
    for (final part in parts) {
      if (part.isEmpty) continue;
      final rawKey = part.split('=').first;
      String key;
      try {
        key = Uri.decodeQueryComponent(rawKey).toLowerCase();
      } catch (_) {
        key = rawKey.toLowerCase();
      }
      if (key.startsWith('x-orvix-')) continue;
      kept.add(part);
    }
    return '$prefix${kept.join('&')}';
  }

  static List<String> trackerUrlsForMagnet(String magnet) {
    final out = <String>[];
    final seen = <String>{};

    void addTracker(String value) {
      final tracker = value.trim();
      if (tracker.isEmpty) return;
      final key = tracker.toLowerCase();
      if (seen.add(key)) out.add(tracker);
    }

    final queryIndex = magnet.indexOf('?');
    if (queryIndex >= 0) {
      for (final part in magnet.substring(queryIndex + 1).split('&')) {
        if (part.isEmpty) continue;
        final equals = part.indexOf('=');
        final rawKey = equals < 0 ? part : part.substring(0, equals);
        String key;
        try {
          key = Uri.decodeQueryComponent(rawKey).toLowerCase();
        } catch (_) {
          key = rawKey.toLowerCase();
        }
        if (key != 'tr') continue;
        final rawValue = equals < 0 ? '' : part.substring(equals + 1);
        try {
          addTracker(Uri.decodeQueryComponent(rawValue));
        } catch (_) {
          addTracker(rawValue);
        }
      }
    }

    for (final tracker in fallbackTrackers) {
      addTracker(tracker);
    }
    return out;
  }

  Process? _process;
  bool _ownsProcess = false;
  Future<void>? _starting;
  bool _androidProfileConfigured = false;
  String? _currentInfoHash;
  final Set<String> _retainedProbeInfoHashes = <String>{};
  Timer? _probeCleanupTimer;

  Future<String> resolve(
    SourceResult source, {
    void Function(String message)? onProgress,
    bool warmForPlayback = true,
  }) async {
    if (!source.isMagnet) return source.resource;

    final infoHash = _extractInfoHash(source.resource);
    if (infoHash == null) {
      throw const LocalTorrentException(
        'This torrent source did not include a usable BitTorrent info hash.',
      );
    }

    onProgress?.call('Preparing stream…');
    await ensureRunning();

    final fileHint = source.fileNameHint?.trim();
    final engineMagnet = normalizeMagnetForEngine(source.resource);
    final trackerUrls = trackerUrlsForMagnet(engineMagnet);

    // Match Stremio's peer-discovery shape more closely. The magnet itself
    // keeps provider trackers, while peerSearch adds DHT plus a small fallback
    // tracker set. The local stream-server de-duplicates/normalizes these.
    final body = <String, dynamic>{
      'from': engineMagnet,
      'guessFileIdx': true,
      'peerSearch': <String, dynamic>{
        'sources': <String>[
          'dht:$infoHash',
          for (final tracker in trackerUrls) 'tracker:$tracker',
        ],
      },
      if (fileHint != null && fileHint.isNotEmpty)
        'fileMustInclude': <String>[fileHint],
    };

    // Nuvio's P2P lifecycle explicitly detaches the old stream before starting
    // another. Apply the same principle here so repeated source attempts do not
    // accumulate stale torrent sessions in the native server.
    final previousInfoHash = _currentInfoHash;
    if (previousInfoHash != null && previousInfoHash != infoHash) {
      await _removeEngine(previousInfoHash);
      _currentInfoHash = null;
    }

    http.Response response;
    try {
      response = await _createTorrent(body);
    } on TimeoutException {
      throw const LocalTorrentException(
        'The local torrent engine timed out while resolving magnet metadata.',
      );
    } catch (error) {
      throw LocalTorrentException(
        'Could not send the torrent to the local streaming engine: $error',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LocalTorrentException(
        'Local torrent engine returned HTTP ${response.statusCode}.',
      );
    }

    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) payload = decoded;
    } catch (_) {}

    final engineError = payload?['error']?.toString().trim();
    if (engineError != null && engineError.isNotEmpty) {
      throw LocalTorrentException('Local torrent engine: $engineError');
    }

    final guessedFileIndex = _asInt(payload?['guessedFileIdx']);
    final explicitFileIndex = source.torrentFileIndex;
    // Match Stremio's resolved stream: an addon-provided fileIdx is
    // authoritative. Guess only when the stream did not provide one.
    var fileIndex = explicitFileIndex ??
        guessedFileIndex ??
        _asInt(payload?['fileIdx']) ??
        -1;

    // Windows ships the Orvix stream-server extension. If upstream-style
    // creation still returns -1, ask the running engine to resolve the same
    // auto-selected file that playback would use, preferably with the addon
    // filename hint. AI Sinhala needs a real non-negative index so it can
    // extract subtitles from the exact episode instead of guessing.
    if (fileIndex < 0 && Platform.isWindows) {
      onProgress?.call('Resolving exact episode file…');
      final resolved = await _resolveOrvixFileIndex(
        infoHash,
        fileHint: fileHint,
      );
      if (resolved != null) {
        fileIndex = resolved;
      }
    }

    // If an older/non-Orvix engine cannot resolve the index, playback keeps
    // compatibility with -1. Preserve the filename filter in the URL so the
    // stream route and any later resolver use the same selection rule.
    final streamUrl = _buildStreamUrl(
      infoHash: infoHash,
      fileIndex: fileIndex,
      fileHint: fileHint,
    );

    _currentInfoHash = infoHash;
    _retainedProbeInfoHashes.remove(infoHash);

    // Android TV players tend to fail faster than the torrent swarm can warm
    // up on marginal sources. Prime a small HTTP range into the stream-server
    // cache before handing the URL to the player. This mirrors TorrServer's
    // preload idea without changing the player or downloading the whole file.
    if (warmForPlayback &&
        Platform.isAndroid &&
        PlatformProfile.isAndroidTv) {
      onProgress?.call('Connecting peers and pre-buffering…');
      await _primeLocalStream(
        streamUrl,
        targetBytes: 1024 * 1024,
        timeout: const Duration(seconds: 10),
      );
    } else if (warmForPlayback && Platform.isWindows) {
      // Windows MPV is much happier when the localhost torrent endpoint has
      // produced real bytes before libmpv opens it. Subtitle-only probes do
      // not need a 2 MiB video warm-up, so they skip this delay entirely.
      onProgress?.call('Connecting peers and warming Windows playback…');
      await _primeLocalStream(
        streamUrl,
        targetBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 12),
      );
    }

    onProgress?.call(
      warmForPlayback ? 'Opening player…' : 'Exact torrent file ready…',
    );
    return streamUrl;
  }

  Future<String> proxyRemoteUrl(
    String remoteUrl, {
    String? fileNameHint,
  }) async {
    final remote = Uri.tryParse(remoteUrl);
    if (remote == null ||
        !(remote.scheme == 'http' || remote.scheme == 'https')) {
      throw const LocalTorrentException(
        'The cloud stream URL is not a valid HTTP/HTTPS media URL.',
      );
    }

    // Windows cloud/debrid playback deliberately uses the same modified
    // localhost stream-server process as Free P2P. This keeps playback,
    // ffprobe and ffmpeg on one native transport instead of sending AI
    // subtitle discovery through a separate Dart-only bridge.
    await ensureRunning();

    final capabilities = await _orvixCapabilities();
    if (capabilities?['remoteEmbeddedSubtitles'] != true ||
        _asInt(capabilities?['remoteSubtitleRouteVersion']) != 1) {
      throw const LocalTorrentException(
        'The bundled Orvix stream engine does not support remote embedded subtitles.',
      );
    }

    final proxy = Uri.parse('$baseUrl/proxy/').replace(
      queryParameters: <String, String>{
        'd': remote.toString(),
      },
    );

    // A filename hint is intentionally not appended to the target URL: signed
    // debrid URLs must remain byte-for-byte intact. Require the native proxy
    // to return actual bytes before handing it to libmpv; capability-only
    // checks are not enough for provider-specific signed URLs.
    if (!await _remoteProxyHasMediaBytes(proxy)) {
      throw const LocalTorrentException(
        'The Orvix stream engine could not read media bytes from this cloud source.',
      );
    }
    return proxy.toString();
  }

  Future<List<int>> extractAudioWindow({
    required String videoUrl,
    required Duration start,
    required Duration duration,
  }) async {
    if (!Platform.isWindows) {
      throw const LocalTorrentException(
        'Native stream-engine audio extraction is currently available on Windows only.',
      );
    }

    final source = Uri.tryParse(videoUrl);
    if (source == null ||
        !(source.scheme == 'http' || source.scheme == 'https')) {
      throw const LocalTorrentException(
        'AI audio extraction requires a readable HTTP/HTTPS media URL.',
      );
    }

    await ensureRunning();
    final capabilities = await _orvixCapabilities();
    if (capabilities?['audioWindowExtraction'] != true ||
        _asInt(capabilities?['audioWindowRouteVersion']) != 1) {
      throw const LocalTorrentException(
        'The bundled Orvix stream engine does not support crash-isolated audio extraction.',
      );
    }

    final startMs = start.inMilliseconds < 0 ? 0 : start.inMilliseconds;
    final durationMs = duration.inMilliseconds.clamp(1000, 30000).toInt();
    final uri = Uri.parse('$baseUrl/orvix/audio-window');

    final client = http.Client();
    try {
      final response = await client
          .post(
            uri,
            headers: const {
              'Accept': 'audio/aac',
              'Content-Type': 'application/json',
              'Cache-Control': 'no-store',
            },
            body: jsonEncode(<String, dynamic>{
              'videoUrl': videoUrl,
              'startMs': startMs,
              'durationMs': durationMs,
            }),
          )
          .timeout(const Duration(seconds: 50));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final raw = utf8
            .decode(response.bodyBytes, allowMalformed: true)
            .trim()
            .replaceAll(RegExp(r'[\r\n]+'), ' ');
        final detail = raw.length > 320 ? raw.substring(0, 320) : raw;
        throw LocalTorrentException(
          detail.isEmpty
              ? 'Orvix stream-engine audio extraction returned HTTP ${response.statusCode}.'
              : 'Orvix stream-engine audio extraction failed: $detail',
        );
      }

      final bytes = response.bodyBytes;
      if (bytes.length < 256) {
        throw const LocalTorrentException(
          'Orvix stream engine returned an empty audio window.',
        );
      }
      if (bytes.length > 850000) {
        throw const LocalTorrentException(
          'Orvix stream engine returned an unexpectedly large audio window.',
        );
      }
      return bytes;
    } on TimeoutException {
      throw const LocalTorrentException(
        'Orvix stream engine timed out while extracting the audio window.',
      );
    } finally {
      client.close();
    }
  }

  Future<bool> _remoteProxyHasMediaBytes(Uri proxy) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', proxy)
        ..headers['Range'] = 'bytes=0-1'
        ..headers['Accept-Encoding'] = 'identity';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 && response.statusCode != 206) {
        return false;
      }
      final firstChunk = await response.stream.first
          .timeout(const Duration(seconds: 8));
      return firstChunk.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> _orvixCapabilities() async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/orvix/capabilities'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  String _buildStreamUrl({
    required String infoHash,
    required int fileIndex,
    String? fileHint,
  }) {
    final base = Uri.parse('$baseUrl/$infoHash/$fileIndex');
    final hint = fileHint?.trim() ?? '';
    if (fileIndex >= 0 || hint.isEmpty) return base.toString();
    return base.replace(
      queryParameters: <String, String>{'f': hint},
    ).toString();
  }

  Future<int?> _resolveOrvixFileIndex(
    String infoHash, {
    String? fileHint,
  }) async {
    final hint = fileHint?.trim() ?? '';
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final uri = Uri.parse('$baseUrl/orvix/$infoHash/resolve-file').replace(
          queryParameters:
              hint.isEmpty ? null : <String, String>{'hint': hint},
        );
        final response = await http
            .get(uri, headers: const {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 4));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            final resolved = _asInt(decoded['fileIdx']);
            if (resolved != null && resolved >= 0) return resolved;
          }
        }
      } catch (_) {
        // Metadata may still be resolving. Retry briefly before falling back.
      }
      if (attempt < 7) {
        await Future<void>.delayed(
          Duration(milliseconds: 250 + (attempt * 150)),
        );
      }
    }
    return null;
  }

  Future<http.Response> _createTorrent(Map<String, dynamic> body) async {
    Future<http.Response> send() => http
        .post(
          Uri.parse('$baseUrl/create'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    try {
      return await send();
    } on TimeoutException {
      rethrow;
    } catch (_) {
      // One recovery attempt only. A dead/restarted Android service should not
      // make the user re-select the same source just to recreate the localhost
      // server.
      if (Platform.isAndroid && !await _heartbeat()) {
        _androidProfileConfigured = false;
        await ensureRunning();
        return await send();
      }
      rethrow;
    }
  }

  Future<void> _primeLocalStream(
    String streamUrl, {
    required int targetBytes,
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      await (() async {
        final request = http.Request('GET', Uri.parse(streamUrl));
        request.headers['Range'] = 'bytes=0-${targetBytes - 1}';
        final response = await client.send(request);
        if (response.statusCode != 200 && response.statusCode != 206) return;

        var received = 0;
        await for (final chunk in response.stream) {
          received += chunk.length;
          if (received >= targetBytes) break;
        }
      })().timeout(timeout);
    } catch (_) {
      // Warm-up is best effort. A slow swarm still gets a chance in the real
      // player, while healthy swarms usually seed the requested prefix.
    } finally {
      client.close();
    }
  }
  Future<void> _removeEngine(String infoHash) async {
    try {
      await http
          .get(Uri.parse('$baseUrl/$infoHash/remove'))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Cleanup is best effort; a dead engine is already effectively removed.
    }
  }

  Future<LocalTorrentHealth?> healthForStreamUrl(String streamUrl) async {
    final uri = Uri.tryParse(streamUrl);
    if (uri == null ||
        (uri.host != '127.0.0.1' && uri.host != 'localhost') ||
        uri.port != 11470 ||
        uri.pathSegments.length < 2) {
      return null;
    }

    final infoHash = uri.pathSegments[0];
    final fileIndex = int.tryParse(uri.pathSegments[1]);
    if (fileIndex == null) return null;

    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/$infoHash/$fileIndex/stats.json'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 2));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;

      final peers = _asInt(decoded['peers']) ??
          _asInt(decoded['numPeers']) ??
          _asInt(decoded['connectedPeers']) ??
          0;
      final connections = _asInt(decoded['swarmConnections']) ??
          _asInt(decoded['connections']) ??
          peers;
      final metadataReady = decoded['hasMetadata'] == true ||
          decoded['metadata'] == true ||
          decoded['metadata']?.toString().toLowerCase() == 'ready';

      double speed = 0;
      for (final key in const [
        'downloadSpeed',
        'downloadRate',
        'downloadRateBytesPerSecond',
        'speed',
      ]) {
        final raw = decoded[key];
        if (raw is num) {
          speed = raw.toDouble();
          break;
        }
        final parsed = double.tryParse(raw?.toString() ?? '');
        if (parsed != null) {
          speed = parsed;
          break;
        }
      }

      return LocalTorrentHealth(
        metadataReady: metadataReady,
        peers: peers,
        connections: connections,
        downloadSpeedBytesPerSecond: speed,
      );
    } catch (_) {
      return null;
    }
  }

  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    Duration timeout = const Duration(milliseconds: 4800),
    int windowBytes = 512 * 1024,
    bool retainSession = false,
  }) async {
    if (!source.isMagnet) {
      return const LocalTorrentProbeResult(
        playableNow: true,
        bytesReceived: 1,
        elapsed: Duration.zero,
        firstByteLatency: Duration.zero,
        peers: 0,
        connections: 0,
        downloadSpeedBytesPerSecond: 0,
        sampleWindowsPassed: 2,
      );
    }

    final infoHash = _extractInfoHash(source.resource);
    if (infoHash == null) {
      return LocalTorrentProbeResult(
        playableNow: false,
        bytesReceived: 0,
        elapsed: timeout,
        firstByteLatency: null,
        peers: 0,
        connections: 0,
        downloadSpeedBytesPerSecond: 0,
        sampleWindowsPassed: 0,
      );
    }

    await ensureRunning();
    final engineMagnet = normalizeMagnetForEngine(source.resource);
    final trackerUrls = trackerUrlsForMagnet(engineMagnet);
    final fileHint = source.fileNameHint?.trim();
    final body = <String, dynamic>{
      'from': engineMagnet,
      'guessFileIdx': true,
      'peerSearch': <String, dynamic>{
        'sources': <String>[
          'dht:$infoHash',
          for (final tracker in trackerUrls) 'tracker:$tracker',
        ],
      },
      if (fileHint != null && fileHint.isNotEmpty)
        'fileMustInclude': <String>[fileHint],
    };

    var retainedProbe = false;
    try {
      final response = await _createTorrent(body).timeout(
        const Duration(milliseconds: 1800),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return LocalTorrentProbeResult(
          playableNow: false,
          bytesReceived: 0,
          elapsed: timeout,
          firstByteLatency: null,
          peers: 0,
          connections: 0,
          downloadSpeedBytesPerSecond: 0,
          sampleWindowsPassed: 0,
        );
      }

      Map<String, dynamic>? payload;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } catch (_) {}

      final fileIndex = source.torrentFileIndex ??
          _asInt(payload?['guessedFileIdx']) ??
          _asInt(payload?['fileIdx']) ??
          -1;
      final streamUrl =
          _buildStreamUrl(infoHash: infoHash, fileIndex: fileIndex);

      final watch = Stopwatch()..start();
      Duration? firstByte;
      var bytes = 0;
      var sampleWindowsPassed = 0;

      Future<int> readWindow(int start, int length) async {
        final client = http.Client();
        var received = 0;
        try {
          final request = http.Request('GET', Uri.parse(streamUrl));
          request.headers['Range'] = 'bytes=$start-${start + length - 1}';
          final streamed = await client.send(request);
          if (streamed.statusCode != 200 && streamed.statusCode != 206) {
            return 0;
          }
          await for (final chunk in streamed.stream) {
            if (chunk.isEmpty) continue;
            firstByte ??= watch.elapsed;
            received += chunk.length;
            if (received >= length) break;
          }
        } finally {
          client.close();
        }
        return received;
      }

      try {
        await (() async {
          final first = await readWindow(0, windowBytes);
          bytes += first;
          if (first >= 256 * 1024) sampleWindowsPassed++;

          // A tiny burst at byte zero can be cached while the rest of the
          // swarm is unusable. Sample a second early-playback region as well
          // so "Ready now" means the torrent can serve more than its header.
          final size = source.sizeBytes ?? 0;
          if (first >= 256 * 1024 && size > 16 * 1024 * 1024) {
            const preferredOffset = 8 * 1024 * 1024;
            final maxSafeOffset = size - windowBytes;
            final secondOffset = maxSafeOffset > preferredOffset
                ? preferredOffset
                : maxSafeOffset.clamp(windowBytes, preferredOffset).toInt();
            final second = await readWindow(secondOffset, windowBytes);
            bytes += second;
            if (second >= 256 * 1024) sampleWindowsPassed++;
          } else if (first >= 256 * 1024) {
            sampleWindowsPassed = 2;
          }
        })().timeout(timeout);
      } catch (_) {
        // Timeout/stall is live health evidence and lowers this source.
      } finally {
        watch.stop();
      }

      final health = await healthForStreamUrl(streamUrl);
      final elapsedSeconds =
          watch.elapsedMicroseconds <= 0 ? 0.001 : watch.elapsedMicroseconds / 1e6;
      final measuredSpeed = bytes / elapsedSeconds;
      final engineSpeed = health?.downloadSpeedBytesPerSecond ?? 0;
      final speed = measuredSpeed > engineSpeed ? measuredSpeed : engineSpeed;

      if (retainSession) {
        _retainedProbeInfoHashes.add(infoHash);
        retainedProbe = true;
        _scheduleProbeCleanup();
      }

      return LocalTorrentProbeResult(
        playableNow: sampleWindowsPassed >= 2 && bytes >= 512 * 1024,
        bytesReceived: bytes,
        elapsed: watch.elapsed,
        firstByteLatency: firstByte,
        peers: health?.peers ?? 0,
        connections: health?.connections ?? 0,
        downloadSpeedBytesPerSecond: speed,
        sampleWindowsPassed: sampleWindowsPassed,
      );
    } finally {
      // Never detach a torrent that is currently being used by the player.
      if (!retainedProbe && _currentInfoHash != infoHash) {
        await _removeEngine(infoHash);
      }
    }
  }

  void _scheduleProbeCleanup() {
    _probeCleanupTimer?.cancel();
    _probeCleanupTimer = Timer(const Duration(seconds: 75), () {
      unawaited(releaseRetainedProbeSessions());
    });
  }

  Future<void> prepareRetainedProbeForPlayback(SourceResult source) async {
    final selectedHash =
        source.isMagnet ? _extractInfoHash(source.resource) : null;
    final stale = _retainedProbeInfoHashes
        .where((hash) => hash != selectedHash && hash != _currentInfoHash)
        .toList(growable: false);
    for (final hash in stale) {
      await _removeEngine(hash);
      _retainedProbeInfoHashes.remove(hash);
    }

    if (selectedHash != null && _retainedProbeInfoHashes.contains(selectedHash)) {
      // Give the caller a short handoff window to call resolve(), which turns
      // this warm probe into the active playback torrent.
      _probeCleanupTimer?.cancel();
      _probeCleanupTimer = Timer(const Duration(seconds: 25), () {
        if (_currentInfoHash != selectedHash) {
          _retainedProbeInfoHashes.remove(selectedHash);
          unawaited(_removeEngine(selectedHash));
        }
      });
    }
  }

  Future<void> releaseRetainedProbeSessions() async {
    _probeCleanupTimer?.cancel();
    _probeCleanupTimer = null;
    final stale = _retainedProbeInfoHashes
        .where((hash) => hash != _currentInfoHash)
        .toList(growable: false);
    for (final hash in stale) {
      await _removeEngine(hash);
      _retainedProbeInfoHashes.remove(hash);
    }
  }

  Future<void> ensureRunning() async {
    if (await _heartbeat()) {
      if (Platform.isWindows) {
        final capabilities = await _orvixCapabilities();
        final currentEngine =
            capabilities?['exactFileEmbeddedSubtitles'] == true &&
            _asInt(capabilities?['exactSubtitleRouteVersion']) == 1 &&
            capabilities?['remoteEmbeddedSubtitles'] == true &&
            _asInt(capabilities?['remoteSubtitleRouteVersion']) == 1 &&
            capabilities?['audioWindowExtraction'] == true &&
            _asInt(capabilities?['audioWindowRouteVersion']) == 1;
        if (currentEngine) return;

        // A previous Orvix/portable run can leave the old localhost helper
        // alive. A plain heartbeat is not enough: beta.37's helper would answer
        // on 11470 but does not implement beta.38's unified audio endpoint.
        // Stop only Orvix's private binary, then launch the bundled version.
        await _stopStaleWindowsEngine();
      } else {
        if (Platform.isAndroid) {
          await _configureAndroidSafeProfile();
        }
        return;
      }
    }

    final existing = _starting;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _starting = completer.future;

    try {
      if (Platform.isAndroid) {
        _androidProfileConfigured = false;
        try {
          await _androidChannel.invokeMethod<String>('start');
        } on PlatformException catch (error) {
          throw LocalTorrentException(
            'Could not start the Android torrent engine: ${error.message ?? error.code}',
          );
        } on MissingPluginException {
          throw const LocalTorrentException(
            'The Android torrent engine bridge is missing from this build. Reinstall the latest Orvix APK.',
          );
        }

        for (var attempt = 0; attempt < 80; attempt++) {
          if (await _heartbeat()) {
            await _configureAndroidSafeProfile();
            completer.complete();
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        throw const LocalTorrentException(
          'The Android torrent engine did not become ready in time.',
        );
      }

      if (!Platform.isWindows && !Platform.isMacOS) {
        throw const LocalTorrentException(
          'Built-in P2P streaming is not packaged for this platform yet.',
        );
      }

      final appDir = File(Platform.resolvedExecutable).parent;
      final executable = Platform.isWindows
          ? File('${appDir.path}${Platform.pathSeparator}$bundledExeName')
          : File(
              '${appDir.parent.path}${Platform.pathSeparator}Resources'
              '${Platform.pathSeparator}$bundledMacName',
            );
      if (!await executable.exists()) {
        throw const LocalTorrentException(
          'The Orvix torrent engine is missing from this installation. Reinstall the latest Orvix build.',
        );
      }

      late final Directory workDir;
      if (Platform.isWindows) {
        final localAppData = Platform.environment['LOCALAPPDATA'];
        workDir = Directory(
          localAppData == null || localAppData.trim().isEmpty
              ? '${appDir.path}${Platform.pathSeparator}torrent-engine-data'
              : '$localAppData${Platform.pathSeparator}Orvix${Platform.pathSeparator}torrent-engine',
        );
      } else {
        // The test DMG is app-sandboxed. Keep the native engine's working
        // directory inside a location the sandbox can always write to.
        workDir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}Orvix'
          '${Platform.pathSeparator}torrent-engine',
        );
      }
      await workDir.create(recursive: true);

      _process = await Process.start(
        executable.path,
        const ['--no-tray'],
        workingDirectory: workDir.path,
        mode: ProcessStartMode.normal,
        environment: Platform.isWindows
            ? windowsStreamServerEnvironment(appDir.path)
            : null,
      );
      _ownsProcess = true;

      _process!.stdout.listen((_) {});
      _process!.stderr.listen((_) {});

      for (var attempt = 0; attempt < 80; attempt++) {
        if (await _heartbeat()) {
          completer.complete();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      await dispose();
      throw const LocalTorrentException(
        'The local torrent engine did not become ready in time.',
      );
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      _starting = null;
    }
  }

  Future<void> _configureAndroidSafeProfile() async {
    if (!Platform.isAndroid || _androidProfileConfigured) return;

    // Use one Android torrent profile for phone and TV. The phone path is the
    // known-good baseline, so TV should not silently run with fewer peers or a
    // much smaller cache and then appear less reliable on the same source.
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/settings'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cacheSize': 2 * 1024 * 1024 * 1024,
              // Stremio exposes 500 as its official Fast profile. Keep mobile
              // on the balanced 200-peer profile and give powered TV devices
              // the larger swarm window.
              'btMaxConnections': PlatformProfile.isAndroidTv ? 500 : 200,
              'btHandshakeTimeout': 20000,
              'btRequestTimeout': 10000,
              'btDownloadSpeedSoftLimit': 0,
              'btDownloadSpeedHardLimit': 0,
              'btMinPeersForStable': 5,
              'btEnableDht': true,
              'btEnablePex': true,
              'btEnableLsd': true,
              'btEncryptionMode': 'allow',
              'seedingEnabled': false,
            }),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _androidProfileConfigured = true;
      }
    } catch (_) {
      // A settings failure must not make the transport itself unusable.
      // The next resolve attempt will retry this best-effort profile.
    }
  }

  Future<void> _stopStaleWindowsEngine() async {
    if (!Platform.isWindows) return;
    try {
      await Process.run(
        'taskkill.exe',
        const <String>['/F', '/IM', bundledExeName],
        runInShell: false,
      ).timeout(const Duration(seconds: 4));
    } catch (_) {
      // The process may already have exited between heartbeat and replacement.
    }
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!await _heartbeat()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<bool> _heartbeat() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/heartbeat'))
          .timeout(const Duration(milliseconds: 700));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  String? _extractInfoHash(String magnet) {
    final match = RegExp(
      r'xt=urn:btih:([a-zA-Z0-9]+)',
      caseSensitive: false,
    ).firstMatch(magnet);
    final value = match?.group(1)?.trim().toLowerCase();
    return value == null || value.isEmpty ? null : value;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> releaseCurrentStream() async {
    final activeInfoHash = _currentInfoHash;
    _currentInfoHash = null;
    if (activeInfoHash != null) {
      await _removeEngine(activeInfoHash);
    }
  }

  Future<void> dispose() async {
    _probeCleanupTimer?.cancel();
    _probeCleanupTimer = null;

    // Desktop app teardown must terminate the private native server before the
    // first await. Flutter cannot await State.dispose(), and the previous order
    // awaited HTTP torrent cleanup before process.kill(), allowing the UI to
    // exit while orvix-stream-server.exe survived on port 11470. That stale
    // process could then fool the next build's heartbeat and serve old routes.
    if (Platform.isWindows || Platform.isMacOS) {
      final process = _process;
      final ownsProcess = _ownsProcess;
      _process = null;
      _ownsProcess = false;
      _currentInfoHash = null;
      _retainedProbeInfoHashes.clear();

      if (ownsProcess && process != null) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      return;
    }

    await releaseRetainedProbeSessions();
    await releaseCurrentStream();

    _process = null;
    _ownsProcess = false;
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod<void>('stop');
      } catch (_) {
        // Process shutdown must stay best-effort during app teardown.
      }
    }
  }

}
