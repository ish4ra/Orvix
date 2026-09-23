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
        '          !Platform.isWindows &&\n'
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

  test('every Windows AI source stays inside the standalone media engine', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final engine =
        File('tools/orvix-media-engine/main.go').readAsStringSync();

    // The gate must NOT depend on useLocalMediaBridge. Direct HTTP is ranked
    // first by free-stream ordering and local free-P2P arrives on :11470.
    expect(
      details,
      contains('final windowsAiEngine = Platform.isWindows && aiSettingEnabled;'),
    );
    expect(details, isNot(contains('Platform.isWindows && useLocalMediaBridge && aiSettingEnabled')));
    expect(details, contains('if (windowsAiEngine) {'));
    expect(details, contains('playbackUrl = enginePlaybackUrl;'));
    expect(details, contains('releaseLocalP2pOnExit: originalLocalP2p'));
    expect(
      details,
      contains('AI Sinhala preparation failed before playback:'),
    );
    expect(engine, contains('mux.HandleFunc("/media/"'));
    expect(engine, contains('"playbackProxy"'));
    expect(engine, contains('s.activeStreams++'));
  });

  test('Windows PlayerScreen refuses legacy in-player AI fallback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('final missingWindowsPreflight = Platform.isWindows'));
    expect(
      player,
      contains('AI Sinhala startup was blocked because Windows pre-player preparation was bypassed.'),
    );
    expect(
      player,
      contains('final usePlayerPreflight = aiPreferred &&\n'
          '          !Platform.isWindows &&'),
    );
  });

  test('direct HTTP and local P2P enter the same Windows AI preflight', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    final directOpen = details.indexOf("_status = 'Opening direct stream…';");
    final aiGate = details.indexOf('final windowsAiEngine =');
    final enginePrepare =
        details.indexOf('OrvixMediaEngineService.instance.prepare(');
    expect(directOpen, greaterThanOrEqualTo(0));
    expect(aiGate, greaterThan(directOpen));
    expect(enginePrepare, greaterThan(aiGate));

    expect(details, contains('originalUri.port == 11470'));
    expect(
      details,
      contains('await LocalTorrentService.instance.releaseCurrentStream();'),
    );
  });

  test('PikPak AI path requests the original container, never the default transcode', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final pikpak =
        File('lib/services/pikpak_transfer_service.dart').readAsStringSync();

    expect(details, contains('preferOriginal: windowsAi'));
    expect(
      details,
      contains('AI Sinhala • requesting the original PikPak container…'),
    );
    expect(
      details,
      contains('AI Sinhala • resolving the original PikPak container…'),
    );
    expect(details, contains('expectedVideoHash: source?.videoHash'));
    expect(details, contains('expectedSizeBytes: source?.sizeBytes'));

    final originalBranch = pikpak.indexOf('if (preferOriginal) {');
    final originChoice =
        pikpak.indexOf("media['is_origin'] == true", originalBranch);
    final defaultChoice =
        pikpak.indexOf("media['is_default'] == true", originalBranch);
    expect(originalBranch, greaterThanOrEqualTo(0));
    expect(originChoice, greaterThan(originalBranch));
    expect(defaultChoice, greaterThan(originChoice));
  });

  test('PikPak cloud task preserves addon exact-file identity metadata', () {
    final source =
        File('lib/services/source_provider_service.dart').readAsStringSync();
    final pikpak =
        File('lib/services/pikpak_transfer_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(source, contains('x-orvix-video-hash=\$videoHash'));
    expect(pikpak, contains("case 'x-orvix-video-hash':"));
    expect(pikpak, contains('final String? videoHash;'));
    expect(details, contains('source: chosen'));
    expect(details, contains('expectedVideoHash: source?.videoHash'));
  });

  test('Windows PikPak AI refuses transcode-only playback instead of guessing', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(
      details,
      contains(
        'Only a provider rendition/transcode is available, so Orvix cannot safely recover embedded subtitles or an exact-file hash.',
      ),
    );
    expect(
      details,
      contains(
        'AI Sinhala requires the original container so embedded subtitles and exact-file fingerprinting remain valid.',
      ),
    );
  });

  test('Windows AI cannot autoplay before verified Sinhala attach', () {
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      playback,
      contains('Platform.isWindows &&\n        play &&\n        await AiSinhalaPreferencesService.isEnabled()'),
    );
    expect(
      playback,
      contains('Windows AI Sinhala blocked unprepared autoplay at PlaybackService.'),
    );

    expect(player, contains('Sinhala subtitle is ready. Attaching it to MPV before playback…'));
    expect(player, contains('for (var attempt = 0; attempt < 24 && !_closing; attempt++)'));
    expect(player, contains("selectedLanguage == 'si'"));
    expect(player, contains("selectedTitle.contains('ai sinhala')"));
    expect(
      player,
      contains('Playback was kept paused instead of starting without Sinhala subtitles.'),
    );

    final attach = player.indexOf('player-attach-confirmed language=si');
    final play = player.indexOf('player-play allowed aiReady=');
    expect(attach, greaterThanOrEqualTo(0));
    expect(play, greaterThan(attach));
  });

  test('generated Sinhala cache rejects stale non-Sinhala SRT files', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains("srt-v6-verified-attach"));
    expect(service, contains("RegExp(r'[\\u0D80-\\u0DFF]')"));
    expect(service, contains('if (sinhalaChars < 8) return null;'));
    expect(
      service,
      contains('The generated subtitle did not contain enough Sinhala text'),
    );
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
