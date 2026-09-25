import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala falls back to audio STT when no text subtitle exists', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final audio =
        File('lib/services/ai_audio_stt_service.dart').readAsStringSync();

    expect(player, contains("import '../services/ai_audio_stt_service.dart';"));
    expect(player, contains('Future<bool> _activateAudioAiFallback'));
    expect(player, contains("return _activateAudioAiFallback(phase: '\$phase-no-text');"));
    expect(
      player,
      contains("return _activateAudioAiFallback(phase: '\$phase-transcript-miss');"),
    );
    expect(player, contains("sourceMatch: 'audio-stt'"));
    expect(player, contains('if (_audioAiActive) {'));
    expect(player, contains('_ensureAudioAiAhead(adjusted);'));

    // AI startup opens media paused. A failed AI path must still release normal
    // playback instead of leaving the user stuck on a loading screen.
    expect(player, contains('if (!reopenedAfterAiFailure) {'));
    expect(player, contains('await widget.playback.player.play();'));

    // Audio windows use the original provider/debrid URL and call the protected
    // Supabase function with both auth headers required by guest mode.
    expect(audio, contains('AiAudioSttService'));
    expect(audio, contains("'apikey': _guestFunctionJwt"));
    expect(audio, contains('windowStride = Duration(seconds: 20)'));
    expect(audio, contains('transcribe-audio-si'));

    // Windows must keep FFmpeg outside the Flutter process. The Office beta.37
    // run still terminated after audio-ai-window-start when Dart launched the
    // child directly, so beta.38 routes extraction through the standalone media
    // engine process.
    expect(audio, contains('if (Platform.isWindows)'));
    expect(audio, contains('OrvixMediaEngineService.instance.extractAudioWindow'));
    expect(audio, isNot(contains('Process.run(')));
    expect(
      player,
      contains(
        'Embedded English subtitle found, but it is image-based (PGS/VobSub)',
      ),
    );

    // A real native English text track on Windows must never trigger the old
    // multi-minute full-file embedded subtitle rescan.
    expect(player, contains('if (Platform.isWindows)'));
    expect(player, contains('native-cue-ai-live phase='));
    expect(
      player,
      contains(
        'Using the detected English text track directly; full-file rescanning is skipped on Windows.',
      ),
    );
    expect(player, contains('static const int _liveAiLeadMs = 3000;'));
    expect(
      player,
      contains('await _setNativeSubtitleDelayProperty(-_liveAiLeadMs / 1000.0);'),
    );
    expect(player, contains('live-cue-ok index='));

  });
}
