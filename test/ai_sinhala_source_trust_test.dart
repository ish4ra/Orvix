import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OpenSubtitles is used only as a transcript corpus, not a timing oracle', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final startupStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final startupEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', startupStart);
    final startup = player.substring(startupStart, startupEnd);

    expect(startup, contains('_captureNativeEnglishSamples()'));
    expect(startup, contains('OnlineSubtitleService.search('));
    expect(startup, contains('videoHash: null'));
    expect(startup, isNot(contains('final chosen = english.first;')));
    expect(
      startup,
      contains('prepareTranslatedTranscriptForNativeTiming('),
    );
  });

  test('transcript acceptance requires multiple sequential native dialogue matches', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('selectedMatches < 3'));
    expect(service, contains('searchFrom = bestIndex + 1'));
    expect(service, contains('bestSimilarity < .62'));
    expect(
      service,
      contains("sourceMatch: 'native-cue-text-oracle'"),
    );
  });

  test('runtime matching is sequence-aware and seek recovery is exact-only globally', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('int matchSourceCueIndex('));
    expect(service, contains('previousIndex + 180'));
    expect(service, contains('previousIndex - 3'));
    expect(service, contains('if (previousIndex >= 0)'));
    expect(service, contains('_normalizeCue(cues[i].source) == target'));
  });

  test('automatic native mode has no exact-hash or external-SRT fallback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, isNot(contains('prepareGeneratedSinhalaFile(')));
    expect(startup, isNot(contains('mk.SubtitleTrack.uri(')));
  });
}
