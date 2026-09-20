import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'source_provider_service.dart';

class AndroidTvTorrentException implements Exception {
  const AndroidTvTorrentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AndroidTvTorrentHealth {
  const AndroidTvTorrentHealth({
    required this.metadataReady,
    required this.peers,
    required this.seeds,
    required this.downloadSpeedBytesPerSecond,
    required this.preloadedBytes,
  });

  final bool metadataReady;
  final int peers;
  final int seeds;
  final double downloadSpeedBytesPerSecond;
  final int preloadedBytes;
}

class _TorrServerFile {
  const _TorrServerFile({
    required this.id,
    required this.path,
    required this.length,
  });

  final int id;
  final String path;
  final int length;
}

class _TorrServerStats {
  const _TorrServerStats({
    required this.hash,
    required this.files,
    required this.peers,
    required this.seeds,
    required this.downloadSpeed,
    required this.preloadedBytes,
  });

  final String hash;
  final List<_TorrServerFile> files;
  final int peers;
  final int seeds;
  final double downloadSpeed;
  final int preloadedBytes;
}

/// Android-TV-only torrent transport.
///
/// Orvix deliberately talks to TorrServer through its public localhost HTTP API
/// instead of copying Nuvio/Debrify implementation code. The executable is a
/// separate GPLv3 program bundled with its own license/source notice.
class AndroidTvTorrServerService {
  AndroidTvTorrServerService._();

  static final AndroidTvTorrServerService instance =
      AndroidTvTorrServerService._();

  static const String baseUrl = 'http://127.0.0.1:8091';
  static const MethodChannel _channel = MethodChannel('orvix/torrserver');
  static const int _preloadTargetBytes = 5 * 1024 * 1024;

  String? _activeHash;
  String? _activeMagnet;
  Future<void>? _starting;

