import 'dart:io';

import 'package:flutter/foundation.dart';

class PlatformProfile {
  PlatformProfile._();

  /// Set by the dedicated Android TV build using:
  /// --dart-define=ORVIX_TV=true
  static const bool tvBuild = bool.fromEnvironment('ORVIX_TV');

  /// Lets widget tests render the Android TV interface on the host platform.
  /// Always null in the app.
  @visibleForTesting
  static bool? debugAndroidTvOverride;

  static bool get isAndroidTv =>
      debugAndroidTvOverride ?? (Platform.isAndroid && tvBuild);
  static bool get isAndroidMobile =>
      debugAndroidTvOverride == true ? false : Platform.isAndroid && !tvBuild;
}
