import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/video_black_bar_crop_service.dart';

Uint8List _solidFrame(int width, int height, {int value = 92}) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    final offset = i * 4;
    rgba[offset] = value;
    rgba[offset + 1] = value;
    rgba[offset + 2] = value;
    rgba[offset + 3] = 255;
  }
  return rgba;
}

void _paintBlackRows(
  Uint8List rgba,
  int width,
  int startY,
  int endY,
) {
  for (var y = startY; y < endY; y++) {
    for (var x = 0; x < width; x++) {
      final offset = ((y * width) + x) * 4;
      rgba[offset] = 0;
      rgba[offset + 1] = 0;
      rgba[offset + 2] = 0;
      rgba[offset + 3] = 255;
    }
  }
}

void main() {
  test('letterboxed 2.35 picture inside 16:9 is a meaningful crop', () {
    const crop = VideoCropRect(width: 1920, height: 816, x: 0, y: 132);
    expect(
      crop.isMeaningful(encodedWidth: 1920, encodedHeight: 1080),
      isTrue,
    );
    expect(crop.mpvValue, '1920x816+0+132');
  });

  test('decoded frame detector removes real encoded top and bottom bars', () {
    const width = 320;
    const height = 180;
    const bar = 22;
    final rgba = _solidFrame(width, height);

    _paintBlackRows(rgba, width, 0, bar);
    _paintBlackRows(rgba, width, height - bar, height);

    final crop = VideoBlackBarCropService.detectFromRgba(
      rgba: rgba,
      width: width,
      height: height,
    );

    expect(crop, isNotNull);
    expect(crop!.x, 0);
    expect(crop.y, bar);
    expect(crop.width, width);
    expect(crop.height, height - (bar * 2));
  });

  test('ordinary full-frame dark content is not treated as encoded bars', () {
    const width = 320;
    const height = 180;
    final rgba = _solidFrame(width, height, value: 18);

    // Keep every edge from being a uniform encoded-black line.
    for (var x = 0; x < width; x += 5) {
      for (final y in <int>[0, height - 1]) {
        final offset = ((y * width) + x) * 4;
        rgba[offset] = 55;
        rgba[offset + 1] = 45;
        rgba[offset + 2] = 40;
      }
    }

    expect(
      VideoBlackBarCropService.detectFromRgba(
        rgba: rgba,
        width: width,
        height: height,
      ),
      isNull,
    );
  });

  test('crop consensus requires matching decoded frames', () {
    const a = VideoCropRect(width: 1920, height: 816, x: 0, y: 132);
    const b = VideoCropRect(width: 1920, height: 820, x: 0, y: 130);
    const outlier = VideoCropRect(width: 1600, height: 900, x: 160, y: 90);

    final crop = VideoBlackBarCropService.consensus(
      const <VideoCropRect>[a, b, outlier],
      sourceWidth: 1920,
      sourceHeight: 1080,
    );

    expect(crop, isNotNull);
    expect(crop!.width, greaterThanOrEqualTo(1918));
    expect(crop.height, inInclusiveRange(816, 822));
  });

  test('tiny codec edges are not auto-cropped', () {
    const crop = VideoCropRect(width: 1916, height: 1076, x: 2, y: 2);
    expect(
      crop.isMeaningful(encodedWidth: 1920, encodedHeight: 1080),
      isFalse,
    );
  });

  test('strongly asymmetric dark-scene detection is rejected', () {
    const crop = VideoCropRect(width: 1600, height: 900, x: 0, y: 0);
    expect(
      crop.isMeaningful(encodedWidth: 1920, encodedHeight: 1080),
      isFalse,
    );
  });
}
