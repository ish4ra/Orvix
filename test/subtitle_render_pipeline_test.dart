import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/online_subtitle_service.dart';

void main() {
  test('whole subtitle translation is parallel-batched and must finish before SRT write', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('static Future<void> _translateEntireSubtitle('));
    expect(service, contains('const batchSize = 96;'));
    expect(service, contains('const parallelBatches = 3;'));
    expect(service, contains('await Future.wait<void>'));
    expect(service, contains('_translateIndicesResilient('));
    expect(
      service,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
    expect(service, contains('_writeGeneratedSrt('));
  });

  test('complete embedded generation writes translated text with original cue timestamps', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final writeStart = service.indexOf('static Future<File> _writeGeneratedSrt(');
    final writeEnd = service.indexOf('static String _formatSrtTimestamp', writeStart);
    final writer = service.substring(writeStart, writeEnd);

    expect(writer, contains('_formatSrtTimestamp(cue.start)'));
    expect(writer, contains('_formatSrtTimestamp(cue.end)'));
    expect(writer, contains('writeln(translated)'));
  });

  test('generated Sinhala SRT is attached as a native subtitle track', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _loadGeneratedAiSubtitleTrack()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final generated = player.substring(start, end);

    expect(generated, contains('mk.SubtitleTrack.uri('));
    expect(generated, contains("language: 'si'"));
    expect(generated, contains('await _setNativeSubtitleDelayProperty(0);'));
    expect(generated, contains('await _setNativeSubtitleVisibility(true);'));
  });

  test('normal source subtitle appearance remains native when AI is off', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains("'sub-ass-override'"));
    expect(player, contains("'no'"));
    expect(
      player,
      contains('Source subtitle appearance is preserved by the native player.'),
    );
  });
  test('normal playback prefers full native subtitles and falls back online', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    expect(player, contains('Future<void> _ensureNormalSubtitleSelection()'));
    expect(player, contains('bool _isLikelyFullSubtitleTrack'));
    expect(player, contains("!title.contains('forced')"));
    expect(player, contains("!title.contains('commentary')"));
    expect(player, contains('_normalOnlineSubtitleSearch ??='));
    expect(player, contains('OnlineSubtitleService.search('));
    expect(player, contains('attempt == 4'));
    expect(player, contains('attempt == 12'));
    expect(player, contains('_tryNormalOnlineSubtitleFallback('));
    expect(player, contains('OnlineSubtitleService.materialize(subtitle)'));
    expect(player, contains("preferred == 'eng' && _isEnglishTrack(track)"));
    expect(player, contains('for (final candidate in candidates)'));
    expect(player, contains('final nativePreferred = player.state.tracks.subtitle'));
    expect(player, contains('var nativeSelected = false;'));
    expect(player, contains('if (nativeSelected)'));
    expect(
      player,
      contains(
        'continue with the\n'
        '          // already-materialized online subtitle',
      ),
    );
    expect(player, contains('await _activateNativeSubtitle(track);'));
    expect(player, contains('unawaited(_ensureNormalSubtitleSelection());'));
    expect(playback, contains("'slang': 'eng,en,en-US,en-GB'"));
  });

  test('online subtitle materialization gives MPV a local text file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.text;
      request.response.write(
        '1\\n00:00:01,000 --> 00:00:03,000\\nHello there.\\n',
      );
      await request.response.close();
    });

    final result = OnlineSubtitleResult(
      id: 'local-test',
      url: 'http://127.0.0.1:${server.port}/subtitle.srt',
      language: 'eng',
      languageLabel: 'English',
      label: 'Test English',
      provider: 'test',
      score: 100,
    );

    File? file;
    try {
      file = await OnlineSubtitleService.materialize(result);
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), contains('Hello there.'));
      expect(file.path.toLowerCase(), endsWith('.srt'));
    } finally {
      if (file != null && await file.exists()) {
        await file.delete();
      }
      await server.close(force: true);
    }
  });

  test('online subtitle materialization rejects non-subtitle payloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html><body>temporary provider error</body></html>');
      await request.response.close();
    });

    final result = OnlineSubtitleResult(
      id: 'invalid-test',
      url: 'http://127.0.0.1:${server.port}/subtitle.srt',
      language: 'eng',
      languageLabel: 'English',
      label: 'Invalid English',
      provider: 'test',
      score: 100,
    );

    try {
      await expectLater(
        OnlineSubtitleService.materialize(result),
        throwsA(isA<StateError>()),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('Android player wires MediaKit text overlay render policy', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains('SubtitleRenderPolicy.flutterOverlayVisible('),
    );
    expect(
      player,
      contains('SubtitleRenderPolicy.nativeSubtitleVisible('),
    );
    expect(player, contains('isAndroid: Platform.isAndroid'));
    expect(player, contains('isBitmapTrack: _isImageSubtitleTrack(selected)'));
  });

  test('Android text subtitles use direct Orvix sizing and selected MPV track id', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('textScaler: TextScaler.noScaling'));
    expect(player, contains("'current-tracks/sub/id'"));
    expect(player, contains("for (final property in const <String>['current-tracks/sub/id', 'sid'])"));
    expect(player, contains('selected: activeSubtitleId == track.id'));
    expect(
      player,
      contains('Android text subtitles use Orvix styling for consistent size.'),
    );
  });

}
