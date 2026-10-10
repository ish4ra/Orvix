import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/online_subtitle_service.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_exo_backend.dart';

// The Android ExoPlayer screen: subtitles (embedded, off, OpenSubtitles,
// automatic), timing and size, audio and speed, aspect modes, next episode,
// Orvix colors and Android TV DPAD/Back behavior. The native Media3 bridge is
// replaced by a fake that sends the same events.

const _url = 'https://cdn.example.org/breaking.bad.s01e01.mkv';

const _englishSrt = '''1
00:00:01,000 --> 00:00:04,000
Say my name.

2
00:00:05,000 --> 00:00:08,000
You're goddamn right.
''';

final _tracks = <Map<String, Object?>>[
  {
    'type': 'audio',
    'group': 0,
    'track': 0,
    'language': 'en',
    'channels': 6,
    'codecs': 'ac-3',
    'selected': true,
    'supported': true,
  },
  {
    'type': 'audio',
    'group': 1,
    'track': 0,
    'language': 'es',
    'channels': 2,
    'selected': false,
    'supported': true,
  },
  {
    'type': 'text',
    'group': 2,
    'track': 0,
    'language': 'en',
    'label': 'SDH',
    'mimeType': 'application/x-subrip',
    'selected': true,
    'supported': true,
  },
  {
    'type': 'text',
    'group': 3,
    'track': 0,
    'language': 'si',
    'mimeType': 'text/x-ssa',
    'selected': false,
    'supported': true,
  },
];

