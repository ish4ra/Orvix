import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'source_provider_service.dart';

class LocalTorrentException implements Exception {
  const LocalTorrentException(this.message);
  final String message;

  @override
  String toString() => message;
}

class LocalTorrentService {
  LocalTorrentService._();

  static final LocalTorrentService instance = LocalTorrentService._();

  static const String baseUrl = 'http://127.0.0.1:11470';
  static const String bundledExeName = 'orvix-stream-server.exe';
  static const String bundledMacName = 'orvix-stream-server';
  static const MethodChannel _androidChannel =
      MethodChannel('orvix/torrent_engine');

  Process? _process;
  bool _ownsProcess = false;
  Future<void>? _starting;

  Future<String> resolve(SourceResult source) async {
    if (!source.isMagnet) return source.resource;

    final infoHash = _extractInfoHash(source.resource);
    if (infoHash == null) {
      throw const LocalTorrentException(
        'This torrent source did not include a usable BitTorrent info hash.',
      );
    }

    await ensureRunning();

    final body = <String, dynamic>{
      'from': source.resource,
      'guessFileIdx': true,
      if (source.fileNameHint?.trim().isNotEmpty == true)
        'fileMustInclude': <String>[source.fileNameHint!.trim()],
    };

    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$baseUrl/create'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 45));
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

    final fileIndex = source.torrentFileIndex ??
        _asInt(payload?['guessedFileIdx']) ??
        _asInt(payload?['fileIdx']) ??
        -1;

    return '$baseUrl/$infoHash/$fileIndex';
  }

  Future<void> ensureRunning() async {
    if (await _heartbeat()) return;

    final existing = _starting;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _starting = completer.future;

    try {
      if (Platform.isAndroid) {
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

  Future<void> dispose() async {
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
