import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// Android media_kit renders libmpv into a Flutter SurfaceProducer texture.
///
/// media_kit normally sizes that texture from MPV's decoded display dimensions.
/// When Orvix applies a VO-level crop to remove encoded black bars, the decoded
/// frame can keep its old outer dimensions while the active picture becomes
/// wider/narrower. Resizing the native SurfaceProducer to the active display
/// dimensions keeps MPV and Flutter on the same geometry and avoids stretching
/// the texture with a synthetic Flutter aspect-ratio override.
class AndroidVideoSurfaceService {
  AndroidVideoSurfaceService._();

  static const MethodChannel _channel =
      MethodChannel('com.alexmercerind/media_kit_video');

  static int _evenPositive(int value) {
    final safe = value.clamp(2, 1 << 30).toInt();
    return safe.isEven ? safe : safe - 1;
  }

  static Future<bool> resizeToActiveFrame({
    required mk.Player player,
    required int cropWidth,
    required int cropHeight,
  }) async {
    if (!Platform.isAndroid || cropWidth <= 0 || cropHeight <= 0) {
      return false;
    }
    if (player.platform is! mk.NativePlayer) return false;

    final params = player.state.videoParams;
    final rawPar = params.par;
    final pixelAspect =
        rawPar != null && rawPar.isFinite && rawPar > 0 ? rawPar : 1.0;

    var displayWidth = _evenPositive((cropWidth * pixelAspect).round());
    var displayHeight = _evenPositive(cropHeight);

    final rotation = ((params.rotate ?? 0) % 360 + 360) % 360;
    if (rotation == 90 || rotation == 270) {
      final swap = displayWidth;
      displayWidth = displayHeight;
      displayHeight = swap;
    }

    try {
      final handle = await player.handle;
      await _channel.invokeMethod<void>(
        'VideoOutputManager.SetSurfaceSize',
        <String, String>{
          'handle': handle.toString(),
          'width': displayWidth.toString(),
          'height': displayHeight.toString(),
        },
      );
      return true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
