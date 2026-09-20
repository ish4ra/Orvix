import 'package:flutter/services.dart';

class AndroidTvNativePlayerResult {
  const AndroidTvNativePlayerResult({
    this.error,
    this.positionMs,
    this.durationMs,
  });

  final String? error;
  final int? positionMs;
  final int? durationMs;

  bool get failed => error != null && error!.trim().isNotEmpty;
}

class AndroidTvNativePlayerService {
  AndroidTvNativePlayerService._();

  static const MethodChannel _channel =
      MethodChannel('orvix/tv_native_player');

  static Future<AndroidTvNativePlayerResult> play({
    required String url,
    required String title,
    int startPositionMs = 0,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'play',
        <String, dynamic>{
          'url': url,
          'title': title,
          'startPositionMs': startPositionMs,
        },
      );
      return AndroidTvNativePlayerResult(
        error: raw?['error']?.toString(),
        positionMs: _asInt(raw?['positionMs']),
        durationMs: _asInt(raw?['durationMs']),
      );
    } on PlatformException catch (error) {
      return AndroidTvNativePlayerResult(
        error: error.message ?? error.code,
      );
    } on MissingPluginException {
      return const AndroidTvNativePlayerResult(
        error: 'The Android TV native player bridge is missing from this build.',
      );
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
