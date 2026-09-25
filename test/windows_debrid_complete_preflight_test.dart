import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows debrid AI completes the subtitle before opening MPV', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(
      details,
      contains('final windowsDebridCompleteSubtitlePreflight = Platform.isWindows'),
    );
    expect(details, contains('useLocalMediaBridge &&'));
    expect(details, contains('!originalLocalP2p &&'));
    expect(
      details,
      contains('.prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
    expect(
      details,
      contains(
        'AI Sinhala • complete Sinhala subtitle ready. Opening player…',
      ),
    );
    expect(details, contains('complete-preflight-start mode=debrid-11470'));
    expect(details, contains('warmForPlayback: true'));

    // A completed/failed preflight is terminal for AI selection in the player.
    // It must not silently fall back to live per-cue translation.
    expect(
      player,
      contains('preprepared == null &&\n          !widget.aiPreflightAttempted'),
    );
    expect(
      details,
      contains('aiPreflightFailure: aiPreflightFailure'),
    );

    // The remote helper must unwrap the exact signed provider URL instead of
    // recursively probing its own localhost proxy.
    expect(
      ai,
      contains("videoUri.queryParameters['d']"),
    );
    expect(
      ai,
      contains("'videoUrl': remoteMediaUrl"),
    );
  });

  test('debrid preflight cannot mutate the existing Free P2P playback branch', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    final blockStart =
        details.indexOf('final windowsDebridCompleteSubtitlePreflight');
    final legacyStart = details.indexOf(
      '// Dormant compatibility path for the retired standalone 11471 preflight.',
      blockStart,
    );
    final block = details.substring(blockStart, legacyStart);

    expect(block, contains('!originalLocalP2p'));
    expect(block, contains('!originalLocalP2p &&'));
    expect(
      details,
      contains(
        'IMPORTANT: original Free P2P playback is explicitly excluded here.',
      ),
    );
  });
}
