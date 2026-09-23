import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows AI Sinhala prepares before PlayerScreen is opened', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final mediaEngine =
        details.indexOf('OrvixMediaEngineService.instance.prepare(');
    final openPlayer = details.indexOf('await _openMpvPlayer(');

    expect(mediaEngine, greaterThanOrEqualTo(0));
    expect(openPlayer, greaterThan(mediaEngine));
    expect(
      details,
      contains('prepareGeneratedSinhalaFromEngineEmbedded('),
    );
    expect(
      details,
      contains('prepareGeneratedSinhalaFromExactFingerprint('),
    );
  });

  test('pre-player result disables player-driven sampling fallback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('preparedAiSubtitleFile'));
    expect(player, contains('aiPreflightAttempted'));
    expect(
      player,
      contains(
        'final usePlayerPreflight = aiPreferred &&\n'
        '          !widget.aiPreflightAttempted',
      ),
    );
    expect(
      player,
      contains(
        'Standalone pre-player preparation failed. Do not re-run the old',
      ),
    );
  });

  test('standalone engine is independent of MPV and exposes exact preparation', () {
    final engine =
        File('tools/orvix-media-engine/main.go').readAsStringSync();

    expect(engine, contains('"prePlayerPreparation"'));
    expect(engine, contains('"requiresPlayerForDiscovery"'));
    expect(engine, contains('exec.CommandContext(ctx, "ffprobe"'));
    expect(engine, contains('exec.CommandContext(extractCtx, "ffmpeg"'));
    expect(engine, contains('openSubtitlesFingerprint('));
  });

  test('Windows client launches bundled media engine on its own port', () {
    final service =
        File('lib/services/orvix_media_engine_service.dart').readAsStringSync();

    expect(service, contains("baseUrl = 'http://127.0.0.1:11471'"));
    expect(service, contains("bundledExeName = 'orvix-media-engine.exe'"));
    expect(service, contains("Uri.parse('\$baseUrl/prepare')"));
    expect(service, contains("'--idle-timeout'"));
  });
}
