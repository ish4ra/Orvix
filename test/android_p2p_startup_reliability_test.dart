import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/screens/player_screen.dart';
import 'package:orvix/services/local_p2p_startup_policy.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_exo_backend.dart';

// Android local Free P2P startup: a torrent that needs minutes to deliver its
// first frame must never be reported as failed, switched to another source
// or switched to another player engine. Genuine terminal errors still are.

final _hash = 'ab' * 20;
final _p2pUrl = 'http://127.0.0.1:11470/$_hash/0';

const _slowRead =
    'androidx.media3.exoplayer.ExoPlaybackException: Source error '
    '(HttpDataSourceException: java.net.SocketTimeoutException: timeout)';
const _codec =
    'androidx.media3.exoplayer.ExoPlaybackException: MediaCodecVideoRenderer '
    'error, index=0, format=Format(1, null, video/av01), '
    'format_supported=NO_UNSUPPORTED_TYPE';

void main() {
  group('startup policy', () {
    test('only an Android localhost torrent stream gets patient startup', () {
      expect(LocalP2pStartupPolicy.appliesTo(isAndroid: true, url: _p2pUrl),
          isTrue);
      expect(
        LocalP2pStartupPolicy.appliesTo(
            isAndroid: true, url: _p2pUrl.replaceFirst('127.0.0.1', 'localhost')),
        isTrue,
      );
      // Windows/macOS keep their watchdog; so do debrid/direct streams.
      expect(LocalP2pStartupPolicy.appliesTo(isAndroid: false, url: _p2pUrl),
          isFalse);
      expect(
        LocalP2pStartupPolicy.appliesTo(
            isAndroid: true, url: 'https://cdn.example.org/video.mkv'),
        isFalse,
      );
      expect(
        LocalP2pStartupPolicy.appliesTo(
            isAndroid: true, url: 'http://127.0.0.1:8080/video'),
        isFalse,
      );
      expect(PlayerScreen.slowStartKeepsWaiting(isAndroid: true, url: _p2pUrl),
          isTrue);
    });

    test('slow-torrent read errors are not terminal, codec errors are', () {
      expect(LocalP2pStartupPolicy.exoErrorIsTerminal(_slowRead), isFalse);
      expect(
        LocalP2pStartupPolicy.exoErrorIsTerminal(
            'ExoPlaybackException: Source error'),
        isFalse,
      );
      expect(LocalP2pStartupPolicy.exoErrorIsTerminal(_codec), isTrue);
      expect(
        LocalP2pStartupPolicy.exoErrorIsTerminal(
            'Source error (InvalidResponseCodeException: Response code: 404)'),
        isTrue,
      );
      expect(
        LocalP2pStartupPolicy.exoErrorIsTerminal(
            'Source error (UnrecognizedInputFormatException: None of the '
            'available extractors could read the stream)'),
        isTrue,
      );
    });

    test('ExoPlayer retries a slow torrent but never loops on fast failures',
        () {
      final slow = ExoP2pRetryPolicy();
      for (var i = 0; i < 20; i++) {
        expect(
          slow.shouldRetry(
            description: _slowRead,
            attemptWasLong: true,
            engineAnswering: true,
          ),
          isTrue,
          reason: 'a slow attempt is retried (attempt ${i + 1})',
        );
      }

      final fast = ExoP2pRetryPolicy();
      final answers = [
        for (var i = 0; i < 3; i++)
          fast.shouldRetry(
            description: 'Source error',
            attemptWasLong: false,
            engineAnswering: true,
          ),
      ];
      expect(answers, [true, true, false],
          reason: 'a stream that fails instantly is not slow');

      expect(
        ExoP2pRetryPolicy().shouldRetry(
          description: _slowRead,
          attemptWasLong: true,
          engineAnswering: false,
        ),
        isFalse,
        reason: 'a dead torrent engine is terminal',
      );
      expect(
        ExoP2pRetryPolicy().shouldRetry(
          description: _codec,
          attemptWasLong: false,
          engineAnswering: true,
        ),
        isFalse,
      );
    });
  });

  group('MPV startup monitor (simulated player events)', () {
    late bool started;
    late bool playerIdle;
    late bool engineUp;
    late int slowCalls;
    late List<String> terminal;
    late List<String> stages;

    LocalP2pStartupMonitor monitor() => LocalP2pStartupMonitor(
          playerGaveUp: () async => playerIdle,
          engineAnswering: () async => engineUp,
          started: () => started,
          onSlow: () => slowCalls++,
          onTerminal: terminal.add,
          onStage: (stage, result, _) => stages.add('$stage:$result'),
        );

    setUp(() {
      started = false;
      playerIdle = false;
      engineUp = true;
      slowCalls = 0;
      terminal = <String>[];
      stages = <String>[];
    });

    testWidgets(
        'a torrent that starts after more than three minutes is never '
        'reported as failed', (tester) async {
      final watch = monitor()..begin();
      // MPV logs tcp read timeouts while the swarm has no pieces yet.
      for (var second = 0; second < 200; second += 5) {
        if (second % 90 == 85) {
          watch.playerError('tcp: ffurl_read returned 0xffffff92');
        }
        await tester.pump(const Duration(seconds: 5));
      }
      expect(terminal, isEmpty, reason: 'no false startup failure');
      expect(slowCalls, 1, reason: 'one calm "still connecting" note');
      expect(stages, contains('playerStart:slow'));
      expect(stages, isNot(contains('playerStart:terminal')));

      started = true;
      await tester.pump(const Duration(seconds: 5));
      expect(watch.active, isFalse);
      expect(terminal, isEmpty);
    });

    testWidgets('elapsed time alone never ends a waiting stream',
        (tester) async {
      final watch = monitor()..begin();
      await tester.pump(const Duration(minutes: 15));
      expect(terminal, isEmpty);
      expect(watch.active, isTrue, reason: 'still waiting, Back still works');
      watch.stop();
    });

    testWidgets('a genuine fatal error is still reported once',
        (tester) async {
      final watch = monitor()..begin();
      watch.playerError('Failed to recognize file format.');
      await tester.pump(const Duration(seconds: 5));
      expect(terminal, isEmpty, reason: 'MPV is still loading');
      playerIdle = true; // MPV gave up on the file.
      await tester.pump(const Duration(seconds: 5));
      expect(terminal, isEmpty, reason: 'one reading is not enough');
      await tester.pump(const Duration(seconds: 5));
      expect(terminal, ['Playback engine: Failed to recognize file format.']);
      await tester.pump(const Duration(minutes: 1));
      expect(terminal, hasLength(1));
      expect(stages, contains('playerStart:terminal'));
    });

    testWidgets('a torrent engine that stopped answering is terminal',
        (tester) async {
      final watch = monitor()..begin();
      await tester.pump(const Duration(seconds: 31));
      engineUp = false;
      await tester.pump(const Duration(seconds: 10));
      expect(terminal.single, contains('stopped answering'));
      expect(watch.active, isFalse);
    });

    testWidgets('Back stops every timer and reports nothing', (tester) async {
      final watch = monitor()..begin();
      watch.playerError('tcp: timeout');
      watch.stop();
      playerIdle = true;
      engineUp = false;
      await tester.pump(const Duration(minutes: 5));
      expect(terminal, isEmpty);
      expect(slowCalls, 1);
    });
  });

  group('MPV player wiring', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    test('local P2P errors go to the startup monitor, not the failure card',
        () {
      final handler = player.substring(
        player.indexOf('  void _onPlaybackError(String message) {'),
      );
      final monitorCall =
          handler.indexOf('_localP2pStartup().playerError(message);');
      final failureCall = handler.indexOf('_reportStartupFailure(detail)');
      expect(monitorCall, greaterThan(0));
      expect(monitorCall, lessThan(failureCall),
          reason: 'local P2P returns before the generic failure path');
      expect(player, contains("'idle-active'"));
      expect(player, contains('_localP2pStartup().begin();'));
    });

    test('other streams keep the 30-second startup watchdog', () {
      expect(player, contains('_startupTimer = Timer(const Duration(seconds: 30)'));
      expect(player, contains("'The stream is taking longer than expected to start. '"));
    });
  });

  group('ExoPlayer screen (simulated native player)', () {
    late FakeExoBackend backend;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = FakeExoBackend();
      OrvixExoController.defaultBackend = backend;
      AndroidExoPlayerScreen.debugEngineAnswering = () async => true;
    });

    testWidgets(
        'a torrent that needs over three minutes plays in the same player '
        'with no failure and no engine switch', (tester) async {
      final stages = <String>[];
      final player = await openExo(
        tester,
        _p2pUrl,
        autoFallbackToMpv: true,
        stages: stages,
      );
      expect(backend.created.single['patientStartup'], isTrue);
      final id = backend.lastId;
      for (var second = 0; second < 200; second += 5) {
        backend.state(id, state: 2, playing: false);
        await tester.pump(const Duration(seconds: 5));
        if (second == 30) {
          expect(find.text('Still connecting to peers…'), findsOneWidget);
        }
      }
      expect(find.text('Could not play this stream'), findsNothing);
      expect(backend.created, hasLength(1), reason: 'the same player waits');
      expect(stages, contains('playerStart:slow'));

      backend.state(id, state: 3, playing: true, positionMs: 1000);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Still connecting to peers…'), findsNothing);

      await tester.binding.handlePopRoute();
      final closed = await player.close(tester, pop: false);
      expect(closed?.started, isTrue);
      expect(closed?.failed, isFalse);
      expect(closed?.switchToMpv, isFalse,
          reason: 'slow startup never switches the player engine');
      expect(backend.disposed, contains(id));
    });

    testWidgets(
        'a network timeout from a slow swarm reopens the same stream instead '
        'of failing', (tester) async {
      await openExo(tester, _p2pUrl, autoFallbackToMpv: true);
      final first = backend.lastId;
      await tester.pump(const Duration(seconds: 35));
      backend.error(first, 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT');
      await tester.pump(const Duration(seconds: 2));
      expect(backend.created, hasLength(2));
      expect(backend.created.map((c) => c['url']).toSet(), {_p2pUrl},
          reason: 'same source, no switch');
      expect(find.text('Could not play this stream'), findsNothing);
      backend.state(backend.lastId, state: 3, playing: true, positionMs: 500);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Still connecting to peers…'), findsNothing);
    });

    testWidgets('a genuine decoder error is still reported', (tester) async {
      final player = await openExo(tester, _p2pUrl);
      backend.error(
        backend.lastId,
        'ERROR_CODE_DECODER_INIT_FAILED',
        message: _codec,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Could not play this stream'), findsOneWidget);
      expect(find.text('Try MPV'), findsOneWidget);
      expect(backend.created, hasLength(1));
      await tester.tap(find.text('Back'));
      expect((await player.close(tester))?.failed, isTrue);
    });

    testWidgets('a genuine error may fall back to MPV only when Auto allows',
        (tester) async {
      final player = await openExo(tester, _p2pUrl, autoFallbackToMpv: true);
      backend.error(backend.lastId, 'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED');
      await tester.pump(const Duration(seconds: 1));
      final closed = await player.close(tester, pop: false);
      expect(closed?.failed, isTrue);
      expect(closed?.switchToMpv, isTrue);
    });

    testWidgets('a stream that keeps failing instantly does not loop',
        (tester) async {
      await openExo(tester, _p2pUrl);
      for (var i = 0; i < 6; i++) {
        backend.error(backend.lastId, 'ERROR_CODE_IO_UNSPECIFIED');
        await tester.pump(const Duration(milliseconds: 1500));
      }
      expect(find.text('Could not play this stream'), findsOneWidget);
      expect(backend.created.length, lessThanOrEqualTo(3));
    });

    testWidgets('a torrent engine that stopped answering ends the attempt',
        (tester) async {
      await openExo(tester, _p2pUrl);
      await tester.pump(const Duration(seconds: 31));
      AndroidExoPlayerScreen.debugEngineAnswering = () async => false;
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('Could not play this stream'), findsOneWidget);
      expect(find.textContaining('stopped answering'), findsOneWidget);
    });

    testWidgets('Back during a slow start closes at once and is not a failure',
        (tester) async {
      final player = await openExo(tester, _p2pUrl);
      await tester.pump(const Duration(minutes: 2));
      await tester.binding.handlePopRoute();
      final closed = await player.close(tester, pop: false);
      expect(closed?.started, isFalse);
      expect(closed?.failed, isFalse,
          reason: 'leaving a slow start is not a source failure');
      expect(backend.disposed, contains(backend.lastId));
    });

    testWidgets('a direct (non-P2P) stream keeps the 35-second limit',
        (tester) async {
      await openExo(tester, 'https://cdn.example.org/video.mkv');
      expect(backend.created.single['patientStartup'], isFalse);
      await tester.pump(const Duration(seconds: 36));
      expect(find.textContaining('within 35 seconds'), findsOneWidget);
    });
  });
}
