import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic AI Sinhala never auto-selects a ranked OpenSubtitles result', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final startupStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final startupEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', startupStart);
    final startup = player.substring(startupStart, startupEnd);

    expect(startup, contains('prepareGeneratedSinhalaFile('));
    expect(startup, contains('videoUrl: widget.url'));
    expect(startup, contains('expectedSizeBytes: widget.expectedSizeBytes'));
    expect(startup, contains('expectedVideoHash: widget.expectedVideoHash'));
    expect(startup, isNot(contains('OnlineSubtitleService.search(')));
    expect(startup, isNot(contains('final chosen = english.first;')));
  });

  test('actual selected URL is fingerprinted with first and last 64 KiB', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final probeStart = service.indexOf('static Future<_VideoProbe> _probeVideo(');
    final probeEnd =
        service.indexOf('static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(', probeStart);
    final probe = service.substring(probeStart, probeEnd);

    expect(probe, contains('65535'));
    expect(probe, contains('size - 65536'));
    expect(probe, contains('_openSubtitlesHash(size, first.bytes, tail.bytes)'));
    expect(probe, isNot(contains('_probeLocalOpenSubtitlesHash(')));

    expect(service, contains("request.headers['enginefs-prio'] = '255';"));
    expect(service, contains('uri.port == 11470'));
  });
}
