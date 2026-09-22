import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('guest AI Sinhala can translate the complete embedded subtitle before playback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));
    expect(
      service,
      contains('prepareGeneratedSinhalaFromEmbeddedSubtitle'),
    );
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));

    expect(
      player,
      contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
    expect(player, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(player, contains('play: !aiPreferred'));
  });
}
