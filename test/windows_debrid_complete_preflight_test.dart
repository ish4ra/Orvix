import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows debrid AI is held while the feature remains beta', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final playback = File('lib/services/playback_service.dart').readAsStringSync();

    expect(
      details,
      contains('final windowsDebridCompleteSubtitlePreflight = false;'),
    );
    expect(
      details,
      contains('aiSinhalaEnabled: aiEnabled && !useLocalMediaBridge'),
    );
    expect(
      details,
      contains('aiPreflightAttempted: useLocalMediaBridge ? false : aiPreflightAttempted'),
    );
    expect(
      details,
      contains('aiPreflightFailure: useLocalMediaBridge ? null : aiPreflightFailure'),
    );

    // Debrid/cloud users must always retain normal playback even if the global
    // AI Sinhala beta preference is enabled.
    expect(
      playback,
      isNot(contains('Windows AI Sinhala blocked unprepared autoplay')),
    );
  });

  test('Free P2P AI path stays separate from the held debrid path', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('final originalLocalP2p = originalUri != null'));
    expect(
      details,
      contains(
        'IMPORTANT: original Free P2P playback is explicitly excluded here.',
      ),
    );
    expect(
      details,
      contains('.prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
  });
}
