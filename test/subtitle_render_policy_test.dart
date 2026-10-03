import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_render_policy.dart';

void main() {
  group('SubtitleRenderPolicy', () {
    test('Android Mobile text subtitles use configured native styled renderer', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: false,
          isAndroid: true,
          isNativePlayer: true,
          nativeStyledSubtitles: true,
        ),
        isFalse,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: false,
          nativeStyledSubtitles: true,
        ),
        isTrue,
      );
    });

    test('Android fallback path keeps text in Flutter and bitmap native', () {
      expect(
        SubtitleRenderPolicy.flutterOverlayVisible(
          aiSinhalaRequested: false,
          isAndroid: true,
          isNativePlayer: true,
          nativeStyledSubtitles: false,
        ),
        isTrue,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: false,
          nativeStyledSubtitles: false,
        ),
        isFalse,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: true,
          nativeStyledSubtitles: false,
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
          nativeStyledSubtitles: false,
        ),
        isFalse,
      );
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: true,
          aiSinhalaRequested: false,
          isAndroid: false,
          isBitmapTrack: false,
          nativeStyledSubtitles: false,
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
          nativeStyledSubtitles: true,
        ),
        isFalse,
      );
    });

    test('requested hidden always keeps native subtitles hidden', () {
      expect(
        SubtitleRenderPolicy.nativeSubtitleVisible(
          requestedVisible: false,
          aiSinhalaRequested: false,
          isAndroid: true,
          isBitmapTrack: true,
          nativeStyledSubtitles: true,
        ),
        isFalse,
      );
    });
  });
}
