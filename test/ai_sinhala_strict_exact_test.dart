import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selected-subtitle mode preserves timestamps and writes a complete SRT', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'prepareGeneratedSinhalaFromOnlineSubtitle',
    );
    final end = service.indexOf(
      'static Future<AiGeneratedSubtitleFile> prepareGeneratedSinhalaFile',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final generated = service.substring(start, end);

    expect(generated, contains('_downloadSubtitle(cleanUrl)'));
    expect(generated, contains('_parseSubtitle(text)'));
    expect(generated, contains('_translateEntireSubtitle('));
    expect(generated, contains('_writeGeneratedSrt('));
    expect(
      generated,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
  });

  test('automatic preparation does not touch the player', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final prepare = player.substring(start, end);

    expect(
      prepare,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle('),
    );
    expect(prepare, isNot(contains('widget.playback.player')));
    expect(prepare, isNot(contains('_tryPrepareEmbeddedAiTiming()')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });

  test('generated SRT is loaded only after the media opens', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    final mediaOpen = open.indexOf('await widget.playback.open(');
    final subtitleLoad = open.indexOf('mk.SubtitleTrack.uri(');
    expect(mediaOpen, greaterThanOrEqualTo(0));
    expect(subtitleLoad, greaterThan(mediaOpen));
    expect(open, contains("language: 'si'"));
  });

  test('desktop subtitle scaling remains restrained', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        'return (base * heightScale * 1.08).clamp(24.0, 44.0).toDouble();',
      ),
    );
  });
}
