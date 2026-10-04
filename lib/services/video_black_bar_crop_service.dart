import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart' as mk;

class VideoCropRect {
  const VideoCropRect({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
  });

  final int width;
  final int height;
  final int x;
  final int y;

  String get mpvValue => '${width}x$height+$x+$y';

  String get ffmpegValue => '$width:$height:$x:$y';

  int get right => x + width;
  int get bottom => y + height;

  VideoCropRect scaleTo({
    required int fromWidth,
    required int fromHeight,
    required int toWidth,
    required int toHeight,
  }) {
    if (fromWidth <= 0 ||
        fromHeight <= 0 ||
        toWidth <= 0 ||
        toHeight <= 0 ||
        (fromWidth == toWidth && fromHeight == toHeight)) {
      return this;
    }

    int even(double value) {
      final rounded = value.round().clamp(0, 1 << 30).toInt();
      return rounded.isEven
          ? rounded
          : (rounded - 1).clamp(0, 1 << 30).toInt();
    }

    final left = even(x * toWidth / fromWidth);
    final top = even(y * toHeight / fromHeight);
    final rightEdge = even(right * toWidth / fromWidth);
    final bottomEdge = even(bottom * toHeight / fromHeight);

    return VideoCropRect(
      width: (rightEdge - left).clamp(2, toWidth).toInt(),
      height: (bottomEdge - top).clamp(2, toHeight).toInt(),
      x: left,
      y: top,
    );
  }

  bool isMeaningful({
    int? encodedWidth,
    int? encodedHeight,
  }) {
    final fullWidth = (encodedWidth ?? 0) > 0 ? encodedWidth! : width + (x * 2);
    final fullHeight =
        (encodedHeight ?? 0) > 0 ? encodedHeight! : height + (y * 2);
    if (fullWidth <= 0 || fullHeight <= 0) return false;
    if (width <= 0 || height <= 0 || width > fullWidth || height > fullHeight) {
      return false;
    }

    final removedX = (fullWidth - width) / fullWidth;
    final removedY = (fullHeight - height) / fullHeight;
    final area = (width * height) / (fullWidth * fullHeight);

    // Ignore codec alignment and tiny dark edges. Auto-crop is only for a
    // clearly letterboxed/pillarboxed source such as a 2.35:1 picture encoded
    // inside a 16:9 frame.
    if (removedX < .08 && removedY < .08) return false;
    if (area < .60) return false;

    // Real encoded bars should be approximately centered. This rejects a dark
    // object/scene edge from becoming a permanent crop.
    final rightMargin = fullWidth - width - x;
    final bottomMargin = fullHeight - height - y;
    final xTolerance = (fullWidth * .05).round();
    final yTolerance = (fullHeight * .05).round();
    if ((x - rightMargin).abs() > xTolerance ||
        (y - bottomMargin).abs() > yTolerance) {
      return false;
    }

    return true;
  }

  bool isHorizontalLetterbox({
    required int encodedWidth,
    required int encodedHeight,
  }) {
    if (!isMeaningful(
      encodedWidth: encodedWidth,
      encodedHeight: encodedHeight,
    )) {
      return false;
    }

    final removedX = (encodedWidth - width) / encodedWidth;
    final removedY = (encodedHeight - height) / encodedHeight;
    if (removedY < .08 || removedX > .03) return false;

    final frameAspect = encodedWidth / encodedHeight;
    final activeAspect = width / height;
    return activeAspect >= frameAspect * 1.08;
  }
}

class VideoBlackBarCropService {
  VideoBlackBarCropService._();

  // Compressed black bars are not always mathematically 0,0,0. Keep the
  // threshold conservative, then rely on multi-frame consensus and centered
  // margins to reject dark scene content.
  static const int _nearBlack = 36;
  static const double _blackLineRatio = .96;

  static bool _isNearBlack(Uint8List rgba, int offset) {
    return rgba[offset] <= _nearBlack &&
        rgba[offset + 1] <= _nearBlack &&
        rgba[offset + 2] <= _nearBlack;
  }

  static double _rowBlackRatio(
    Uint8List rgba,
    int width,
    int height,
    int y,
  ) {
    if (width <= 0 || height <= 0 || y < 0 || y >= height) return 0;
    final stride = width > 640 ? 3 : width > 320 ? 2 : 1;
    var dark = 0;
    var total = 0;
    for (var x = 0; x < width; x += stride) {
      final offset = ((y * width) + x) * 4;
      if (_isNearBlack(rgba, offset)) dark++;
      total++;
    }
    return total == 0 ? 0 : dark / total;
  }

  static double _columnBlackRatio(
    Uint8List rgba,
    int width,
    int height,
    int x,
  ) {
    if (width <= 0 || height <= 0 || x < 0 || x >= width) return 0;
    final stride = height > 640 ? 3 : height > 320 ? 2 : 1;
    var dark = 0;
    var total = 0;
    for (var y = 0; y < height; y += stride) {
      final offset = ((y * width) + x) * 4;
      if (_isNearBlack(rgba, offset)) dark++;
      total++;
    }
    return total == 0 ? 0 : dark / total;
  }

  static int _scanTop(Uint8List rgba, int width, int height) {
    final limit = (height * .32).floor();
    var edge = 0;
    while (edge < limit &&
        _rowBlackRatio(rgba, width, height, edge) >= _blackLineRatio) {
      edge++;
    }
    return edge;
  }

  static int _scanBottom(Uint8List rgba, int width, int height) {
    final limit = (height * .32).floor();
    var removed = 0;
    while (removed < limit &&
        _rowBlackRatio(
              rgba,
              width,
              height,
              height - 1 - removed,
            ) >=
            _blackLineRatio) {
      removed++;
    }
    return removed;
  }

