// Android TV ExoPlayer controls and buffering with real fonts at 720p, 1080p
// and 4K logical sizes. Nothing may overflow, the remote reaches every
// control, and ORVIX_CAPTURE_DIR receives screenshots.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/online_subtitle_service.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_exo_backend.dart';
import 'support/tv_visual.dart';

const _remote = 'https://cdn.example.org/breaking.bad.s01e01.mkv';
const _p2p =
    'http://127.0.0.1:11470/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/0';

const _tracks = <Map<String, Object?>>[
  {
    'type': 'audio',
    'group': 1,
    'track': 0,
    'language': 'en',
    'mimeType': 'audio/eac3',
    'channels': 6,
    'selected': true,
    'supported': true,
  },
  {
    'type': 'text',
    'group': 2,
    'track': 0,
    'language': 'en',
    'mimeType': OrvixExoTrack.parsedCuesMime,
    'codecs': 'application/x-subrip',
    'selected': true,
    'supported': true,
  },
];

void main() {
  late FakeExoBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformProfile.debugAndroidTvOverride = true;
    backend = FakeExoBackend();
    OrvixExoController.defaultBackend = backend;
    AndroidExoPlayerScreen.debugEngineAnswering = () async => true;
    AndroidExoPlayerScreen.debugSearchSubtitles = ({
      required item,
      episode,
      releaseHint,
      videoSize,
      videoHash,
      preferredLanguage = 'eng',
    }) async =>
        const <OnlineSubtitleResult>[];
  });
  tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  String? focusedLabel() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    String? label;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Semantics && widget.properties.label != null) {
        label = widget.properties.label;
        return false;
      }
      return true;
    });
    return label;
  }

  for (final entry in tvCanvases.entries) {
    testWidgets('TV player controls ${entry.key}: real fonts, no overflow',
        (tester) async {
      if (!await loadTvFonts()) {
        markTestSkipped('Flutter SDK fonts not found');
        return;
      }
      final exo = await openExo(
        tester,
        _remote,
        size: entry.value,
        item: exoTestMovie,
        nextEpisodeLabel: "S01E02 Cat's in the Bag...",
      );
      final id = backend.lastId;
      backend.tracks(id, _tracks);
      backend.state(id, positionMs: 27000, durationMs: 3666000);
      backend.cues(id, ['My name is Walter Hartwell White.']);
      await settle(tester);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(focusedLabel(), 'Pause', reason: 'The remote lands on Pause');
      await captureTv(tester, 'player-${entry.key}-controls');

      // Every control is one row away: Right walks the whole row.
      final seen = <String?>{focusedLabel()};
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
        seen.add(focusedLabel());
        if (i == 1) await captureTv(tester, 'player-${entry.key}-focus-tool');
      }
      await captureTv(tester, 'player-${entry.key}-focus-mpv');
      expect(
        seen,
        containsAll(<String>[
          'Forward 10 seconds',
          'Subtitles',
          'Audio',
          'Playback speed',
          'Aspect ratio Fit',
          'Next episode',
          'Player settings',
          'Switch to MPV',
        ]),
      );
      expect(tester.takeException(), isNull);
      // Up reaches the timeline, then Back.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusedLabel(), 'Timeline');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusedLabel(), 'Back');
      await tester.binding.handlePopRoute(); // hide the controls
      await settle(tester);
      await exo.close(tester);
    });
  }

  testWidgets('TV subtitle menu and settings panel at 1080p', (tester) async {
    if (!await loadTvFonts()) {
      markTestSkipped('Flutter SDK fonts not found');
      return;
    }
    final exo = await openExo(tester, _remote,
        size: tvCanvases['1080p']!, item: exoTestMovie);
    final id = backend.lastId;
    backend.tracks(id, _tracks);
    backend.state(id, positionMs: 27000, durationMs: 3666000);
    await settle(tester);
    while (focusedLabel() != 'Subtitles') {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.text('IN THIS VIDEO'), findsOneWidget);
    expect(find.textContaining('SRT'), findsWidgets,
        reason: 'Media3 parsed-cue tracks show their real format');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    await captureTv(tester, 'player-1080p-subtitles-panel');
    expect(tester.takeException(), isNull);
    // The style sheet: live preview and every working style control.
    await tester.scrollUntilVisible(find.text('Subtitle style'), 120,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Subtitle style'));
    await settle(tester);
    for (final label in ['Size', 'Font', 'Reset subtitle style']) {
      await tester.scrollUntilVisible(find.text(label), 120,
          scrollable: find.byType(Scrollable).last);
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.scrollUntilVisible(find.text('Size'), -120,
        scrollable: find.byType(Scrollable).last);
    await settle(tester);
    await captureTv(tester, 'player-1080p-style-panel');
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute(); // back to Subtitles
    await settle(tester);
    // Back closes only the menu, and focus returns to Subtitles.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('IN THIS VIDEO'), findsNothing);
    expect(focusedLabel(), 'Subtitles');
    await tester.binding.handlePopRoute(); // hide the controls
    await settle(tester);
    await exo.close(tester);
  });

  testWidgets('TV buffering: quiet ring first, then what is really happening',
      (tester) async {
    if (!await loadTvFonts()) {
      markTestSkipped('Flutter SDK fonts not found');
      return;
    }
    final exo = await openExo(tester, _p2p,
        size: tvCanvases['1080p']!, item: exoTestMovie);
    final id = backend.lastId;
    backend.state(id, positionMs: 600000, durationMs: 3666000,
        bytesLoaded: 50 << 20);
    await settle(tester);
    await tester.binding.handlePopRoute(); // hide the controls
    await settle(tester);

    // Buffering starts: nothing for a moment, then a small ring.
    backend.state(id, state: 2, playing: false, positionMs: 600000,
        durationMs: 3666000, bytesLoaded: 50 << 20);
    await tester.pump();
    expect(find.byKey(const ValueKey('exo-tv-buffering-ring')), findsNothing);
    // The buffering clock is a real Stopwatch.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    backend.state(id, state: 2, playing: false, positionMs: 600000,
        durationMs: 3666000, bytesLoaded: 50 << 20);
    await settle(tester);
    expect(find.byKey(const ValueKey('exo-tv-buffering-ring')), findsOneWidget);
    expect(find.textContaining('Waiting for peers'), findsNothing);
    await captureTv(tester, 'player-1080p-buffering-brief');

    // Still no new data after the slow notice: waiting for peers.
    await tester.runAsync(
        () => Future<void>.delayed(AndroidExoPlayerScreen.slowBufferNoticeAfter));
    backend.state(id, state: 2, playing: false, positionMs: 600000,
        durationMs: 3666000, bytesLoaded: 50 << 20);
    await settle(tester);
    expect(find.text('Waiting for peers…'), findsOneWidget);
    await captureTv(tester, 'player-1080p-buffering-peers');

    // Data arrives: it says so instead of claiming no peers.
    backend.state(id, state: 2, playing: false, positionMs: 600000,
        durationMs: 3666000, bytesLoaded: (50 << 20) + (3 << 20));
    await settle(tester);
    expect(find.text('Waiting for peers…'), findsNothing);
    expect(find.text('3.0 MB from peers so far'), findsOneWidget);
    await captureTv(tester, 'player-1080p-buffering-receiving');
    expect(tester.takeException(), isNull);

    // No deadline: three more minutes of timers end nothing.
    await tester.pump(const Duration(minutes: 3));
    backend.state(id, state: 2, playing: false, positionMs: 600000,
        durationMs: 3666000, bytesLoaded: (50 << 20) + (3 << 20));
    await settle(tester);
    expect(find.text('Buffering'), findsOneWidget);
    expect(find.text('Try MPV'), findsNothing, reason: 'Never a false error');
    await exo.close(tester);
  });

  test('buffering status follows real signals', () {
    expect(
      exoBufferingStatus(
              localP2p: true,
              bufferingFor: const Duration(seconds: 2),
              bytesSinceStart: 0)
          .phase,
      ExoBufferPhase.brief,
    );
    expect(
      exoBufferingStatus(
              localP2p: true,
              bufferingFor: const Duration(seconds: 30),
              bytesSinceStart: 0)
          .phase,
      ExoBufferPhase.waitingForPeers,
    );
    expect(
      exoBufferingStatus(
              localP2p: false,
              bufferingFor: const Duration(seconds: 30),
              bytesSinceStart: 0)
          .phase,
      ExoBufferPhase.slowSource,
    );
    final receiving = exoBufferingStatus(
        localP2p: false,
        bufferingFor: const Duration(seconds: 30),
        bytesSinceStart: 512 * 1024);
    expect(receiving.phase, ExoBufferPhase.receiving);
    expect(receiving.detail, '512 KB received so far');
  });
}
