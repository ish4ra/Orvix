import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup uses ranked online English subtitle instead of embedded/live AI', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final startup = player.substring(start, end);

    expect(startup, contains('OnlineSubtitleService.search('));
    expect(startup, contains("preferredLanguage: 'eng'"));
    expect(
      startup,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle('),
    );
    expect(startup, contains('mk.SubtitleTrack.uri('));
    expect(startup, contains("language: 'si'"));
    expect(startup, isNot(contains('_fetchEmbeddedEnglishSubtitle')));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback')));
    expect(startup, isNot(contains('translateCue(')));
  });

  test('failed automatic AI preflight does not mutate native subtitle tracks', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    expect(openStart, greaterThanOrEqualTo(0));
    expect(prepareStart, greaterThan(openStart));
    final open = player.substring(openStart, prepareStart);

    expect(
      open,
      contains('A failed AI preflight\n          // must leave normal playback untouched'),
    );
    expect(open, isNot(contains('await _restoreNativeSubtitleFallback();')));
  });
}
