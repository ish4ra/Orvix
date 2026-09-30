import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('IntroDB skip integration covers both internal player engines', () {
    final service = File('lib/services/skip_segment_service.dart').readAsStringSync();
    final mpv = File('lib/screens/player_screen.dart').readAsStringSync();
    final exo = File('lib/screens/android_exo_player_screen.dart').readAsStringSync();

    expect(service, contains("'api.introdb.app'"));
    expect(service, contains("'/segments'"));
    expect(service, contains("query['is_movie'] = 'true'"));
    expect(service, contains("value.contains(':')"));
    expect(service, contains("'post_credits'"));
    expect(mpv, contains('_loadSkipSegments()'));
    expect(mpv, contains('_skipActiveSegment()'));
    expect(mpv, contains('onPressed: _skipActiveSegment'));
    expect(mpv, contains('_activeSkipSegment != null && !_skipSegmentDismissed'));
    expect(exo, contains('_loadSkipSegments()'));
    expect(exo, contains('_skipActiveSegment()'));
    expect(exo, contains('onPressed: _skipActiveSegment'));
    expect(exo, contains('_activeSkipSegment != null && !_skipDismissed'));
  });

  test('skip seek targets are clamped before media duration', () {
    final mpv = File('lib/screens/player_screen.dart').readAsStringSync();
    final exo = File('lib/screens/android_exo_player_screen.dart').readAsStringSync();

    expect(mpv, contains("duration - const Duration(milliseconds: 1)"));
    expect(exo, contains("duration - const Duration(milliseconds: 1)"));
  });
}
