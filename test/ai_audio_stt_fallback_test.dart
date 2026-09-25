import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows holds unreliable audio STT while retaining the service', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final audio =
        File('lib/services/ai_audio_stt_service.dart').readAsStringSync();

    // Keep the audio machinery available for non-Windows/manual experiments,
    // but production Windows startup must no longer auto-enter it when no
    // readable text subtitle exists.
    expect(player, contains("import '../services/ai_audio_stt_service.dart';"));
    expect(player, contains('Future<bool> _activateAudioAiFallback'));
    expect(player, contains('audio-ai-held phase='));
    expect(player, contains('bool _windowsAiTextOnlyHeld = false;'));
    expect(
      player,
      contains(
        'AI Sinhala is paused for this source because its English subtitle is image-based (PGS/VobSub).',
      ),
    );

    final progressiveStart =
        player.indexOf('Future<bool> _activateProgressiveNativeCueAi');
    final progressiveEnd =
        player.indexOf('Future<void> _discoverNativeCueAiAfterPlayback', progressiveStart);
    final progressive = player.substring(progressiveStart, progressiveEnd);
    expect(progressive, contains('if (Platform.isWindows)'));
    expect(progressive, contains('audio-ai-held phase='));
    expect(
      progressive.indexOf('audio-ai-held phase='),
      lessThan(progressive.indexOf(
        "return _activateAudioAiFallback(phase: '\$phase-no-text');",
      )),
    );

    // AI startup always releases normal playback if AI is held/unavailable.
    expect(player, contains('if (!reopenedAfterAiFailure) {'));
    expect(player, contains('await widget.playback.player.play();'));

    // The isolated STT service itself remains intact.
    expect(audio, contains('AiAudioSttService'));
    expect(audio, contains("'apikey': _guestFunctionJwt"));
    expect(audio, contains('windowStride = Duration(seconds: 20)'));
    expect(audio, contains('transcribe-audio-si'));
    expect(audio, contains('if (Platform.isWindows)'));
    expect(audio, contains('LocalTorrentService.instance.extractAudioWindow'));
    expect(audio, isNot(contains('OrvixMediaEngineService')));
    expect(audio, isNot(contains('Process.run(')));
  });

  test('Windows native text AI uses exact MPV event timing, not wall clock', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('native-cue-ai-live phase='));
    expect(
      player,
      contains(
        'Using the detected English text track directly; full-file rescanning is skipped on Windows.',
      ),
    );
    expect(player, contains('static const int _liveAiLeadMs = 6000;'));
    expect(player, contains("'sub-text/ass-full'"));
    expect(player, contains('NativeSubtitleEventParser.parseAssFull(raw)'));
    expect(player, contains('final Map<String, AiSubtitleCue> _liveExactCues'));
    expect(player, contains('_refreshLiveExactSubtitle(position)'));
    expect(player, contains('lines.join'));
    expect(
      player,
      contains('Duration maxWait = const Duration(milliseconds: 6500)'),
    );
  });
}
