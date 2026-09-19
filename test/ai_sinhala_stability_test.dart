import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';

void main() {
  test('automatic AI Sinhala uses an exact generated file, not live translation', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('prepareGeneratedSinhalaFile('));
    expect(startup, isNot(contains('_translateLiveSubtitleCue')));
    expect(startup, isNot(contains('_handleEmbeddedSubtitleCue')));
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));
    expect(
      service,
      contains("sourceMatch: 'rest-moviehash+moviebytesize-generated-srt'"),
    );
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });

  test('exact generated file cache is keyed by actual hash and byte size', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains("'exact-video|"));
    expect(service, contains('probe.hash'));
    expect(service, contains('probe.size'));
    expect(service, contains("'srt-v3-exact-video'"));
  });
}