  static int _scanLeft(Uint8List rgba, int width, int height) {
    final limit = (width * .32).floor();
    var edge = 0;
    while (edge < limit &&
        _columnBlackRatio(rgba, width, height, edge) >= _blackLineRatio) {
      edge++;
    }
    return edge;
  }

  static int _scanRight(Uint8List rgba, int width, int height) {
    final limit = (width * .32).floor();
    var removed = 0;
    while (removed < limit &&
        _columnBlackRatio(
              rgba,
              width,
              height,
              width - 1 - removed,
            ) >=
            _blackLineRatio) {
      removed++;
    }
    return removed;
  }

  static VideoCropRect? detectFromRgba({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return null;
    }

    final top = _scanTop(rgba, width, height);
    final bottom = _scanBottom(rgba, width, height);
    final left = _scanLeft(rgba, width, height);
    final right = _scanRight(rgba, width, height);

    final crop = VideoCropRect(
      width: width - left - right,
      height: height - top - bottom,
      x: left,
      y: top,
    );
    return crop.isMeaningful(
      encodedWidth: width,
      encodedHeight: height,
    )
        ? crop
        : null;
  }

  static Future<VideoCropRect?> _decodeScreenshot(
    File file, {
    required int sourceWidth,
    required int sourceHeight,
  }) async {
    if (!await file.exists() || await file.length() == 0) return null;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final detected = detectFromRgba(
        rgba: byteData.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
      if (detected == null) return null;
      return detected.scaleTo(
        fromWidth: image.width,
        fromHeight: image.height,
        toWidth: sourceWidth,
        toHeight: sourceHeight,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  static Future<bool> _waitForFile(File file) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      if (await file.exists() && await file.length() > 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  static bool _matches(
    VideoCropRect a,
    VideoCropRect b,
    int fullWidth,
    int fullHeight,
  ) {
    final toleranceX =
        (fullWidth * .025).round().clamp(2, 80).toInt();
    final toleranceY =
        (fullHeight * .025).round().clamp(2, 80).toInt();
    return (a.x - b.x).abs() <= toleranceX &&
        (a.y - b.y).abs() <= toleranceY &&
        (a.right - b.right).abs() <= toleranceX &&
        (a.bottom - b.bottom).abs() <= toleranceY;
  }

  static VideoCropRect? consensus(
    List<VideoCropRect> samples, {
    required int sourceWidth,
    required int sourceHeight,
  }) {
    if (samples.length < 2) return null;
    for (var i = 0; i < samples.length; i++) {
      final group = <VideoCropRect>[samples[i]];
      for (var j = i + 1; j < samples.length; j++) {
        if (_matches(
          samples[i],
          samples[j],
          sourceWidth,
          sourceHeight,
        )) {
          group.add(samples[j]);
        }
      }
      final requiredMatches = samples.length >= 4 ? 3 : 2;
      if (group.length < requiredMatches) continue;

      int median(List<int> values) {
        values.sort();
        return values[values.length ~/ 2];
      }

      final left = median(group.map((e) => e.x).toList());
      final top = median(group.map((e) => e.y).toList());
      final right = median(group.map((e) => e.right).toList());
      final bottom = median(group.map((e) => e.bottom).toList());
      final crop = VideoCropRect(
        width: right - left,
        height: bottom - top,
        x: left,
        y: top,
      );
      if (crop.isMeaningful(
        encodedWidth: sourceWidth,
        encodedHeight: sourceHeight,
      )) {
        return crop;
      }
    }
    return null;
  }

  static Future<VideoCropRect?> detectFromNativePlayer({
    required mk.NativePlayer platform,
    required Directory directory,
  }) async {
    if (!Platform.isAndroid) return null;

    Future<int> readDimensionAsync(List<String> properties) async {
      for (final property in properties) {
        try {
          final value = int.tryParse(
            (await platform.getProperty(
              property,
              waitForInitialization: false,
            ))
                .trim(),
          );
          if (value != null && value > 0) return value;
        } catch (_) {}
      }
      return 0;
    }

    final sourceWidth = await readDimensionAsync(
      const <String>['video-params/w', 'video-out-params/w', 'width'],
    );
    final sourceHeight = await readDimensionAsync(
      const <String>['video-params/h', 'video-out-params/h', 'height'],
    );
    if (sourceWidth <= 0 || sourceHeight <= 0) return null;

    // The old beta.49 detector reopened the remote/P2P URL with FFmpeg. That
    // can fail independently of playback (headers, localhost bridge state,
    // range behavior), which is exactly why a visible four-sided frame could
    // survive while the probe silently returned nothing. Capture the frames
    // already decoded by the active libmpv instance instead.
    try {
      await platform.setProperty(
        'screenshot-format',
        'png',
        waitForInitialization: false,
      );
      await platform.setProperty(
        'screenshot-sw',
        'yes',
        waitForInitialization: false,
      );
    } catch (_) {}

    final samples = <VideoCropRect>[];
    for (var sample = 0; sample < 5; sample++) {
      final file = File(
        '${directory.path}/orvix-active-frame-'
        '${DateTime.now().microsecondsSinceEpoch}-$sample.png',
      );
      try {
        if (await file.exists()) await file.delete();
        await platform.command(
          <String>['screenshot-to-file', file.path, 'video'],
          waitForInitialization: false,
          throwOnError: true,
        );
        if (await _waitForFile(file)) {
          final crop = await _decodeScreenshot(
            file,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
          );
          if (crop != null) samples.add(crop);
        }
      } catch (_) {
        // A failed snapshot must not interrupt playback.
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      if (sample < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 260));
      }
    }

    return consensus(
      samples,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
  }
}
