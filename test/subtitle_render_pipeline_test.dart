import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala opening buffer is chunked below backend batch limit', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('final firstEnd = math.min(96,'));
    expect(
      service,
      contains('await _translateMissingIndices(prepared, indices);'),
    );
    expect(service, contains('const batchSize = 36;'));
  });

  test('text subtitles have one renderer and responsive sizing', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('double _effectiveSubtitleFontSize(BuildContext context)'));
    expect(player, contains('fontSize: _effectiveSubtitleFontSize(context)'));
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(_isImageSubtitleTrack(chosen));'),
    );
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(_isImageSubtitleTrack(track));'),
    );
    expect(player, contains('visible: !_aiSinhalaRequested'));
  });
}
