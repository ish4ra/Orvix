import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_render_policy.dart';

void main() {
  group('SubtitleRenderPolicy', () {
    test('native player preserves subtitles with native renderer', () {
      expect(SubtitleRenderPolicy.flutterOverlayVisible(aiSinhalaRequested: false, isNativePlayer: true), isFalse);
      expect(SubtitleRenderPolicy.nativeSubtitleVisible(requestedVisible: true), isTrue);
    });
    test('non-native fallback may use Flutter SubtitleView', () {
      expect(SubtitleRenderPolicy.flutterOverlayVisible(aiSinhalaRequested: false, isNativePlayer: false), isTrue);
    });
    test('AI Sinhala suppresses source Flutter overlay', () {
      expect(SubtitleRenderPolicy.flutterOverlayVisible(aiSinhalaRequested: true, isNativePlayer: true), isFalse);
    });
    test('requested hidden keeps native subtitles hidden', () {
      expect(SubtitleRenderPolicy.nativeSubtitleVisible(requestedVisible: false), isFalse);
    });
  });
}
