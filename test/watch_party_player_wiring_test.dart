// Watch Party and the players: the feature flag, the ExoPlayer adapter on
// the real player screen, the in-player overlay, the Settings entry, and
// the guarantees that keep solo playback untouched.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/screens/settings_screen.dart';
import 'package:orvix/screens/watch_party_screen.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/watch_party/watch_party_chat_policy.dart';
import 'package:orvix/services/watch_party/watch_party_feature.dart';
import 'package:orvix/services/watch_party/watch_party_models.dart';
import 'package:orvix/services/watch_party/watch_party_player_adapter.dart';
import 'package:orvix/services/watch_party/watch_party_service.dart';
import 'package:orvix/services/watch_party/watch_party_session.dart';
import 'package:orvix/widgets/watch_party_player_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_exo_backend.dart';
import 'support/watch_party_fakes.dart';

const _movie = MediaItem(
  id: 'tt1375666',
  kind: MediaKind.movie,
  title: 'Inception',
  year: '2010',
);

const _url = 'https://cdn.example.test/inception.mkv';

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets the session's timers run and the fake requests finish.
Future<void> _pass(WidgetTester tester, int ms) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 250) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _finish(WidgetTester tester) async {
  await WatchPartyService.instance.leave();
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  late FakeTime time;
  late FakeRoomBackend room;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WatchPartyService.instance.leave();
    time = FakeTime();
    room = FakeRoomBackend(time);
    WatchPartyService.instance.backend = room;
  });

  tearDown(() {
    WatchPartyFeature.debugOverride = null;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  WatchPartySession directSession({bool host = false}) {
    room.selfIsHost = host;
    final session = WatchPartySession(
      backend: room,
      snapshot: room.snapshot(),
      displayName: 'Me',
      clock: clockFor(time),
      chatPolicy: WatchPartyChatPolicy(nowMs: () => time.nowMs),
      autoTimers: false,
    );
    WatchPartyService.instance.session.value = session;
    return session;
  }

  group('feature flag', () {
    test('is off unless the build defines ORVIX_WATCH_PARTY', () {
      expect(WatchPartyFeature.compiledIn, isFalse);
      expect(WatchPartyFeature.debugOverride, isNull);
      expect(WatchPartyFeature.enabled, isFalse);
    });

    test('with the flag off a player is never attached or read', () {
      room.media = inception;
      room.stateSeq = 1;
      room.playing = true;
      final session = directSession();
      final player = FakePlayer(time)..unreadable = true;

      expect(WatchPartyService.instance.current, isNull);
      final binding = WatchPartyService.instance.attachPlayer(
        player,
        item: _movie,
      );
      expect(binding, isNull);
      expect(session.hasPlayer, isFalse);
      expect(player.commands, isEmpty);
      session.dispose();
      WatchPartyService.instance.session.value = null;
    });

    test('with the flag off rooms cannot be created or joined', () {
      expect(
        () => WatchPartyService.instance.create('Sam'),
        throwsA(isA<WatchPartyException>()
            .having((e) => e.error, 'error', WatchPartyError.unavailable)),
      );
      expect(
        () => WatchPartyService.instance.join('ABCDEFGH', 'Sam'),
        throwsA(isA<WatchPartyException>()),
      );
      expect(room.calls, isEmpty);
    });

    test('with the flag on but no room a player is left alone', () {
      WatchPartyFeature.debugOverride = true;
      final player = FakePlayer(time);
      expect(
        WatchPartyService.instance.attachPlayer(player, item: _movie),
        isNull,
      );
      expect(player.commands, isEmpty);
    });

    test('a signed-out account cannot open a room', () {
      WatchPartyFeature.debugOverride = true;
      room.signedIn = false;
      expect(
        () => WatchPartyService.instance.create('Sam'),
        throwsA(isA<WatchPartyException>()
            .having((e) => e.error, 'error', WatchPartyError.authRequired)),
      );
      expect(room.calls, isEmpty);
    });

    testWidgets('Settings shows Watch Party only with the flag on',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pumpSettings() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(body: SettingsScreen()),
        ));
        await _settle(tester);
      }

      await pumpSettings();
      expect(find.text('Watch Party'), findsNothing);
      expect(find.byKey(const ValueKey('watch-party-entry')), findsNothing);

      WatchPartyFeature.debugOverride = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpSettings();
      expect(find.text('Watch Party'), findsOneWidget);

      await tester
          .ensureVisible(find.byKey(const ValueKey('watch-party-entry')));
      await tester.tap(find.byKey(const ValueKey('watch-party-entry')));
      await _settle(tester);
      expect(find.byType(WatchPartyScreen), findsOneWidget);
    });

    testWidgets('Android TV Settings shows the entry only with the flag on',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pumpSettings() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(body: SettingsScreen()),
        ));
        await _settle(tester);
      }

      await pumpSettings();
      expect(find.byKey(const ValueKey('watch-party-entry')), findsNothing);

      WatchPartyFeature.debugOverride = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpSettings();
      expect(find.byKey(const ValueKey('watch-party-entry')), findsOneWidget);
    });
  });

  group('ExoPlayer adapter', () {
    late FakeExoBackend exo;

    setUp(() {
      exo = FakeExoBackend();
      OrvixExoController.defaultBackend = exo;
    });

    test('cannot be read before the native player exists or after it is gone',
        () async {
      OrvixExoController? controller;
      final adapter = ExoWatchPartyAdapter(() => controller);
      expect(adapter.read(), isNull);
      await adapter.play();
      await adapter.seek(5000);
      expect(exo.commands, isEmpty);

      controller = OrvixExoController(url: _url);
      expect(adapter.read(), isNull, reason: 'not created yet');
      await controller.open();
      expect(adapter.read(), isNotNull);

      controller.dispose();
      expect(adapter.read(), isNull);
      final before = exo.commands.length;
      await adapter.pause();
      expect(exo.commands.length, before);
    });

    test('reads intent, stalls, position and speed, and sends commands',
        () async {
      final controller = OrvixExoController(url: _url);
      await controller.open();
      final id = exo.lastId;
      final adapter = ExoWatchPartyAdapter(() => controller);

      // Stalled but still set to play: that is buffering, not a pause.
      exo.state(id, state: 2, playing: false, positionMs: 42000);
      var reading = adapter.read()!;
      expect(reading.playing, isTrue);
      expect(reading.buffering, isTrue);
      expect(reading.positionMs, 42000);
      expect(reading.durationMs, 2640000);

      exo.state(id, playing: true, positionMs: 43000, speed: 1.05);
      reading = adapter.read()!;
      expect(reading.buffering, isFalse);
      expect(reading.rate, closeTo(1.05, 0.0001));

      await adapter.pause();
      expect(adapter.read()!.playing, isFalse);
      await adapter.play();
      await adapter.seek(90000);
      await adapter.setRate(0.95);
      expect(exo.calls('pause').length, 1);
      expect(exo.calls('play').length, 1);
      expect(exo.calls('seekTo').single['positionMs'], 90000);
      expect(exo.calls('setSpeed').single['speed'], 0.95);

      exo.error(id, 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED');
      expect(adapter.read(), isNull, reason: 'a failed player is not followed');
      controller.dispose();
    });
  });

  group('ExoPlayer screen in a room', () {
    late FakeExoBackend exo;

    setUp(() {
      exo = FakeExoBackend();
      OrvixExoController.defaultBackend = exo;
      AndroidExoPlayerScreen.debugEngineAnswering = () async => true;
    });

    testWidgets('solo playback is untouched', (tester) async {
      WatchPartyFeature.debugOverride = true;
      final player = await openExo(tester, _url, item: _movie);
      final id = exo.lastId;
      exo.state(id, playing: true, positionMs: 1000);
      await _pass(tester, 4000);

      expect(exo.calls('seekTo'), isEmpty);
      expect(exo.calls('setSpeed'), isEmpty);
      expect(exo.calls('pause'), isEmpty);
      expect(find.byKey(const ValueKey('watch-party-pill')), findsNothing);
      expect(room.calls, isEmpty);
      await player.close(tester);
    });

    testWidgets('a room joined with the flag off changes nothing',
        (tester) async {
      room.media = inception;
      room.stateSeq = 3;
      room.playing = true;
      room.positionMs = 600000;
      room.atMs = room.serverNowMs;
      final session = directSession();

      final player = await openExo(tester, _url, item: _movie);
      final id = exo.lastId;
      exo.state(id, playing: true, positionMs: 1000);
      await _pass(tester, 3000);

      expect(session.hasPlayer, isFalse);
      expect(exo.calls('seekTo'), isEmpty);
      expect(find.byKey(const ValueKey('watch-party-pill')), findsNothing);
      await player.close(tester);
      session.dispose();
      WatchPartyService.instance.session.value = null;
    });

    testWidgets('a participant\'s player joins the room position',
        (tester) async {
      WatchPartyFeature.debugOverride = true;
      room.media = inception;
      await WatchPartyService.instance.join('ABCDEFGH', 'Sam');
      room.channel.setConnected(true);
      room.remoteState(playing: true, positionMs: 600000);
      await _settle(tester);

      final player = await openExo(tester, _url, item: _movie);
      final id = exo.lastId;
      exo.state(id, playing: true, positionMs: 1000);
      await _pass(tester, 1500);

      final seek = exo.calls('seekTo').single['positionMs']! as int;
      expect(seek, inInclusiveRange(600000, 603000));
      expect(room.selfReady, isTrue, reason: 'reported ready to the room');
      expect(find.byKey(const ValueKey('watch-party-pill')), findsOneWidget);
      expect(room.playbackCalls, isEmpty);

      // The host pauses: the native player is paused.
      room.remoteState(playing: false, positionMs: 700000);
      await _pass(tester, 1000);
      expect(exo.calls('pause').length, 1);
      expect(exo.calls('seekTo').last['positionMs'], 700000);

      await player.close(tester);
      await _pass(tester, 1500);
      expect(room.selfReady, isFalse, reason: 'closing the player ends ready');
      await _finish(tester);
    });

    testWidgets('a different title is not synchronised', (tester) async {
      WatchPartyFeature.debugOverride = true;
      room.media = pilot;
      await WatchPartyService.instance.join('ABCDEFGH', 'Sam');
      room.remoteState(playing: true, positionMs: 600000);
      await _settle(tester);

      final player = await openExo(tester, _url, item: _movie);
      final id = exo.lastId;
      exo.state(id, playing: true, positionMs: 1000);
      await _pass(tester, 3000);

      expect(exo.calls('seekTo'), isEmpty);
      expect(room.selfReady, isFalse);
      expect(find.textContaining('The party is watching'), findsOneWidget);
      await player.close(tester);
      await _finish(tester);
    });

    testWidgets('the host\'s ExoPlayer drives the room', (tester) async {
      WatchPartyFeature.debugOverride = true;
      room.otherInRoom = true;
      await WatchPartyService.instance.create('Sam');
      room.channel.setConnected(true);
      await _settle(tester);

      final player = await openExo(tester, _url, item: _movie);
      final id = exo.lastId;
      exo.state(id, playing: true, positionMs: 125000);
      await _pass(tester, 2000);

      expect(room.mediaCalls.single.key, 'movie:tt1375666:-:-');
      expect(room.playing, isTrue);
      expect(room.positionMs, 125000);
      expect(exo.calls('seekTo'), isEmpty,
          reason: 'the host\'s player is never moved');

      // The host pauses with the player's own controls.
      exo.emit(id, {
        'event': 'state',
        'state': 3,
        'playing': false,
        'playWhenReady': false,
        'positionMs': 130000,
        'durationMs': 2640000,
        'bufferedMs': 150000,
        'speed': 1.0,
      });
      await _pass(tester, 1500);
      expect(room.playing, isFalse);
      expect(room.positionMs, 130000);

      // And resumes.
      exo.state(id, playing: true, positionMs: 130000);
      await _pass(tester, 1500);
      expect(room.playing, isTrue);

      // Closing the player pauses the room where the host was. The player's
      // own pause on exit must not rewind the room.
      exo.state(id, playing: true, positionMs: 140000);
      await _pass(tester, 600);
      await player.close(tester);
      await _pass(tester, 1500);
      expect(room.playing, isFalse);
      expect(room.positionMs, inInclusiveRange(139000, 141000));
      await _finish(tester);
    });
  });

  group('MPV player screen wiring', () {
    final source = File('lib/screens/player_screen.dart').readAsStringSync();

    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNonNegative, reason: signature);
      final end = source.indexOf('\n  }\n', start);
      return source.substring(start, end);
    }

    test('attaches once playback has started, through the service', () {
      final started = body('void _markPlaybackStarted() {');
      expect(started, contains('WatchPartyService.instance.attachPlayer('));
      expect(started, contains('MediaKitWatchPartyAdapter('));
      // Startup probing (which plays, pauses and seeks) happens before this.
      expect(started.indexOf('if (_closing || _preflightWarmup) return;'),
          lessThan(started.indexOf('attachPlayer(')));
      expect(
        'attachPlayer('.allMatches(source).length,
        1,
        reason: 'one attach point, guarded by the feature flag in the service',
      );
    });

    test('detaches before its own pause and stop on exit', () {
      final exit = body('Future<void> _preparePlayerExitInternal() async {');
      final detach = exit.indexOf('_watchParty?.detach();');
      expect(detach, isNonNegative);
      expect(detach, lessThan(exit.indexOf('_persistProgress()')));
      for (final call in ['.pause()', '.stop()']) {
        final at = exit.indexOf(call);
        if (at >= 0) expect(detach, lessThan(at), reason: call);
      }
      expect(body('void dispose() {\n    _closing = true;'),
          contains('_watchParty?.detach();'));
    });

    test('both players show the overlay and never reference the session API',
        () {
      final exo =
          File('lib/screens/android_exo_player_screen.dart').readAsStringSync();
      for (final screen in [source, exo]) {
        expect('WatchPartyPlayerOverlay('.allMatches(screen).length, 1);
        expect(screen, isNot(contains('setPlayback')));
        expect(screen, isNot(contains('WatchPartyFeature')));
      }
      expect(exo, contains('ExoWatchPartyAdapter(() => _controller)'));
    });
  });

  group('player overlay', () {
    Future<void> pumpOverlay(WidgetTester tester,
        {bool controlsVisible = true}) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              WatchPartyPlayerOverlay(controlsVisible: controlsVisible),
            ],
          ),
        ),
      ));
      await _settle(tester);
    }

    double pillOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(find.ancestor(
          of: find.byKey(const ValueKey('watch-party-pill')),
          matching: find.byType(AnimatedOpacity),
        ))
        .opacity;

    Future<void> end(WidgetTester tester, WatchPartySession session) async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      WatchPartyService.instance.session.value = null;
      await tester.pump(const Duration(seconds: 6));
    }

    testWidgets('builds nothing with the flag off or without a room',
        (tester) async {
      await pumpOverlay(tester);
      expect(find.byKey(const ValueKey('watch-party-pill')), findsNothing);

      final session = directSession();
      await pumpOverlay(tester);
      expect(find.byKey(const ValueKey('watch-party-pill')), findsNothing,
          reason: 'flag off');

      WatchPartyFeature.debugOverride = true;
      await pumpOverlay(tester);
      expect(find.byKey(const ValueKey('watch-party-pill')), findsOneWidget);
      await end(tester, session);
    });

    testWidgets('shows sync state with the controls and hides with them',
        (tester) async {
      WatchPartyFeature.debugOverride = true;
      room.media = inception;
      final session = directSession();
      room.channel.setConnected(true);
      room.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(time, positionMs: 60000);
      session.attachPlayer(player, inception);
      for (var i = 0; i < 6; i++) {
        time.nowMs += 500;
        session.tick();
        await tester.pump();
      }

      await pumpOverlay(tester);
      expect(find.text('In sync'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'people in the room');
      expect(pillOpacity(tester), 1);

      await pumpOverlay(tester, controlsVisible: false);
      expect(pillOpacity(tester), 0,
          reason: 'nothing to report: the film is left clear');

      // Something worth knowing shows even with the controls hidden.
      player.stalled = true;
      for (var i = 0; i < 6; i++) {
        time.nowMs += 500;
        session.tick();
        await tester.pump();
      }
      await _settle(tester);
      expect(find.text('Buffering…'), findsOneWidget);
      expect(pillOpacity(tester), 1);
      await end(tester, session);
    });

    testWidgets('a new message flashes briefly and counts as unread',
        (tester) async {
      WatchPartyFeature.debugOverride = true;
      final session = directSession();
      await pumpOverlay(tester, controlsVisible: false);

      room.remoteChat('popcorn ready?');
      await _settle(tester);
      expect(find.text('Friend: popcorn ready?'), findsOneWidget);
      expect(find.text('1'), findsOneWidget, reason: 'unread badge');
      expect(pillOpacity(tester), 1);

      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Friend: popcorn ready?'), findsNothing);
      await end(tester, session);
    });

    testWidgets('tapping the pill opens chat over the video', (tester) async {
      WatchPartyFeature.debugOverride = true;
      final session = directSession();
      room.remoteChat('hello');
      await pumpOverlay(tester);

      await tester.tap(find.byKey(const ValueKey('watch-party-pill')));
      await _settle(tester);
      expect(
          find.byKey(const ValueKey('watch-party-chat-input')), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(session.unreadCount, 0, reason: 'seen messages are read');

      await tester.enterText(
          find.byKey(const ValueKey('watch-party-chat-input')), 'on my way');
      await tester.tap(find.byKey(const ValueKey('watch-party-chat-send')));
      await _settle(tester);
      expect(room.chat.last.body, 'on my way');

      await tester.tap(find.byTooltip('Close'));
      await _settle(tester);
      expect(
          find.byKey(const ValueKey('watch-party-chat-input')), findsNothing);
      await end(tester, session);
    });

    testWidgets('on Android TV it is display only and never takes focus',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      WatchPartyFeature.debugOverride = true;
      final session = directSession();
      await pumpOverlay(tester);

      expect(find.byKey(const ValueKey('watch-party-pill')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('watch-party-pill')),
          warnIfMissed: false);
      await _settle(tester);
      expect(
          find.byKey(const ValueKey('watch-party-chat-input')), findsNothing);

      final focus = FocusManager.instance.primaryFocus;
      final pill =
          tester.element(find.byKey(const ValueKey('watch-party-pill')));
      var inside = false;
      focus?.context?.visitAncestorElements((element) {
        if (element == pill) inside = true;
        return !inside;
      });
      expect(inside, isFalse);
      await end(tester, session);
    });
  });
}
