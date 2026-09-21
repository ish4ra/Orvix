import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('whole subtitle translation is batched and must finish before SRT write', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('static Future<void> _translateEntireSubtitle('));
    expect(service, contains('const batchSize = 60;'));
    expect(
      service,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
    expect(service, contains('_writeGeneratedSrt('));
  });

  test('AI styling is isolated from normal source subtitle rendering', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('double _effectiveSubtitleFontSize(BuildContext context)'));
    expect(player, contains('fontSize: _effectiveSubtitleFontSize(context)'));
    expect(
      player,
      contains(
        'visible: !_aiSinhalaRequested &&\n'
        '                          widget.playback.player.platform is! mk.NativePlayer',
      ),
    );
    expect(player, contains("'sub-ass-override'"));
    expect(player, contains("'no'"));
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(true);'),
    );
    expect(player, contains('mk.SubtitleTrack.uri('));
    expect(player, contains('!_aiSinhalaRequested ||'));
    expect(
      player,
      contains('embedded subtitle can then appear with its own authored styling'),
    );
    expect(
      player,
      contains('Source subtitle appearance is preserved by the native player.'),
    );
    expect(
      player,
      contains('Orvix font/background/position styling is only used for AI Sinhala.'),
    );
  });

  test('generated Sinhala SRT paths stay visible with native subtitle rendering', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final generatedStart =
        player.indexOf('if (aiReady && _generatedAiSubtitlePath != null)');
    final generatedEnd =
        player.indexOf('} else if (aiReady && _preparedAiSubtitle != null)', generatedStart);
    final generated = player.substring(generatedStart, generatedEnd);
    expect(generated, contains('await _setNativeSubtitleVisibility(true);'));

    final onlineStart =
        player.indexOf('Future<void> _activateAiSinhalaFromOnlineSubtitle');
    final onlineEnd =
        player.indexOf('Future<void> _showOnlineSubtitles()', onlineStart);
    final online = player.substring(onlineStart, onlineEnd);
    expect(online, contains('await _setNativeSubtitleVisibility(true);'));
  });

}
