import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/exo_player_preferences_service.dart';
import 'package:orvix/services/online_subtitle_service.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/player_orientation_controller.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';
import 'package:orvix/widgets/exo_subtitle_view.dart';
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

  /// Scrolls the open player menu to [finder] and taps it.
  Future<void> tapInPanel(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets(
      'aspect ratio cycles Fit, Fill and Zoom without ever stretching, and '
      'the choice is restored next time', (tester) async {
    await openExo(tester, _url);
    await playing(tester);
    FittedBox box() => tester.widget<FittedBox>(find.byType(FittedBox).first);
    Finder zoomed() => find.ancestor(
          of: find.byType(FittedBox).first,
          matching: find.byType(Transform),
        );
    expect(box().fit, BoxFit.contain, reason: 'Fit shows the whole picture');
    expect(zoomed(), findsNothing);
    await tapLabel(tester, 'Aspect ratio Fit');
    expect(box().fit, BoxFit.cover,
        reason: 'Fill covers the screen by cropping, never by stretching');
    await tapLabel(tester, 'Aspect ratio Fill');
    expect(box().fit, BoxFit.contain);
    expect(zoomed(), findsOneWidget, reason: 'Zoom enlarges the picture');
    for (final fit in [for (final b in tester.widgetList<FittedBox>(
        find.byType(FittedBox))) b.fit]) {
      expect(fit, isNot(BoxFit.fill), reason: 'no mode stretches the video');
    }
    expect(await ExoPlayerPreferencesService.aspectMode(), ExoAspectMode.zoom);

    // A new session opens in the saved mode.
    final second = await openExo(tester, _url);
    await playing(tester);
    expect(labelled('Aspect ratio Zoom'), findsOneWidget);
    await second.close(tester);
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

  group('startup and errors', () {
    testWidgets('the loading screen follows the real startup stage',
        (tester) async {
      await openExo(tester, _url);
      final id = backend.lastId;
      backend.state(id, state: 2, playing: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Connecting to the source…'), findsOneWidget);

      backend.state(id, state: 2, playing: false, bytesLoaded: 3 * 1024 * 1024,
          httpStatus: 206);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Loading video…'), findsOneWidget);
      expect(find.text('Received 3.0 MB'), findsOneWidget);

      backend.diag(id, 'videoDecoder', {'name': 'c2.android.avc.decoder'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Starting playback…'), findsOneWidget);

      backend.state(id, positionMs: 400, bytesLoaded: 4 * 1024 * 1024);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Starting playback…'), findsNothing);
    });

    testWidgets(
        'a decoder failure says so, keeps the user in control and puts the '
        'remote on Try MPV', (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      final player = await openExo(tester, _url, size: const Size(1920, 1080));
      backend.error(
        backend.lastId,
        'ERROR_CODE_DECODER_INIT_FAILED',
        causes: ['DecoderInitializationException'],
        rendererMime: 'video/hevc',
        rendererCodecs: 'hvc1.2.4.L153',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Could not play this stream'), findsOneWidget);
      expect(find.text('Video format not supported'), findsOneWidget);
      expect(find.textContaining('HEVC'), findsOneWidget);
      expect(focusedLabel(), 'Try MPV');
      // No automatic engine switch: the route stays open until the user acts.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Could not play this stream'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      final closed = await player.close(tester, pop: false);
      expect(closed?.switchToMpv, isTrue);
      expect(closed?.failed, isTrue);
    });

    testWidgets('an expired link is reported as a source problem and Retry '
        'reopens the same stream', (tester) async {
      await openExo(tester, _url);
      backend.error(
        backend.lastId,
        'ERROR_CODE_IO_BAD_HTTP_STATUS',
        httpStatus: 403,
        causes: ['InvalidResponseCodeException'],
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Source unavailable'), findsOneWidget);
      expect(find.textContaining('HTTP 403'), findsOneWidget);
      await tapLabel(tester, 'Retry in ExoPlayer');
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(backend.created, hasLength(2));
      expect(backend.created.last['url'], _url);
      expect(find.text('Could not play this stream'), findsNothing);
    });

    testWidgets('the copied playback report has codes but no URL or hash',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      const secretUrl = 'https://cdn.example.org/d/AbCdEf0123456789AbCdEf0123456789/'
          'Movie.mkv?token=topsecret';
      await openExo(tester, secretUrl);
      final id = backend.lastId;
      backend.tracks(id, _tracks);
      backend.error(id, 'ERROR_CODE_IO_BAD_HTTP_STATUS',
          httpStatus: 410, message: 'Response code: 410 for $secretUrl');
      await tester.pump(const Duration(milliseconds: 600));
      await tapLabel(tester, 'Playback details');
      await tester.tap(find.text('Copy playback report'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copied, isNotNull);
      expect(copied, contains('ERROR_CODE_IO_BAD_HTTP_STATUS'));
      expect(copied, contains('http=410'));
      expect(copied, contains('platform: Android Mobile'));
      expect(copied, contains('HTTPS stream, Matroska'));
      expect(copied, isNot(contains('topsecret')));
      expect(copied, isNot(contains('AbCdEf0123456789')));
      expect(copied, isNot(contains('cdn.example.org/d')));
    });
  });

  group('subtitle style and persistence', () {
    testWidgets('style changes render on the real subtitles and are saved',
        (tester) async {
      await openExo(tester, _url);
      final id = await playing(tester);
      backend.cues(id, ['Say my name.']);
      await tester.pump(const Duration(milliseconds: 300));

      await tapLabel(tester, 'Subtitles');
      await tapInPanel(tester, find.text('Subtitle style'));
      await tapInPanel(tester, labelled('Text color up'));
      await tapInPanel(tester, labelled('Edge style up')); // -> drop shadow
      await tapInPanel(tester, labelled('Window opacity up'));
      await tapInPanel(tester, labelled('Alignment up')); // center -> right

      ExoSubtitleText rendered() => tester.widget<ExoSubtitleText>(
            find.ancestor(
              of: find.text('Say my name.'),
              matching: find.byType(ExoSubtitleText),
            ),
          );
      expect(rendered().style.textColor, 0xFFFFE14D, reason: 'yellow');
      expect(rendered().style.edge, SubtitleEdgeStyle.dropShadow);
      final text = tester.widget<Text>(find.text('Say my name.'));
      expect(text.style?.color, const Color(0xFFFFE14D));
      expect(text.style?.shadows, isNotEmpty);
      expect(text.textAlign, TextAlign.right);

      final saved = await ExoPlayerPreferencesService.subtitleStyle();
      expect(saved.textColor, 0xFFFFE14D);
      expect(saved.edge, SubtitleEdgeStyle.dropShadow);
      expect(saved.windowOpacity, closeTo(.1, .001));
      expect(saved.alignment, SubtitleAlignment.right);

      await tapInPanel(tester, find.text('Reset subtitle style'));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(rendered().style.textColor, 0xFFFFFFFF);
      expect(rendered().style.edge, SubtitleEdgeStyle.outline);
    });

    testWidgets('the outline is a real stroke under the text', (tester) async {
      await openExo(tester, _url);
      final id = await playing(tester);
      backend.cues(id, ['Outlined']);
      await tester.pump(const Duration(milliseconds: 300));
      final strokes = tester
          .widgetList<RichText>(find.descendant(
            of: find.byType(ExoSubtitleText),
            matching: find.byType(RichText),
          ))
          .where((rich) =>
              rich.text.style?.foreground?.style == PaintingStyle.stroke);
      expect(strokes, hasLength(1));
      expect(find.text('Outlined'), findsOneWidget,
          reason: 'the subtitle itself is found once');
    });

    testWidgets('subtitles turned off stay off in the next session',
        (tester) async {
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
        return const <OnlineSubtitleResult>[];
      };
      final first = await openExo(tester, _url, item: exoTestMovie);
      await playing(tester);
      await tapLabel(tester, 'Subtitles');
      await tester.tap(find.text('Off'));
      await tester.pump(const Duration(milliseconds: 300));
      await first.close(tester);

      await openExo(tester, _url, item: exoTestMovie);
      expect(backend.created.last['textDisabled'], isTrue);
      final id = await playing(tester);
      expect(find.text('Subtitles off'), findsOneWidget,
          reason: 'the control shows the remembered state');
      backend.tracks(id, [_tracks[0]]);
      await tester.pump(const Duration(seconds: 7));
      expect(searches, 0, reason: 'no automatic OpenSubtitles when off');
    });

    testWidgets('the chosen subtitle and audio languages are remembered',
        (tester) async {
      final first = await openExo(tester, _url);
      final id = await playing(tester);
      backend.tracks(id, _tracks);
      await tester.pump(const Duration(milliseconds: 300));
      await tapLabel(tester, 'Subtitles');
      await tester.tap(find.text('Sinhala'));
      await tester.pump(const Duration(milliseconds: 300));
      await tapLabel(tester, 'Audio');
      await tester.tap(find.text('Spanish • Stereo'));
      await tester.pump(const Duration(milliseconds: 300));
      await first.close(tester);

      await openExo(tester, _url);
      expect(backend.created.last['preferredTextLanguage'], 'si');
      expect(backend.created.last['preferredAudioLanguage'], 'es');
      expect(backend.created.last['textDisabled'], isFalse);
    });

    testWidgets('Automatic audio returns the choice to the player',
        (tester) async {
      await openExo(tester, _url);
      final id = await playing(tester);
      backend.tracks(id, _tracks);
      await tester.pump(const Duration(milliseconds: 300));
      await tapLabel(tester, 'Audio');
      await tester.tap(find.text('Automatic'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls('selectTrack').last,
          {'type': 'audio', 'group': -1, 'track': -1});
    });

    testWidgets('subtitle timing survives seeking and resets to zero',
        (tester) async {
      await openExo(tester, _url);
      final id = await playing(tester, positionMs: 5000);
      await tapLabel(tester, 'Subtitles');
      await tapLabel(tester, 'Timing down');
      await tapLabel(tester, 'Timing down');
      expect(backend.calls('setSubtitleOffset').last, {'offsetMs': -500});
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tapLabel(tester, 'Forward 10 seconds');
      backend.state(id, positionMs: 15000);
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls('setSubtitleOffset').last, {'offsetMs': -500},
          reason: 'a seek does not touch the delay');
      await tapLabel(tester, 'Subtitles');
      await tester.tap(find.text('Reset timing'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls('setSubtitleOffset').last, {'offsetMs': 0});
    });

    testWidgets('a top-placed cue stays at the top of the picture',
        (tester) async {
      await openExo(tester, _url);
      final id = await playing(tester);
      backend.cues(id, ['SIGN: Los Pollos Hermanos'], top: true);
      await tester.pump(const Duration(milliseconds: 300));
      final y = tester.getCenter(find.text('SIGN: Los Pollos Hermanos')).dy;
      expect(y, lessThan(720 / 2));
    });
  });

  group('controls', () {
    testWidgets('the skip step is configurable and saved', (tester) async {
      await openExo(tester, _url);
      await playing(tester, positionMs: 60000);
      await tapLabel(tester, 'Player settings');
      await tapLabel(tester, 'Skip step up'); // 10 -> 15
      await tapLabel(tester, 'Skip step up'); // 15 -> 30
      expect(await ExoPlayerPreferencesService.seekStepSeconds(), 30);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tapLabel(tester, 'Back 30 seconds');
      expect(backend.calls('seekTo').last, {'positionMs': 30000});
    });

    testWidgets('zoom level is adjustable and turns Zoom on', (tester) async {
      await openExo(tester, _url);
      await playing(tester);
      await tapLabel(tester, 'Player settings');
      await tapLabel(tester, 'Zoom level up');
      expect(await ExoPlayerPreferencesService.zoom(), closeTo(1.2, .001));
      expect(await ExoPlayerPreferencesService.aspectMode(), ExoAspectMode.zoom);
      final transform = tester.widget<Transform>(find.ancestor(
        of: find.byType(FittedBox).first,
        matching: find.byType(Transform),
      ));
      expect(transform.transform.getMaxScaleOnAxis(), closeTo(1.2, .001));
    });

    testWidgets('a playing film pauses when the app goes to the background, '
        'a starting stream keeps loading', (tester) async {
      await openExo(tester, _url);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.calls('pause'), isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await playing(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.calls('pause'), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    });
  });

  group('orientation', () {
    late List<String> calls;
    setUp(() {
      calls = <String>[];
      AndroidExoPlayerScreen.debugOrientationController = (tv) =>
          PlayerOrientationController(
            isTv: tv,
            setOrientations: (o) async =>
                calls.add('orient:${o.map((e) => e.name).join(',')}'),
            setUiMode: (m) async => calls.add('ui:${m.name}'),
          );
    });
    tearDown(() => AndroidExoPlayerScreen.debugOrientationController = null);

    testWidgets(
        'a phone plays in landscape fullscreen and gets its normal policy '
        'back on exit', (tester) async {
      final player =
          await openExo(tester, _url, size: const Size(390, 844));
      expect(calls, [
        'ui:immersiveSticky',
        'orient:landscapeLeft,landscapeRight',
      ]);
      await playing(tester);
      calls.clear();
      await player.close(tester);
      expect(calls, ['orient:', 'ui:edgeToEdge'],
          reason: 'no lock is left behind, not even portrait');
    });

    testWidgets('returning from the background re-applies fullscreen',
        (tester) async {
      await openExo(tester, _url, size: const Size(390, 844));
      calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, [
        'ui:immersiveSticky',
        'orient:landscapeLeft,landscapeRight',
      ]);
    });

    testWidgets('a tablet hides the system bars without locking rotation',
        (tester) async {
      final player =
          await openExo(tester, _url, size: const Size(800, 1280));
      expect(calls, ['ui:immersiveSticky']);
      calls.clear();
      await player.close(tester);
      expect(calls, ['ui:edgeToEdge']);
    });

    testWidgets('Android TV is never touched', (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      await openExo(tester, _url, size: const Size(1920, 1080));
      await playing(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, isEmpty);
    });
  });

  group('Android TV remote: menus', () {
    setUp(() => PlatformProfile.debugAndroidTvOverride = true);

    Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('closing a menu returns focus to the button that opened it',
        (tester) async {
      await openExo(tester, _url, size: const Size(1920, 1080));
      final id = await playing(tester);
      backend.tracks(id, _tracks);
      await tester.pump(const Duration(milliseconds: 300));
      var guard = 0;
      while (focusedLabel() != 'Audio' && guard++ < 8) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(), 'Audio');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('Automatic'), findsOneWidget);
      // Left/Right inside the menu never escape to the controls behind it.
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('Automatic'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Automatic'), findsNothing);
      expect(focusedLabel(), 'Audio');
    });

    testWidgets('Left/Right change a setting row; Up/Down move between rows',
        (tester) async {
      await openExo(tester, _url, size: const Size(1920, 1080));
      await playing(tester);
      await tester.binding.handlePopRoute(); // hide controls
      await tester.pump(const Duration(milliseconds: 300));
      await key(tester, LogicalKeyboardKey.contextMenu);
      expect(find.text('Player settings'), findsWidgets);
      // First row (Picture) has focus: Right switches Fit -> Fill.
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(await ExoPlayerPreferencesService.aspectMode(), ExoAspectMode.fill);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown); // Skip step
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(await ExoPlayerPreferencesService.seekStepSeconds(), 5);
    });

    testWidgets('media keys work while a button has focus', (tester) async {
      await openExo(tester, _url, size: const Size(1920, 1080));
      await playing(tester, positionMs: 30000);
      expect(focusedLabel(), 'Pause');
      await key(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(backend.calls('pause'), hasLength(1));
      await key(tester, LogicalKeyboardKey.mediaFastForward);
      expect(backend.calls('seekTo').last, {'positionMs': 40000});
    });

    testWidgets('holding Right scrubs and seeks once on release',
        (tester) async {
      await openExo(tester, _url, size: const Size(1920, 1080));
      await playing(tester, positionMs: 60000);
      await tester.binding.handlePopRoute(); // hide controls, surface focused
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.calls('seekTo'), hasLength(1));
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(backend.calls('seekTo'), hasLength(1),
          reason: 'repeats move the preview only');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.calls('seekTo'), hasLength(2));
      // The first press seeked from 60 s to 70 s; the four repeats scrub
      // from there to 110 s.
      expect(backend.calls('seekTo').first, {'positionMs': 70000});
      expect(backend.calls('seekTo').last, {'positionMs': 110000});
    });
  });
}
