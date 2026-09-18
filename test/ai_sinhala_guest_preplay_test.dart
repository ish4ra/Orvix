import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala guest translation prepares before playback and fails open safely', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));

    // alpha.11: AI Sinhala is prepared before navigation to PlayerScreen.
    expect(details, contains('AiSinhalaSubtitleService.prepareBuffered('));
    expect(details, contains('aiSubtitle: preparedAiSubtitle'));

    // If preparation fails, PlayerScreen must not hide native subtitles.
    expect(player, contains('final aiReady = _preparedAiSubtitle != null;'));
    expect(player, contains('await _setNativeSubtitleVisibility(!aiReady);'));
    expect(
      player,
      isNot(contains('unawaited(_prepareAiSinhalaAfterPlaybackStarts());')),
    );

    // Embedded subtitle preparation must never pause/resume the movie itself.
    expect(player, isNot(contains('final wasPlaying = player.state.playing;')));
  });
}
