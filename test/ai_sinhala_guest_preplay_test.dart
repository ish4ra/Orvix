import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala guest translation stays enabled without blocking playback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));

    // Playback must open first. Subtitle preparation now runs in PlayerScreen.
    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));
    expect(player, contains('AiSinhalaPreferencesService.isEnabled()'));
    expect(player, contains('AiSinhalaSubtitleService.prepareBuffered('));
    expect(player, contains('_prepareAiSinhalaAfterPlaybackStarts'));

    // Embedded subtitle preparation must never pause/resume the movie itself.
    expect(player, isNot(contains('final wasPlaying = player.state.playing;')));
  });
}
