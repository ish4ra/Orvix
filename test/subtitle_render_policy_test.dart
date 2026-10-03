import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_render_policy.dart';

void main() {
  group('SubtitleRenderPolicy', () {
    test('Android normal text subtitles use Flutter overlay only', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: false,
          isAndroid: true,
          isNativePlayer: true,
        ),
        isTrue,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: false,
        ),
        isFalse,
      );
    });

    test('Android bitmap subtitles keep native renderer enabled', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: false,
          isAndroid: true,
          isNativePlayer: true,
        ),
        isTrue,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: true,
        ),
        isTrue,
      );
    });

    test('desktop native playback preserves native subtitle rendering', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: false,
          isAndroid: false,
          isNativePlayer: true,
        ),
        isFalse,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: false,
          isBitmapTrack: false,
        ),
        isTrue,
      );
    });

    test('AI Sinhala suppresses source Flutter overlay', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: true,
          isAndroid: true,
          isNativePlayer: true,
        ),
        isFalse,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: true,
          isAndroid: true,
          isBitmapTrack: false,
        ),
        isTrue,
      );
    });

    test('requested hidden always keeps native subtitles hidden', () {
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: false,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: true,
        ),
        isFalse,
      );
    });
  });
}
