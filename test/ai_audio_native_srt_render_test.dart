import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio AI Sinhala native subtitle renderer wiring', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    expect(player, contains('Future<bool> _syncAudioAiNativeTrack'));
    expect(player, contains('audio-ai-native-attach'));
    expect(player, contains('audio-ai-native-reload'));
    expect(player, contains("'sub-add'"));
    expect(player, contains("'sub-reload'"));
    expect(player, contains("'sub-remove'"));
    expect(player, contains('_audioAiNativeAttached'));
  });
}
