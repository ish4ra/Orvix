import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class OrvixMediaPreparation {
  const OrvixMediaPreparation({
    required this.embeddedFound,
    required this.embeddedSrt,
    required this.embeddedLabel,
    required this.embeddedCodec,
    required this.embeddedStreamIndex,
    required this.movieHash,
    required this.movieByteSize,
    required this.probeError,
    required this.hashError,
  });

  final bool embeddedFound;
  final String? embeddedSrt;
  final String? embeddedLabel;
  final String? embeddedCodec;
  final int? embeddedStreamIndex;
  final String? movieHash;
  final int? movieByteSize;
  final String? probeError;
  final String? hashError;

  bool get hasEmbeddedText =>
      embeddedFound &&
      embeddedSrt != null &&
      embeddedSrt!.trim().isNotEmpty;

  bool get hasExactFingerprint =>
      movieHash != null &&
      movieHash!.length == 16 &&
      movieByteSize != null &&
      movieByteSize! > 0;
}

class OrvixMediaEngineException implements Exception {
  const OrvixMediaEngineException(this.message);
  final String message;

  @override
  String toString() => message;
}

class OrvixMediaEngineService {
  OrvixMediaEngineService._();

  static final OrvixMediaEngineService instance = OrvixMediaEngineService._();

  static const String baseUrl = 'http://127.0.0.1:11471';
  static const String bundledExeName = 'orvix-media-engine.exe';

  Process? _process;
  Future<void>? _starting;

  Future<OrvixMediaPreparation> prepare(
    String videoUrl, {
    String? preferredTrackLabel,
    void Function(String message)? onStatus,
  }) async {
    if (!Platform.isWindows) {
      throw const OrvixMediaEngineException(
        'The standalone Orvix media engine is currently packaged for Windows only.',
      );
    }

    onStatus?.call('Starting the standalone Orvix media engine…');
    await ensureRunning();
    onStatus?.call('Inspecting the exact video file before the player opens…');

    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$baseUrl/prepare'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'videoUrl': videoUrl,
              if (preferredTrackLabel?.trim().isNotEmpty == true)
                'preferredTrackLabel': preferredTrackLabel!.trim(),
            }),
          )
          .timeout(const Duration(minutes: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OrvixMediaEngineException(
          'Orvix media engine returned HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map) {
        throw const OrvixMediaEngineException(
          'Orvix media engine returned an invalid response.',
        );
      }

      final map = Map<String, dynamic>.from(decoded);
      if (map['engine'] != 'orvix-media-engine' || map['version'] != 1) {
        throw const OrvixMediaEngineException(
          'The bundled Orvix media engine version is not supported.',
        );
      }

      final embeddedSrt = map['embeddedSrt']?.toString();
      final movieHash = map['movieHash']?.toString().trim();
      final movieByteSize = _asInt(map['movieByteSize']);

      return OrvixMediaPreparation(
        embeddedFound: map['embeddedFound'] == true,
        embeddedSrt: embeddedSrt,
        embeddedLabel: map['embeddedLabel']?.toString(),
        embeddedCodec: map['embeddedCodec']?.toString(),
        embeddedStreamIndex: _asInt(map['embeddedStreamIndex']),
        movieHash:
            movieHash == null || movieHash.isEmpty ? null : movieHash,
        movieByteSize: movieByteSize,
        probeError: _clean(map['probeError']),
        hashError: _clean(map['hashError']),
      );
    } on TimeoutException {
      throw const OrvixMediaEngineException(
        'The Orvix media engine timed out while inspecting this video.',
      );
    } finally {
      client.close();
    }
  }

  Future<void> ensureRunning() async {
    if (await _heartbeat()) return;

    final existing = _starting;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _starting = completer.future;
    try {
      final appDir = File(Platform.resolvedExecutable).parent;
      final executable =
          File('${appDir.path}${Platform.pathSeparator}$bundledExeName');
      if (!await executable.exists()) {
        throw const OrvixMediaEngineException(
          'The standalone Orvix media engine is missing from this installation. Reinstall the latest Orvix build.',
        );
      }

      final environment = Map<String, String>.from(Platform.environment);
      final pathKey = environment.keys.firstWhere(
        (key) => key.toLowerCase() == 'path',
        orElse: () => 'Path',
      );
      final ffmpegBin =
          '${appDir.path}${Platform.pathSeparator}tools${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin';
      final currentPath = environment[pathKey]?.trim() ?? '';
      environment[pathKey] =
          currentPath.isEmpty ? ffmpegBin : '$ffmpegBin;$currentPath';

      _process = await Process.start(
        executable.path,
        const ['--port', '11471', '--idle-timeout', '10m'],
        workingDirectory: appDir.path,
        mode: ProcessStartMode.normal,
        environment: environment,
      );
      _process!.stdout.listen((_) {});
      _process!.stderr.listen((_) {});

      for (var attempt = 0; attempt < 40; attempt++) {
        if (await _heartbeat()) {
          completer.complete();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      _process?.kill();
      _process = null;
      throw const OrvixMediaEngineException(
        'The standalone Orvix media engine did not become ready in time.',
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
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final decoded = jsonDecode(response.body);
      return decoded is Map &&
          decoded['name'] == 'orvix-media-engine' &&
          decoded['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _clean(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
