import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_https/log_redirection_strategy.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/orvix_account_service.dart';
import 'services/ai_sinhala_trace_service.dart';

bool _isFfmpegKitWindowsStdioFailure(Object error, StackTrace? stack) {
  if (!Platform.isWindows || error is! FileSystemException) return false;
  final trace = stack?.toString() ?? '';
  return trace.contains('FFmpegKitInitializer._processLogCallbackEvent') &&
      (trace.contains('_StdSink.write') ||
          trace.contains('_RandomAccessFile.writeFromSync'));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    if (_isFfmpegKitWindowsStdioFailure(details.exception, details.stack)) {
      AiSinhalaTraceService.writeCrashSync(
        'ffmpegkit-stdio-suppressed channel=flutter type=${details.exception.runtimeType}',
      );
      return;
    }

    if (Platform.isWindows) {
      final stack = details.stack?.toString().split('\n').take(18).join(' | ') ??
          'no-stack';
      AiSinhalaTraceService.writeCrashSync(
        'flutter-fatal type=${details.exception.runtimeType} stack="$stack"',
      );
    }
    try {
      FlutterError.presentError(details);
    } catch (_) {}
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    if (_isFfmpegKitWindowsStdioFailure(error, stack)) {
      AiSinhalaTraceService.writeCrashSync(
        'ffmpegkit-stdio-suppressed channel=platform type=${error.runtimeType}',
      );
      return true;
    }

    if (Platform.isWindows) {
      final compact = stack.toString().split('\n').take(18).join(' | ');
      AiSinhalaTraceService.writeCrashSync(
        'platform-fatal type=${error.runtimeType} stack="$compact"',
      );
    }
    return false;
  };

  // FFmpegKit's default Flutter log strategy prints session logs to stdout
  // when no callback is registered. A packaged Windows GUI app can have no
  // valid stdout handle; the resulting FileSystemException was the beta.32
  // crash immediately after native English subtitle detection. Keep FFmpeg
  // log redirection enabled for session output, but never print it to the
  // process console. The no-op callback is a second guard for forks that keep
  // the default "print when no callback" behavior.
  if (Platform.isWindows) {
    FFmpegKitConfig.setLogRedirectionStrategy(
      LogRedirectionStrategy.neverPrintLogs,
    );
    FFmpegKitConfig.enableLogCallback((_) {});
  }

  MediaKit.ensureInitialized();

  await Supabase.initialize(
    url: 'https://kpjuisxofwqxhbnnsyzf.supabase.co',
    publishableKey: 'sb_publishable_HmqvNavX_iovenN3YRgpmA_cgxQdG9y',
  );

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
  }

  await OrvixAccountService.restoreSignedInState();
  runApp(const OrvixApp());
}
