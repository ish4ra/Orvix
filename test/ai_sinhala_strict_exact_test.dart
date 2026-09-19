import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native calibration retimes the whole candidate before translation', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(
      service,
      contains('prepareGeneratedSinhalaFromNativeCalibration'),
    );
    expect(service, contains('_calibrateAgainstNativeSamples('));
    expect(service, contains('cue.start.inMilliseconds * selected.scale'));
    expect(service, contains('cue.end.inMilliseconds * selected.scale'));
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));
  });

  test('strict exact-file mode remains available as fallback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'static Future<AiGeneratedSubtitleFile> prepareGeneratedSinhalaFile',
    );
    expect(start, greaterThanOrEqualTo(0));
    final tail = service.substring(start);

    expect(tail, contains('_probeVideo('));
    expect(tail, contains('_fetchExactRestSubtitle('));
    expect(tail, contains('_parseSubtitle(exactText)'));
  });

  test('generated SRT is loaded after calibration while media is paused', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    final mediaOpen = open.indexOf('await widget.playback.open(');
    final prepare = open.indexOf('await _prepareAiSinhalaBeforePlayback()');
    final subtitleLoad = open.indexOf('mk.SubtitleTrack.uri(');
    expect(mediaOpen, greaterThanOrEqualTo(0));
    expect(prepare, greaterThan(mediaOpen));
    expect(subtitleLoad, greaterThan(prepare));
  });
}
