import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic startup fingerprints the actual video before playback', () {
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
      open.indexOf('await _prepareAiSinhalaBeforePlayback()'),
      lessThan(open.indexOf('await widget.playback.open(')),
    );
    expect(prepare, contains('prepareGeneratedSinhalaFile('));
    expect(prepare, contains('videoUrl: widget.url'));
    expect(prepare, isNot(contains('OnlineSubtitleService.search(')));
    expect(prepare, isNot(contains('prepareGeneratedSinhalaFromOnlineSubtitle(')));
    expect(prepare, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback')));

    expect(open, contains('mk.SubtitleTrack.uri('));
    expect(open, contains("language: 'si'"));
  });

  test('failed exact preflight opens normal playback without track recovery loops', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    expect(open, contains('play: !aiReady'));
    expect(open, isNot(contains('await _restoreNativeSubtitleFallback();')));
  });
}
