import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'orvix_media_engine_service.dart';

class AiAudioSinhalaCue {
  const AiAudioSinhalaCue({
    required this.start,
    required this.end,
    required this.english,
    required this.sinhala,
  });

  final Duration start;
  final Duration end;
  final String english;
  final String sinhala;
}

class AiAudioSttException implements Exception {
  const AiAudioSttException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AiAudioSttService {
  AiAudioSttService._();

  static const _guestFunctionJwt =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwanVpc3hvZndxeGhibm5zeXpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2NTMxMDIsImV4cCI6MjEwNTIyOTEwMn0.cBlT4tgZW_WMlkmOagFo7PhtFXwS7ib9Yw9BECCrNew';
  static final Uri _endpoint = Uri.parse(
    'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/transcribe-audio-si',
  );

  static const Duration windowDuration = Duration(seconds: 28);
  static const Duration windowStride = Duration(seconds: 20);

  static Future<List<AiAudioSinhalaCue>> transcribeWindow({
    required String title,
    required String videoUrl,
    required Duration start,
    Duration duration = windowDuration,
  }) async {
    if (!(Platform.isWindows || Platform.isAndroid || Platform.isMacOS)) {
      throw const AiAudioSttException(
        'Audio subtitle fallback is not supported on this platform.',
      );
    }
    final uri = Uri.tryParse(videoUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const AiAudioSttException(
        'Audio subtitle fallback requires a readable media URL.',
      );
    }

    final safeStartMs = start.inMilliseconds < 0 ? 0 : start.inMilliseconds;
    final durationMs = duration.inMilliseconds.clamp(1000, 30000).toInt();
    final temp = await getTemporaryDirectory();
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}orvix-ai-audio',
    );
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'window_${safeStartMs}_${DateTime.now().microsecondsSinceEpoch}.aac',
    );

    try {
      final startSeconds = (safeStartMs / 1000).toStringAsFixed(3);
      final durationSeconds = (durationMs / 1000).toStringAsFixed(3);

      List<int> bytes;
      if (Platform.isWindows) {
        // Keep FFmpeg completely outside the Flutter process. A real Office
        // test still terminated the app after audio-ai-window-start even when
        // Dart launched ffmpeg.exe directly. Route extraction through the
        // already-separate Orvix media engine so an FFmpeg/helper failure can
        // only fail this request, never the player process.
        try {
          bytes = await OrvixMediaEngineService.instance.extractAudioWindow(
            videoUrl: videoUrl,
            start: Duration(milliseconds: safeStartMs),
            duration: Duration(milliseconds: durationMs),
          );
        } on OrvixMediaEngineException catch (error) {
          throw AiAudioSttException(error.message);
        }
      } else {
        final session = await FFmpegKit.executeWithArguments(<String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-ss',
          startSeconds,
          '-t',
          durationSeconds,
          '-i',
          videoUrl,
          '-map',
          '0:a:0?',
          '-vn',
          '-sn',
          '-dn',
          '-ac',
          '1',
          '-ar',
          '16000',
          '-c:a',
          'aac',
          '-b:a',
          '32k',
          '-f',
          'adts',
          file.path,
        ]).timeout(const Duration(seconds: 45));

        final code = await session.getReturnCode();
        if (!ReturnCode.isSuccess(code)) {
          throw const AiAudioSttException(
            'Could not extract a short audio window from this video.',
          );
        }
      }

      if (!Platform.isWindows) {
        if (!await file.exists() || await file.length() < 256) {
          throw const AiAudioSttException(
            'Could not extract a short audio window from this video.',
          );
        }
        bytes = await file.readAsBytes();
      }
      // 28 s mono AAC at 32 kbps is normally ~110 KB. Keep a hard guard well
      // below the Edge Function payload ceiling so a malformed encoder output
      // can never create a huge request.
      if (bytes.length > 850000) {
        throw const AiAudioSttException(
          'The extracted audio window was unexpectedly large.',
        );
      }

      final sessionToken =
          Supabase.instance.client.auth.currentSession?.accessToken.trim();
      final token = sessionToken != null && sessionToken.isNotEmpty
          ? sessionToken
          : _guestFunctionJwt;

      final response = await http
          .post(
            _endpoint,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'apikey': _guestFunctionJwt,
              'Content-Type': 'application/json',
              'Cache-Control': 'no-store',
            },
            body: jsonEncode(<String, dynamic>{
              'title': title,
              'mime_type': 'audio/aac',
              'duration_ms': durationMs,
              'audio_base64': base64Encode(bytes),
            }),
          )
          .timeout(const Duration(seconds: 40));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail =
            decoded is Map ? decoded['error']?.toString().trim() : null;
        throw AiAudioSttException(
          detail == null || detail.isEmpty
              ? 'Audio subtitle service returned HTTP ${response.statusCode}.'
              : 'Audio subtitle service failed: $detail.',
        );
      }

      final raw = decoded is Map ? decoded['cues'] : null;
      if (raw is! List) {
        throw const AiAudioSttException(
          'Audio subtitle service returned an invalid cue list.',
        );
      }

      final result = <AiAudioSinhalaCue>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final relativeStart = int.tryParse(item['start_ms']?.toString() ?? '');
        final relativeEnd = int.tryParse(item['end_ms']?.toString() ?? '');
        final english = item['english']?.toString().trim() ?? '';
        final sinhala = item['sinhala']?.toString().trim() ?? '';
        if (relativeStart == null ||
            relativeEnd == null ||
            relativeStart < 0 ||
            relativeEnd <= relativeStart ||
            english.isEmpty ||
            sinhala.isEmpty) {
          continue;
        }

        result.add(
          AiAudioSinhalaCue(
            start: Duration(milliseconds: safeStartMs + relativeStart),
            end: Duration(milliseconds: safeStartMs + relativeEnd),
            english: english,
            sinhala: sinhala,
          ),
        );
      }
      return result;
    } on AiAudioSttException {
      rethrow;
    } on TimeoutException {
      throw const AiAudioSttException(
        'Audio subtitle preparation timed out.',
      );
    } catch (error) {
      throw AiAudioSttException(
        'Audio subtitle preparation failed (${error.runtimeType}).',
      );
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}
