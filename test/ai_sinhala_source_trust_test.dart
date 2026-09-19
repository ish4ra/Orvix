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

  test('local P2P uses stream-server exact selected-file OpenSubtitles hash', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final probeStart = service.indexOf('static Future<_VideoProbe> _probeVideo(');
    final probeEnd =
        service.indexOf('static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(', probeStart);
    final probe = service.substring(probeStart, probeEnd);

    expect(probe, contains("uri.port == 11470"));
    expect(probe, contains('_probeLocalOpenSubtitlesHash('));

    final localStart =
        service.indexOf('static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(');
    final localEnd =
        service.indexOf('static Future<_RangeRead?> _readRangeWithRetry(', localStart);
    final local = service.substring(localStart, localEnd);

    expect(local, contains("path: '/opensubHash'"));
    expect(local, contains("'videoUrl': videoUri.toString()"));
    expect(local, contains("result['hash']"));
    expect(local, contains("result['size']"));
  });

  test('local P2P never falls back to addon hash when exact native probe fails', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final localStart =
        service.indexOf('static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(');
    final localEnd =
        service.indexOf('static Future<_RangeRead?> _readRangeWithRetry(', localStart);
    final local = service.substring(localStart, localEnd);

    expect(local, contains('size: null'));
    expect(local, contains('hash: null'));
    expect(local, isNot(contains('suppliedHash')));
  });

  test('non-local direct streams can compute the canonical hash from byte ranges', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final probeStart = service.indexOf('static Future<_VideoProbe> _probeVideo(');
    final probeEnd =
        service.indexOf('static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(', probeStart);
    final probe = service.substring(probeStart, probeEnd);

    expect(probe, contains('65535'));
    expect(probe, contains('size - 65536'));
    expect(probe, contains('_openSubtitlesHash(size, first.bytes, tail.bytes)'));
  });
}
