import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('guest AI Sinhala translates one complete selected subtitle before playback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));
    expect(
      service,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle'),
    );
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));

    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    expect(player, contains('play: !aiReady'));
    expect(player, contains('_prepareAiSinhalaBeforePlayback'));
    expect(player, contains('OnlineSubtitleService.search('));
    expect(
      player,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle('),
    );
    expect(player, contains('mk.SubtitleTrack.uri('));
    expect(playback, contains('bool play = true'));
    expect(playback, contains('play: play'));
  });
}
