import 'dart:io';

class PlatformProfile {
  PlatformProfile._();

  /// Set by the dedicated Android TV build using:
  /// --dart-define=ORVIX_TV=true
  static const bool tvBuild = bool.fromEnvironment('ORVIX_TV');

  static bool get isAndroidTv => Platform.isAndroid && tvBuild;
  static bool get isAndroidMobile => Platform.isAndroid && !tvBuild;
}