void main() {
  late FakeExoBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  Future<int> playing(WidgetTester tester, {int positionMs = 0}) async {
    final id = backend.lastId;
    backend.state(id, positionMs: positionMs);
    await tester.pump(const Duration(milliseconds: 300));
    return id;
  }

  Finder labelled(String label) => find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      );

  Future<void> tapLabel(WidgetTester tester, String semanticLabel) async {
    await tester.tap(labelled(semanticLabel).first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('Latin-1 subtitle files decode instead of failing', () {
    final bytes = <int>[...'1\n00:00:01,000 --> 00:00:02,000\nCaf'.codeUnits, 0xE9];
    expect(AndroidExoPlayerScreen.decodeSubtitleBytes(bytes), endsWith('Café'));
    expect(
      AndroidExoPlayerScreen.decodeSubtitleBytes([83, 101, 195, 177, 111, 114]),
      'Señor',
      reason: 'UTF-8 stays UTF-8',
    );
  });

  testWidgets('the default subtitle language is requested from the player',
      (tester) async {
    await openExo(tester, _url);
    expect(backend.created.single['preferredTextLanguage'], 'eng');
    expect(backend.created.single['preferredAudioLanguage'], 'en');
  });

  testWidgets('embedded subtitles render and can be switched and turned off',
      (tester) async {
    await openExo(tester, _url);
    final id = await playing(tester);
    backend.tracks(id, _tracks);
    backend.cues(id, ['Say my name.']);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Say my name.'), findsOneWidget);

    await tapLabel(tester, 'Subtitles');
    expect(find.text('English • SDH'), findsOneWidget);
    expect(find.text('Sinhala'), findsOneWidget);
    await tester.tap(find.text('Sinhala'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.calls('selectTrack').last,
        {'type': 'text', 'group': 3, 'track': 0});

    await tapLabel(tester, 'Subtitles');
    await tester.tap(find.text('Off'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.calls('selectTrack').last,
        {'type': 'text', 'group': -1, 'track': -1});
    backend.cues(id, ['still decoded']);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('still decoded'), findsNothing,
        reason: 'Off hides subtitles');
  });

  testWidgets('subtitle timing and size are adjustable', (tester) async {
    await openExo(tester, _url);
    await playing(tester);
    await tapLabel(tester, 'Subtitles');
    await tapLabel(tester, 'Timing up');
    await tapLabel(tester, 'Timing up');
    expect(backend.calls('setSubtitleOffset').last, {'offsetMs': 500});
    expect(find.text('+0.5s'), findsOneWidget);
    await tapLabel(tester, 'Timing down');
    await tapLabel(tester, 'Timing down');
    await tapLabel(tester, 'Timing down');
    expect(backend.calls('setSubtitleOffset').last, {'offsetMs': -250});

    final before = await SubtitlePreferencesService.fontSize();
    await tapLabel(tester, 'Size up');
    expect(await SubtitlePreferencesService.fontSize(), before + 2,
        reason: 'shared with the MPV player');
  });

  testWidgets(
      'OpenSubtitles results load as an external subtitle with timing',
      (tester) async {
    AndroidExoPlayerScreen.debugSearchSubtitles = ({
      required item,
      episode,
      releaseHint,
      videoSize,
      videoHash,
      preferredLanguage = 'eng',
    }) async =>
        const [
          OnlineSubtitleResult(
            id: '1',
            url: 'https://subs.example/1.srt',
            language: 'eng',
            languageLabel: 'English',
            label: 'Breaking.Bad.S01E01.720p.BluRay',
            provider: 'OpenSubtitles v3',
            score: 900,
          ),
        ];
    AndroidExoPlayerScreen.debugDownloadSubtitle = (_) async => _englishSrt;
    await openExo(tester, _url, item: exoTestMovie);
    final id = await playing(tester, positionMs: 1500);
    backend.tracks(id, _tracks);
    await tester.pump(const Duration(milliseconds: 300));

    await tapLabel(tester, 'Subtitles');
    await tester.tap(find.text('Search OpenSubtitles'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Breaking.Bad.S01E01.720p.BluRay'), findsOneWidget);
    await tester.tap(find.text('English'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(backend.calls('selectTrack').last['group'], -1,
        reason: 'embedded subtitles step aside for the external file');
    backend.state(id, positionMs: 2000);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Say my name.'), findsOneWidget);

    // Timing applies to the external file: +1 s shows line 1 later.
    await tapLabel(tester, 'Subtitles');
    for (var i = 0; i < 4; i++) {
      await tapLabel(tester, 'Timing up');
    }
    backend.state(id, positionMs: 1500);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Say my name.'), findsNothing);
    backend.state(id, positionMs: 2100);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Say my name.'), findsOneWidget);
  });

  testWidgets(
      'without a subtitle track the preferred-language OpenSubtitles match '
      'loads automatically', (tester) async {
    var searches = 0;
    AndroidExoPlayerScreen.debugSearchSubtitles = ({
      required item,
      episode,
      releaseHint,
      videoSize,
      videoHash,
      preferredLanguage = 'eng',
    }) async {
      searches++;
      return const [
        OnlineSubtitleResult(
          id: '2',
          url: 'https://subs.example/2.srt',
          language: 'eng',
          languageLabel: 'English',
          label: 'match',
          provider: 'OpenSubtitles v3',
          score: 800,
        ),
      ];
    };
    AndroidExoPlayerScreen.debugDownloadSubtitle = (_) async => _englishSrt;
    await openExo(tester, _url, item: exoTestMovie);
    final id = await playing(tester);
    backend.tracks(id, [_tracks[0]]); // audio only, no subtitles
    await tester.pump(const Duration(seconds: 7));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(searches, 1);
    backend.state(id, positionMs: 6000);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("You're goddamn right."), findsOneWidget);
  });

  testWidgets('audio tracks and playback speed are selectable',
      (tester) async {
    await openExo(tester, _url);
    final id = await playing(tester);
    backend.tracks(id, _tracks);
    await tester.pump(const Duration(milliseconds: 300));

    await tapLabel(tester, 'Audio');
    expect(find.text('English • 5.1'), findsOneWidget);
    await tester.tap(find.text('Spanish • Stereo'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.calls('selectTrack').last,
        {'type': 'audio', 'group': 1, 'track': 0});

    await tapLabel(tester, 'Playback speed');
    await tester.tap(find.text('1.5x'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.calls('setSpeed').last, {'speed': 1.5});
  });

  testWidgets('aspect ratio cycles Fit, Fill and Zoom', (tester) async {
    await openExo(tester, _url);
    await playing(tester);
    FittedBox box() => tester.widget<FittedBox>(find.byType(FittedBox).first);
    expect(box().fit, BoxFit.contain);
    await tapLabel(tester, 'Aspect ratio Fit');
    expect(box().fit, BoxFit.fill);
    await tapLabel(tester, 'Aspect ratio Fill');
    expect(box().fit, BoxFit.cover);
    await tapLabel(tester, 'Aspect ratio Zoom');
    expect(box().fit, BoxFit.contain);
  });

  testWidgets('next episode closes the player with playNext', (tester) async {
    final player =
        await openExo(tester, _url, nextEpisodeLabel: 'S01E02 Cat\'s in the Bag');
    await playing(tester);
    expect(find.textContaining('Next: S01E02'), findsOneWidget);
    await tapLabel(tester, 'Next episode');
    final closed = await player.close(tester, pop: false);
    expect(closed?.playNext, isTrue);
    expect(closed?.started, isTrue);
  });

  testWidgets('Orvix colors are used for the player surfaces', (tester) async {
    expect(ExoPlayerColors.lime, const Color(0xFFB9FF45));
    expect(ExoPlayerColors.lightLime, const Color(0xFFCBFF75));
    expect(ExoPlayerColors.background, const Color(0xFF050806));
    expect(ExoPlayerColors.canvas, const Color(0xFF070A08));
    expect(ExoPlayerColors.surface, const Color(0xFF0B0F0C));
    expect(ExoPlayerColors.card, const Color(0xFF0D120E));
    await openExo(tester, _url);
    await playing(tester);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, ExoPlayerColors.background);
  });

  group('Android TV remote', () {
    setUp(() => PlatformProfile.debugAndroidTvOverride = true);

    Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 200));
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

    testWidgets(
        'DPAD reaches the controls, OK opens subtitles, Back steps out one '
        'layer at a time', (tester) async {
      final player = await openExo(tester, _url, size: const Size(1920, 1080));
      final id = await playing(tester);
      backend.tracks(id, _tracks);
      await tester.pump(const Duration(milliseconds: 300));
      expect(focusedLabel(), 'Pause', reason: 'Play/Pause takes focus on TV');

      // Right moves along the control row to Subtitles.
      var guard = 0;
      while (focusedLabel() != 'Subtitles' && guard++ < 6) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(), 'Subtitles');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('IN THIS VIDEO'), findsOneWidget);
      final primary = FocusManager.instance.primaryFocus?.context?.widget;
      expect(primary, isNotNull);
      expect(find.text('Off'), findsOneWidget);

      // Back closes the panel, then hides the controls, then exits.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('IN THIS VIDEO'), findsNothing);
      expect(labelled('Subtitles'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(labelled('Subtitles'), findsNothing,
          reason: 'controls hidden, video stays');

      // Left/right seek while the controls are hidden (and show them).
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(backend.calls('seekTo').last, {'positionMs': 10000});
      expect(labelled('Subtitles'), findsOneWidget);

      // Back hides the controls again; the next Back leaves the player.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      final closed = await player.close(tester);
      expect(closed?.started, isTrue);
    });
  });
}
