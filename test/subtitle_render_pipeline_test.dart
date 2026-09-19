import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('whole subtitle translation is batched and must finish before SRT write', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('static Future<void> _translateEntireSubtitle('));
    expect(service, contains('const batchSize = 60;'));
    expect(
      service,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
    expect(service, contains('_writeGeneratedSrt('));
  });

  test('text subtitles have one renderer and responsive sizing', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('double _effectiveSubtitleFontSize(BuildContext context)'));
    expect(player, contains('fontSize: _effectiveSubtitleFontSize(context)'));
    expect(player, contains('await _setNativeSubtitleVisibility(false);'));
    expect(player, contains('visible: !_aiSinhalaRequested'));
    expect(player, contains('mk.SubtitleTrack.uri('));
  });
}