  Future<String> resolve(
    SourceResult source, {
    void Function(String message)? onProgress,
  }) async {
    final infoHash = _extractInfoHash(source.resource);
    if (infoHash == null) {
      throw const AndroidTvTorrentException(
        'This source does not contain a usable BitTorrent info hash.',
      );
    }

    onProgress?.call('Starting TV torrent engine…');
    await ensureRunning();

    // Drop the previous route before attaching a new source. TorrServer keeps
    // the process alive, so switching sources is cheap and deterministic.
    await stopCurrentStream();

    final magnet = _cleanMagnet(source.resource, infoHash);
    onProgress?.call('Loading torrent metadata…');
    final hash = await _addTorrent(magnet);
    _activeHash = hash;
    _activeMagnet = magnet;

    _TorrServerStats? stats;
    final deadline = DateTime.now().add(const Duration(seconds: 18));
    while (DateTime.now().isBefore(deadline)) {
      stats = await _stats(hash);
      if (stats != null && stats.files.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (stats == null || stats.files.isEmpty) {
      throw const AndroidTvTorrentException(
        'Torrent metadata did not expose a playable file in time.',
      );
    }

    final fileId = _selectFileId(
      stats.files,
      source.torrentFileIndex,
      source.fileNameHint,
    );
    final streamUrl =
        '$baseUrl/stream?link=${Uri.encodeQueryComponent(magnet)}&index=$fileId&play';

    // TorrServer is designed to keep torrent piece/cache state after the
    // preload request closes. This is the important difference from the old
    // Stremio-server "warm-up" experiment: wait for actual media bytes before
    // handing the route to Media3.
    await _preload(
      streamUrl,
      expectedSizeBytes: source.sizeBytes,
      onProgress: onProgress,
    );

    onProgress?.call('P2P buffer ready — opening player…');
    return streamUrl;
  }

  Future<void> ensureRunning() async {
    if (await _heartbeat()) return;

    final existing = _starting;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _starting = completer.future;
    try {
      try {
        await _channel.invokeMethod<String>('start');
      } on PlatformException catch (error) {
        throw AndroidTvTorrentException(
          'Could not start TorrServer: ${error.message ?? error.code}',
        );
      } on MissingPluginException {
        throw const AndroidTvTorrentException(
          'This Android TV build does not contain the TorrServer bridge.',
        );
      }

      for (var attempt = 0; attempt < 75; attempt++) {
        if (await _heartbeat()) {
          completer.complete();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw const AndroidTvTorrentException(
        'TorrServer did not become ready in time.',
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

  Future<AndroidTvTorrentHealth?> healthForStreamUrl(String streamUrl) async {
    final uri = Uri.tryParse(streamUrl);
    if (uri == null ||
        (uri.host != '127.0.0.1' && uri.host != 'localhost') ||
        uri.port != 8091) {
      return null;
    }

    final magnet = uri.queryParameters['link'] ?? _activeMagnet;
    final hash = magnet == null ? _activeHash : (_extractInfoHash(magnet) ?? _activeHash);
    if (hash == null) return null;

    final stats = await _stats(hash);
    if (stats == null) return null;
    return AndroidTvTorrentHealth(
      metadataReady: stats.files.isNotEmpty,
      peers: stats.peers,
      seeds: stats.seeds,
      downloadSpeedBytesPerSecond: stats.downloadSpeed,
      preloadedBytes: stats.preloadedBytes,
    );
  }

  Future<void> stopCurrentStream() async {
    final hash = _activeHash;
    _activeHash = null;
    _activeMagnet = null;
    if (hash == null) return;
    try {
      await http
          .post(
            Uri.parse('$baseUrl/torrents'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'action': 'drop', 'hash': hash}),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // Switching/back navigation must remain responsive even if cleanup fails.
    }
  }

  Future<void> dispose() async {
    await stopCurrentStream();
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<String> _addTorrent(String magnet) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/torrents'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'action': 'add',
            'link': magnet,
            'save_to_db': false,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AndroidTvTorrentException(
        'TorrServer rejected the torrent (HTTP ${response.statusCode}).',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error']?.toString().trim();
        if (error != null && error.isNotEmpty) {
          throw AndroidTvTorrentException('TorrServer: $error');
        }
        final hash = decoded['hash']?.toString().trim().toLowerCase();
        if (hash != null && hash.isNotEmpty) return hash;
      }
    } on AndroidTvTorrentException {
      rethrow;
    } catch (_) {}

    throw const AndroidTvTorrentException(
      'TorrServer added the source but did not return its torrent hash.',
    );
  }

  Future<_TorrServerStats?> _stats(String hash) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/torrents'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'action': 'get', 'hash': hash}),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;

      final files = <_TorrServerFile>[];
      final rawFiles = decoded['file_stats'];
      if (rawFiles is List) {
        for (var i = 0; i < rawFiles.length; i++) {
          final raw = rawFiles[i];
          if (raw is! Map) continue;
          final map = raw.cast<Object?, Object?>();
          files.add(
            _TorrServerFile(
              id: _asInt(map['id']) ?? i + 1,
              path: map['path']?.toString() ?? '',
              length: _asInt(map['length']) ?? 0,
            ),
          );
        }
      }

      return _TorrServerStats(
        hash: decoded['hash']?.toString().trim().toLowerCase() ?? hash,
        files: files,
        peers: _asInt(decoded['active_peers']) ?? 0,
        seeds: _asInt(decoded['connected_seeders']) ?? 0,
        downloadSpeed: _asDouble(decoded['download_speed']) ?? 0,
        preloadedBytes: _asInt(decoded['preloaded_bytes']) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  int _selectFileId(
    List<_TorrServerFile> files,
    int? requestedIndex,
    String? filename,
  ) {
    final hint = filename?.trim();
    if (hint != null && hint.isNotEmpty) {
      final basename = hint.split(RegExp(r'[/\\]')).last.toLowerCase();
      for (final file in files) {
        if (file.path.split(RegExp(r'[/\\]')).last.toLowerCase() == basename) {
          return file.id;
        }
      }
      final lowerHint = hint.toLowerCase();
      for (final file in files) {
        if (file.path.toLowerCase().contains(lowerHint)) return file.id;
      }
    }

    // Stremio addon fileIdx is zero-based; TorrServer file_stats IDs are
    // commonly one-based. Validate the offset against the returned metadata.
    if (requestedIndex != null) {
      final oneBased = requestedIndex + 1;
      for (final file in files) {
        if (file.id == oneBased) return file.id;
      }
      if (requestedIndex >= 0 && requestedIndex < files.length) {
        return files[requestedIndex].id;
      }
    }

    const videoExtensions = {
      'mkv',
      'mp4',
      'avi',
      'webm',
      'ts',
      'm4v',
      'mov',
      'wmv',
      'flv',
    };
    final videos = files.where((file) {
      final name = file.path.toLowerCase();
      final dot = name.lastIndexOf('.');
      return dot >= 0 && videoExtensions.contains(name.substring(dot + 1));
    }).toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    if (videos.isNotEmpty) return videos.first.id;
    final fallback = [...files]..sort((a, b) => b.length.compareTo(a.length));
    if (fallback.isNotEmpty) return fallback.first.id;
    throw const AndroidTvTorrentException('No playable torrent file was found.');
  }

  Future<void> _preload(
    String streamUrl, {
    int? expectedSizeBytes,
    void Function(String message)? onProgress,
  }) async {
    final target = expectedSizeBytes != null && expectedSizeBytes > 0
        ? expectedSizeBytes.clamp(512 * 1024, _preloadTargetBytes)
        : _preloadTargetBytes;
    final client = http.Client();
    StreamSubscription<List<int>>? subscription;
    Timer? timeout;
    final completer = Completer<void>();
    var received = 0;

    try {
      final request = http.Request('GET', Uri.parse(streamUrl));
      request.headers['Connection'] = 'keep-alive';
      final response =
          await client.send(request).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AndroidTvTorrentException(
          'TorrServer stream returned HTTP ${response.statusCode}.',
        );
      }

      timeout = Timer(const Duration(seconds: 55), () {
        if (!completer.isCompleted) {
          completer.completeError(
            const AndroidTvTorrentException(
              'P2P could not buffer enough video data in time.',
            ),
          );
        }
      });

      subscription = response.stream.listen(
        (chunk) {
          received += chunk.length;
          final mb = received / (1024 * 1024);
          final targetMb = target / (1024 * 1024);
          onProgress?.call(
            'Buffering P2P • ${mb.toStringAsFixed(1)} / '
            '${targetMb.toStringAsFixed(1)} MB',
          );
          if (received >= target && !completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(
              AndroidTvTorrentException('P2P preload failed: $error'),
              stackTrace,
            );
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            if (received > 0) {
              completer.complete();
            } else {
              completer.completeError(
                const AndroidTvTorrentException(
                  'P2P stream closed before delivering video data.',
                ),
              );
            }
          }
        },
        cancelOnError: true,
      );

      await completer.future;
    } finally {
      timeout?.cancel();
      await subscription?.cancel();
      client.close();
    }
  }

  Future<bool> _heartbeat() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/echo'))
          .timeout(const Duration(milliseconds: 900));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  String _cleanMagnet(String raw, String infoHash) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.toLowerCase() != 'magnet') {
      return 'magnet:?xt=urn:btih:$infoHash';
    }

    final parts = <String>['xt=urn:btih:$infoHash'];
    final seenTrackers = <String>{};
    for (final entry in uri.queryParametersAll.entries) {
      final key = entry.key.toLowerCase();
      if (key.startsWith('x-orvix-') || key == 'xt') continue;
      if (key == 'tr') {
        for (final tracker in entry.value) {
          if (tracker.trim().isEmpty || !seenTrackers.add(tracker)) continue;
          parts.add('tr=${Uri.encodeQueryComponent(tracker)}');
        }
      } else if (key == 'dn' && entry.value.isNotEmpty) {
        parts.add('dn=${Uri.encodeQueryComponent(entry.value.first)}');
      }
    }
    return 'magnet:?${parts.join('&')}';
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

  double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
