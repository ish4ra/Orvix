import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('guest AI Sinhala supports progressive native cue translation', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
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
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );
    expect(player, contains('_activateProgressiveNativeCueAi('));
    expect(player, contains('_enableEmbeddedLiveAiFallback('));
    expect(player, contains('translateCue('));
    expect(player, contains('play: !(aiReady || useProgressiveNativeCueAi)'));
  });
}
