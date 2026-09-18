import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala guest and pre-play wiring stays enabled', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains("'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));
    expect(details, contains('AiSinhalaPreferencesService.isEnabled()'));
    expect(details, contains('AiSinhalaSubtitleService.prepareBuffered('));
    expect(details, contains('aiSubtitle: preparedAiSubtitle'));
    expect(
      details,
      contains('Finding source-matched English subtitles'),
    );
  });
}
