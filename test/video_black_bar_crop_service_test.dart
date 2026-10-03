import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/video_black_bar_crop_service.dart';

void main() {
  test('letterboxed 2.35 picture inside 16:9 is a meaningful crop', () {
    const crop = VideoCropRect(width: 1920, height: 816, x: 0, y: 132);
    expect(
      crop.isMeaningful(encodedWidth: 1920, encodedHeight: 1080),
      isTrue,
    );
    expect(crop.mpvValue, '1920x816+0+132');
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
