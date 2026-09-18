import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala guest translation preflights against opened paused media', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));

    // DetailsScreen must not probe the P2P stream before PlayerScreen owns it.
    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    // PlayerScreen opens media paused, then checks embedded timing first.
    expect(player, contains('play: !aiPreferred'));
    expect(player, contains('_prepareAiSinhalaBeforePlayback'));
    expect(player, contains('final embeddedReady = await _tryPrepareEmbeddedAiTiming();'));
    expect(player, contains('await _restoreNativeSubtitleFallback();'));
    expect(playback, contains('bool play = true'));
    expect(playback, contains('play: play'));

    // Embedded subtitle preparation must never pause/resume an already running movie.
    expect(player, isNot(contains('final wasPlaying = player.state.playing;')));
  });
}
