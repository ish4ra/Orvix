import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/orvix_account_service.dart';
import 'services/ai_sinhala_trace_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    if (Platform.isWindows) {
      final stack = details.stack?.toString().split('\n').take(18).join(' | ') ??
          'no-stack';
      AiSinhalaTraceService.writeCrashSync(
        'flutter-fatal type=${details.exception.runtimeType} stack="$stack"',
      );
    }
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    if (Platform.isWindows) {
      final compact = stack.toString().split('\n').take(18).join(' | ');
      AiSinhalaTraceService.writeCrashSync(
        'platform-fatal type=${error.runtimeType} stack="$compact"',
      );
    }
    return false;
  };

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
