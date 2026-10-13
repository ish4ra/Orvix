import 'package:flutter/services.dart';

/// Camera permission state for the phone's TV QR scanner.
enum CameraAccess {
  granted,

  /// Never asked: explain first, then ask.
  notRequested,

  /// Denied, and Android will show its prompt again.
  denied,

  /// Denied, and Android will not ask again: only app settings can change it.
  permanentlyDenied,

  /// The device has no camera.
  noCamera,

  /// The platform could not tell (no native support). The scanner then asks
  /// for the permission itself, as before.
  unknown,
}

/// Reads and requests the camera permission through the Android activity
/// (tools/android/OrvixCameraPermission.kt).
class CameraPermissionGateway {
  const CameraPermissionGateway();

  static const MethodChannel _channel =
      MethodChannel('orvix/camera_permission');

  static CameraAccess parse(Object? value) => switch (value) {
        'granted' => CameraAccess.granted,
        'notRequested' => CameraAccess.notRequested,
        'denied' => CameraAccess.denied,
        'permanentlyDenied' => CameraAccess.permanentlyDenied,
        'noCamera' => CameraAccess.noCamera,
        _ => CameraAccess.unknown,
      };

  Future<CameraAccess> status() => _call('status');

  /// Shows Android's permission prompt when it can still be shown.
  Future<CameraAccess> request() => _call('request');

  /// Opens Orvix's page in Android's app settings.
  Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<CameraAccess> _call(String method) async {
    try {
      return parse(await _channel.invokeMethod<String>(method));
    } on PlatformException {
      return CameraAccess.unknown;
    } on MissingPluginException {
      return CameraAccess.unknown;
    }
  }
}
