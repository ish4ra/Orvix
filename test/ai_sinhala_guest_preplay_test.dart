import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala guest translation preflights exact file before playback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));
    expect(service, contains('prepareExactFileFully('));

    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    expect(player, contains('play: !aiPreferred'));
    expect(player, contains('_prepareAiSinhalaBeforePlayback'));
    expect(player, contains('prepareExactFileFully('));
    expect(player, contains('await _restoreNativeSubtitleFallback();'));
    expect(playback, contains('bool play = true'));
    expect(playback, contains('play: play'));
  });
}
