import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';

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

    // cropdetect should report a roughly centered active picture. Reject
    // strongly asymmetric detections so a dark scene/object cannot become a
    // permanent crop.
    final right = fullWidth - width - x;
    final bottom = fullHeight - height - y;
    final xTolerance = (fullWidth * .05).round();
    final yTolerance = (fullHeight * .05).round();
    if ((x - right).abs() > xTolerance || (y - bottom).abs() > yTolerance) {
      return false;
    }

    return true;
  }
}

class VideoBlackBarCropService {
  VideoBlackBarCropService._();

  static final RegExp _cropPattern =
      RegExp(r'crop=(\d+):(\d+):(\d+):(\d+)');

  static Future<VideoCropRect?> detect({
    required String url,
    int? encodedWidth,
    int? encodedHeight,
  }) async {
    if (!Platform.isAndroid || url.trim().isEmpty) return null;

    // Keep this probe short and bounded. Sampling a moving window rather than
    // the first frames avoids treating fade-to-black intros as letterbox bars.
    final session = await FFmpegKit.executeWithArguments(<String>[
      '-hide_banner',
      '-loglevel',
      'info',
      '-rw_timeout',
      '8000000',
      '-ss',
      '12',
      '-i',
      url,
      '-t',
      '8',
      '-map',
      '0:v:0',
      '-an',
      '-sn',
      '-vf',
      'cropdetect=24:16:0',
      '-f',
      'null',
      '-',
    ]);

    final output = await session.getAllLogsAsString();
    if (output == null || output.isEmpty) return null;

    final counts = <String, int>{};
    final rects = <String, VideoCropRect>{};
    for (final match in _cropPattern.allMatches(output)) {
      final rect = VideoCropRect(
        width: int.parse(match.group(1)!),
        height: int.parse(match.group(2)!),
        x: int.parse(match.group(3)!),
        y: int.parse(match.group(4)!),
      );
      if (!rect.isMeaningful(
        encodedWidth: encodedWidth,
        encodedHeight: encodedHeight,
      )) {
        continue;
      }
      final key = rect.ffmpegValue;
      counts[key] = (counts[key] ?? 0) + 1;
      rects[key] = rect;
    }

    if (counts.isEmpty) return null;
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;

    // Require repeated agreement from cropdetect before changing the picture.
    if (best.value < 4) return null;
    return rects[best.key];
  }
}
