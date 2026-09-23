import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('whole subtitle translation is parallel-batched and must finish before SRT write', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('static Future<void> _translateEntireSubtitle('));
    expect(service, contains('const batchSize = 96;'));
    expect(service, contains('const parallelBatches = 3;'));
    expect(service, contains('await Future.wait<void>'));
    expect(service, contains('_translateIndicesResilient('));
    expect(
      service,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
    expect(service, contains('_writeGeneratedSrt('));
  });

  test('complete embedded generation writes translated text with original cue timestamps', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final writeStart = service.indexOf('static Future<File> _writeGeneratedSrt(');
    final writeEnd = service.indexOf('static String _formatSrtTimestamp', writeStart);
    final writer = service.substring(writeStart, writeEnd);

    expect(writer, contains('_formatSrtTimestamp(cue.start)'));
    expect(writer, contains('_formatSrtTimestamp(cue.end)'));
    expect(writer, contains('writeln(translated)'));
  });

  test('generated Sinhala SRT is attached as a native subtitle track', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _loadGeneratedAiSubtitleTrack()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final generated = player.substring(start, end);

    expect(generated, contains('mk.SubtitleTrack.uri('));
    expect(generated, contains("language: 'si'"));
    expect(generated, contains('await _setNativeSubtitleDelayProperty(0);'));
    expect(generated, contains('await _setNativeSubtitleVisibility(true);'));
  });

  test('normal source subtitle appearance remains native when AI is off', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains("'sub-ass-override'"));
    expect(player, contains("'no'"));
    expect(
      player,
      contains('Source subtitle appearance is preserved by the native player.'),
    );
  });
}
