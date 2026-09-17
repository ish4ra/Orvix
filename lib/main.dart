import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/orvix_account_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
