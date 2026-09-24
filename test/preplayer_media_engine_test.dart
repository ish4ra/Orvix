import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows AI Sinhala no longer blocks on complete-file preflight', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );
    expect(
      details,
      contains('final nativeCueAi = aiSettingEnabled;'),
    );
    expect(
      player,
      contains('final useProgressiveNativeCueAi ='),
    );
    expect(
      player,
      contains('await _activateProgressiveNativeCueAi();'),
    );
  });

  test('native player cue discovery is the universal automatic AI path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('_activateProgressiveNativeCueAi('));
    expect(player, contains('_discoverNativeCueAiAfterPlayback()'));
    expect(player, contains('native-cue-ai-ready'));
    expect(player, contains('native-cue-ai-miss'));
    expect(
      player,
      isNot(contains('final missingWindowsPreflight = Platform.isWindows')),
    );
    expect(
      player,
      isNot(contains('final usePlayerPreflight = aiPreferred')),
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

  test('Windows AI source opens through the player-native cue architecture', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );
    expect(details, contains('nativeCueAi='));
    expect(
      player,
      contains(
        'subtitle tracks that the active demuxer reports',
      ),
    );
    expect(player, contains('_scheduleBufferedNativeCueAi('));
    expect(
      player,
      contains('prepareTrustedTranscriptForNativeClock('),
    );
  });

  test('Windows PlayerScreen accepts progressive native cue AI without preflight', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final runtime =
        File('lib/services/ai_sinhala_runtime_state.dart').readAsStringSync();

    expect(
      player,
      isNot(contains(
        'AI Sinhala startup was blocked because Windows pre-player preparation was bypassed.',
      )),
    );
    expect(
      player,
      contains('aiPreferred && preprepared == null'),
    );
    expect(
      runtime,
      contains('to == AiSinhalaRuntimeMode.liveEmbedded'),
    );
  });

  test('direct HTTP and local P2P share the same player-native AI path', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(details, contains('originalUri.port == 11470'));
    expect(details, contains('final nativeCueAi = aiSettingEnabled;'));
    expect(player, contains('_bestNativeEnglishTextTrack()'));
    expect(player, contains('_scheduleBufferedNativeCueAi('));
    expect(
      player,
      contains(
        'Do not stop/reopen/pause/seek the media.',
      ),
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

  test('progressive AI bounds startup wait and keeps playback available', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        'Duration maxWait = const Duration(milliseconds: 2200)',
      ),
    );
    expect(
      player,
      contains('play: !(aiReady || useProgressiveNativeCueAi)'),
    );
    expect(
      player,
      contains(
        'Playing normally while Orvix waits briefly for a native English subtitle track',
      ),
    );
    expect(
      player,
      contains('unawaited(_discoverNativeCueAiAfterPlayback());'),
    );
    expect(
      player,
      contains('await widget.playback.player.play();'),
    );
  });

  test('automatic native-cue discovery never warms by play-pause-seek', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _open() async');
    final end = player.indexOf('void _onPlaybackError', start);
    final open = player.substring(start, end);

    expect(open, isNot(contains('_primeSubtitleTracksForAiPreflight()')));
    expect(open, isNot(contains('_prepareAiSinhalaBeforePlayback()')));
    expect(open, isNot(contains('await widget.playback.player.pause();')));
    expect(
      player,
      contains(
        'Do not stop/reopen/pause/seek the media.',
      ),
    );
  });

  test('media_kit auto pseudo-track cannot masquerade as embedded English', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains("id != 'auto' && id != 'no'"));
    expect(
      player,
      contains('if (!_isRealSubtitleTrack(track) || _isImageSubtitleTrack(track))'),
    );
    expect(
      player,
      contains('.where(_isRealSubtitleTrack)'),
    );
    expect(
      player,
      contains('phase=cue-probe'),
    );
    expect(
      player,
      contains("phase: 'cue-probe'"),
    );
    expect(
      player,
      contains('_looksLikeEnglishNativeCue(source)'),
    );
    expect(
      player,
      contains("'sub-text'"),
    );
    expect(
      player,
      contains("'sid'"),
    );
    expect(
      player,
      contains('nativeSid='),
    );
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

  test('failed playback can never persistently disable AI Sinhala again', () {
    final preferences =
        File('lib/services/ai_sinhala_preferences_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(preferences, contains("orvix_ai_sinhala_enabled_v3"));
    expect(preferences, contains("orvix_ai_sinhala_enabled_v2"));
    expect(preferences, contains('final migrated = Platform.isWindows ? true'));
    expect(
      player,
      isNot(contains('await AiSinhalaPreferencesService.setEnabled(false);')),
    );
    expect(player, contains('bool _aiPreferenceEnabled = false;'));
    expect(player, contains('value: _aiPreferenceEnabled'));
  });

  test('exact subtitle fallback tries source hash before engine hash', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    final sourceAttempt = details.indexOf("label: 'source'");
    final engineAttempt = details.indexOf("label: 'engine'");
    final addonFallback =
        details.indexOf('checking the official hash-scoped subtitle addons');

    expect(sourceAttempt, greaterThanOrEqualTo(0));
    expect(engineAttempt, greaterThan(sourceAttempt));
    expect(addonFallback, greaterThan(engineAttempt));
    expect(details, contains('candidate.exactHashPath'));
    expect(details, contains('candidate.strongReleaseMatchCount > 0'));
    expect(details, contains('hash-addon-rejected'));
    expect(
      details,
      contains('No safe subtitle matched this exact file.'),
    );
  });

  test('TorBox AI inspects the same cloud torrent file tree before P2P fallback', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final torbox = File('lib/services/torbox_service.dart').readAsStringSync();
    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(details, contains('torBoxItem: cloudItem'));
    expect(details, contains('torBoxVideoFile: file'));
    expect(details, contains('torbox-subtitle-scan'));
    expect(details, contains('torbox-subtitle-candidate'));
    expect(details, contains('torbox-subtitle-selected'));
    expect(
      details,
      contains('prepareGeneratedSinhalaFromVerifiedExternalSubtitle('),
    );
    expect(torbox, contains('rankSubtitleCandidatesForVideo('));
    expect(torbox, contains('final String? path;'));
    expect(torbox, contains('bool get isTextSubtitle'));
    expect(
      ai,
      contains('same-cloud-torrent-sibling-exact-release'),
    );

    final torBoxAttempt = details.indexOf(
      'preparedAiSubtitleFile = await _tryTorBoxSiblingSubtitle(',
    );
    final exactAttempt = details.indexOf(
      'Future<AiGeneratedSubtitleFile?> tryExact(',
    );
    final p2pAttempt = details.indexOf('p2p-subtitle-oracle-start');
    expect(torBoxAttempt, greaterThanOrEqualTo(0));
    expect(exactAttempt, greaterThan(torBoxAttempt));
    expect(p2pAttempt, greaterThan(exactAttempt));
  });

  test('debrid AI can reuse the exact Free P2P subtitle path without switching video playback', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('p2p-subtitle-oracle-start'));
    expect(details, contains('source.isMagnet'));
    expect(details, contains('!originalLocalP2p'));
    expect(details, contains('source.torrentFileIndex != null'));
    expect(details, contains('source.fileNameHint?.trim().isNotEmpty == true'));
    expect(
      details,
      contains('await LocalTorrentService.instance.resolve('),
    );
    expect(
      details,
      contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
    expect(details, contains('videoFileNameHint: source.fileNameHint ?? releaseHint'));
    expect(details, contains('warmForPlayback: false'));
    expect(
      details,
      contains('await LocalTorrentService.instance.releaseCurrentStream();'),
    );

    // The debrid/CDN playback session must remain authoritative. The local
    // torrent is only a subtitle oracle and must never replace playbackUrl.
    expect(details, contains('playbackUrl = enginePlaybackUrl;'));
  });

  test('remote debrid subtitle probing is bounded while local P2P keeps the long window', () {
    final engine =
        File('tools/orvix-media-engine/main.go').readAsStringSync();
    final localTorrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(engine, contains('probeTimeout := 35 * time.Second'));
    expect(engine, contains('probeTimeout = 75 * time.Second'));
    expect(localTorrent, contains('bool warmForPlayback = true'));
    expect(
      localTorrent,
      contains("warmForPlayback ? 'Opening player…' : 'Exact torrent file ready…'"),
    );
    expect(
      ai,
      contains('if (Platform.isWindows) return null;'),
    );
  });

  test('local exact torrent subtitle path accepts matching external text files', () {
    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(ai, contains('final externalCandidates = <Map<String, dynamic>>[];'));
    expect(ai, contains('_externalTorrentSubtitleMatchScore('));
    expect(ai, contains('_subtitleTextLooksEnglish(content)'));
    expect(ai, contains('Torrent external • '));
    expect(
      ai,
      contains(
        'The exact torrent file had no readable English text subtitle, including matching external subtitle files.',
      ),
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
