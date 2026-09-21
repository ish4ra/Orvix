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

  Future<String> resolve(
    SourceResult source, {
    void Function(String message)? onProgress,
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
    // Match Stremio's resolved Tramvai stream: an addon-provided fileIdx is
    // authoritative. Guess only when the stream did not provide one.
    final fileIndex = explicitFileIndex ??
        guessedFileIndex ??
        _asInt(payload?['fileIdx']) ??
        -1;

    // Stremio's Android path deliberately permits -1 here: the local
    // stream-server can auto-select the playable file when the addon/core does
    // not expose an exact file index. Blocking -1 made Orvix reject sources
    // that Stremio itself can open.
    final streamUrl = _buildStreamUrl(
      infoHash: infoHash,
      fileIndex: fileIndex,
    );

    _currentInfoHash = infoHash;

    // Android TV players tend to fail faster than the torrent swarm can warm
    // up on marginal sources. Prime a small HTTP range into the stream-server
    // cache before handing the URL to the player. This mirrors TorrServer's
    // preload idea without changing the player or downloading the whole file.
    if (Platform.isAndroid && PlatformProfile.isAndroidTv) {
      onProgress?.call('Connecting peers and pre-buffering…');
      await _primeLocalStream(
        streamUrl,
        targetBytes: 1024 * 1024,
        timeout: const Duration(seconds: 10),
      );
    } else if (Platform.isWindows) {
      // Windows MPV is much happier when the localhost torrent endpoint has
      // produced real bytes before libmpv opens it. This is best-effort and
      // never blocks a viable slow swarm forever.
      onProgress?.call('Connecting peers and warming Windows playback…');
      await _primeLocalStream(
        streamUrl,
        targetBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 12),
      );
    }

    onProgress?.call('Opening player…');
    return streamUrl;
  }

  String _buildStreamUrl({
    required String infoHash,
    required int fileIndex,
  }) {
    return '$baseUrl/$infoHash/$fileIndex';
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
                : maxSafeOffset.clamp(windowBytes, preferredOffset);
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
      if (_currentInfoHash != infoHash) {
        await _removeEngine(infoHash);
      }
    }
  }

  Future<void> ensureRunning() async {
    if (await _heartbeat()) {
      if (Platform.isAndroid) {
        await _configureAndroidSafeProfile();
      }
      return;
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
    await releaseCurrentStream();

    final process = _process;
    _process = null;
    if (_ownsProcess && process != null) {
      process.kill();
    }
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
