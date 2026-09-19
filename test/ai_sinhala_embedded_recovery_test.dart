import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic startup uses the native English track as timing ground truth', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final prepareEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', prepareStart);
    expect(openStart, greaterThanOrEqualTo(0));
    expect(prepareStart, greaterThan(openStart));
    expect(prepareEnd, greaterThan(prepareStart));

    final open = player.substring(openStart, prepareStart);
    final prepare = player.substring(prepareStart, prepareEnd);

    expect(
      open.indexOf('await widget.playback.open('),
      lessThan(open.indexOf('await _prepareAiSinhalaBeforePlayback()')),
    );
    expect(open, contains('play: !aiPreferred'));
    expect(prepare, contains('_captureNativeEnglishSamples()'));
    expect(prepare, contains('OnlineSubtitleService.search('));
    expect(
      prepare,
      contains('prepareGeneratedSinhalaFromNativeCalibration('),
    );
    expect(prepare, contains('prepareGeneratedSinhalaFile('));
    expect(prepare, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback')));

    expect(open, contains('mk.SubtitleTrack.uri('));
    expect(open, contains("language: 'si'"));
  });

  test('native cue preflight stays hidden and restores playback state', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<List<AiNativeCueSample>> _captureNativeEnglishSamples()');
    final end =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()', start);
    final capture = player.substring(start, end);

    expect(capture, contains('_preflightWarmup = true;'));
    expect(capture, contains('await player.setVolume(0);'));
    expect(capture, contains('await player.setRate(4.0);'));
    expect(capture, contains('await player.pause();'));
    expect(capture, contains('await player.setRate(originalRate);'));
    expect(capture, contains('await player.seek(originalPosition);'));
    expect(capture, contains('await player.setVolume(originalVolume);'));
  });
}
