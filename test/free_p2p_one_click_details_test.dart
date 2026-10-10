import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/screens/tv_source_browser_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/free_p2p_playback_trace.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _series = MediaItem(
  id: 'tt0499550',
  kind: MediaKind.series,
  title: 'Trigger',
  year: '2025',
  episodes: [
    EpisodeItem(id: 'e1', season: 1, episode: 1, title: 'Pilot'),
    EpisodeItem(id: 'e2', season: 1, episode: 2, title: 'Second'),
  ],
);

const _movie = MediaItem(
  id: 'tt0499549',
  kind: MediaKind.movie,
  title: 'Trigger',
  year: '2025',
  runtime: '1h 50m',
);

/// One provider release: [hash] torrent, reported [seeders].
typedef _Release = ({String tag, String hash, int seeders});

final _best = (tag: 'BEST', hash: 'b' * 40, seeders: 40);
final _second = (tag: 'SECOND', hash: 'c' * 40, seeders: 30);
final _hyped = (tag: 'HYPED', hash: 'd' * 40, seeders: 500);

class _OfflineCatalog implements CatalogService {
  @override
  Future<MediaItem?> details(MediaItem item) async => item;

  @override
  Future<void> prefetchDetails(MediaItem item) async {}

  @override
  MediaItem? peekDetails(MediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PikPak implements PikPakService {
  _PikPak({this.signedIn = false});

  final bool signedIn;

  @override
  Future<bool> get isSignedIn async => signedIn;

  @override
  Future<List<PikPakFile>> listFiles({String parentId = ''}) async =>
      const <PikPakFile>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TorBox implements TorBoxService {
  _TorBox({this.connected = false});

  final bool connected;

  @override
  Future<bool> get isConnected async => connected;

  @override
  Future<List<TorBoxItem>> listTorrents({bool fresh = false}) async =>
      const <TorBoxItem>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

MockClient _provider(List<_Release> releases) =>
    MockClient((request) async => http.Response(
          jsonEncode({
            'streams': [
              for (final r in releases)
                {
                  'name': 'Torrentio\n1080p',
                  'title': 'Trigger.2025.1080p.WEB-DL.x264-${r.tag}\n'
                      'Seeders: ${r.seeders} Size: 2.1 GB',
                  'infoHash': r.hash,
                  'fileIdx': 0,
                },
            ],
          }),
          200,
        ));

/// The local stream engine. Live torrents serve media bytes; dead ones
/// serve nothing; [failPlayback] torrents pass the live check but their
/// playback resolve is rejected (the source does not start).
class _Engine {
  _Engine({
    required this.live,
    this.failPlayback = const <String>{},
  });

  final Set<String> live;
  final Set<String> failPlayback;
  final creates = <String, int>{};
  final removed = <String>[];

  int get totalCreates => creates.values.fold(0, (a, b) => a + b);

  late final MockClient client = MockClient.streaming((request, body) async {
    final path = request.url.path;
    final segments = request.url.pathSegments;
    http.StreamedResponse json(Object? value, {int status = 200}) =>
        http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(jsonEncode(value ?? {}))),
          status,
        );
    if (path == '/heartbeat' || path == '/settings') return json({});
    if (path == '/create') {
      final payload =
          jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      final hash = RegExp(r'btih:([a-z0-9]+)')
          .firstMatch(payload['from'] as String)!
          .group(1)!;
      final count = creates[hash] = (creates[hash] ?? 0) + 1;
      // The first create is the live check, later ones are playback.
      if (count > 1 && failPlayback.contains(hash)) {
        return json({'error': 'rejected'}, status: 500);
      }
      return json({'guessedFileIdx': 0});
    }
    if (segments.length == 2 && segments[1] == 'remove') {
      removed.add(segments[0]);
      return json({});
    }
    if (segments.length == 2 && segments[1] == 'stats.json') {
      return json(null, status: 404);
    }
    if (segments.length == 3 && segments[2] == 'stats.json') {
      final ok = live.contains(segments[0]);
      return json({'peers': ok ? 9 : 0, 'swarmConnections': ok ? 6 : 0});
    }
    if (segments.length == 2) {
      if (!live.contains(segments[0])) {
        return http.StreamedResponse(const Stream<List<int>>.empty(), 206);
      }
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers['Range'] ?? '');
      final length = range == null
          ? 512 * 1024
          : int.parse(range.group(2)!) - int.parse(range.group(1)!) + 1;
      return http.StreamedResponse(
          Stream<List<int>>.value(Uint8List(length)), 206);
    }
    return json(null, status: 404);
  });
}

/// Stand-in for the MPV route: records each launch and plays the scripted
/// outcome for its torrent.
class _Player {
  _Player({this.failStartup = const <String>{}});

  /// Torrents whose player reports a startup failure.
  final Set<String> failStartup;
  final launched = <String>[];
  final offeredFallback = <bool>[];

  Future<void> call(DebugPlayerLaunch launch) async {
    final hash = Uri.parse(launch.url).pathSegments.first;
    launched.add(hash);
    offeredFallback.add(launch.onStartupFallback != null);
    if (failStartup.contains(hash)) {
      // Like PlayerScreen: report, then leave by itself when a fallback was
      // offered (otherwise the user closes the error).
      launch.onStartupFailed?.call('The stream did not start.');
      await launch.onStartupFallback?.call('The stream did not start.');
      return;
    }
    launch.onPlaybackStarted?.call();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FreeP2pPlaybackTrace.instance.clear();
  });
  tearDown(() {
    DetailsScreenState.debugPlayerLauncher = null;
    DetailsScreenState.debugExoLauncher = null;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  /// Lets the flow run. The engine stand-in answers through real event-loop
  /// turns while the app's timeouts run on the test clock, so both advance
  /// together: a little real time, then a short clock step.
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames * 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Widget details({
    bool pikpak = false,
    bool torbox = false,
    required SourceProviderService sources,
    MediaItem item = _movie,
  }) =>
      MaterialApp(
        home: DetailsScreen(
          item: item,
          catalog: _OfflineCatalog(),
          pikpak: _PikPak(signedIn: pikpak),
          transfer: PikPakTransferService(),
          sources: sources,
          torbox: _TorBox(connected: torbox),
          cloudPreferences: CloudPreferencesService(),
          playback: _FakePlayback(),
          mediaState: MediaStateService(),
        ),
      );

  /// Runs [body] with the fake engine as the HTTP client, then lets every
  /// timer of the flow finish.
  Future<void> withEngine(
    WidgetTester tester,
    _Engine engine,
    Future<void> Function() body,
  ) async {
    await http.runWithClient(() async {
      await body();
      await tester.pumpWidget(const SizedBox.shrink());
      await LocalTorrentService.instance.releaseRetainedProbeSessions();
      await LocalTorrentService.instance.releaseCurrentStream();
      await tester.pump(const Duration(seconds: 90));
    }, () => engine.client);
  }

  void mobileSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  void tvSize(WidgetTester tester) {
    PlatformProfile.debugAndroidTvOverride = true;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('Android Mobile one-click Play', () {
    testWidgets('starts the best verified source without the source list',
        (tester) async {
      mobileSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_second, _best])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 60);

        expect(player.launched, hasLength(1));
        expect(find.text('Choose source'), findsNothing,
            reason: 'the source list never opened');
        final attempt = FreeP2pPlaybackTrace.instance.attempts.first;
        expect(attempt.selection, 'oneClick');
        expect(attempt.outcome.name, 'playing');
        expect(FreeP2pPlaybackTrace.instance.runs.single.result, 'started');
        // The MPV exit itself detached the played torrent.
        expect(engine.removed, contains(player.launched.single));
      });
    });

    testWidgets('a 500-seeder torrent that fails the live check never plays',
        (tester) async {
      mobileSize(tester);
      final engine = _Engine(live: {_best.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_hyped, _best])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 60);
        expect(player.launched, [_best.hash]);
      });
    });

    testWidgets(
        'a source that does not start falls back to the next verified '
        'source', (tester) async {
      mobileSize(tester);
      final engine = _Engine(
        live: {_best.hash, _second.hash},
        // The first choice (more reported seeders, otherwise equal) passes
        // the live check but its playback is rejected.
        failPlayback: {_best.hash},
      );
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 80);

        final failed = _best.hash;
        expect(player.launched, [_second.hash],
            reason: 'the rejected torrent never reached a player');
        expect(engine.creates[failed], 2,
            reason: 'one live check and one playback attempt, never retried');
        expect(engine.removed, contains(failed),
            reason: 'the failed attempt left no torrent behind');
        final run = FreeP2pPlaybackTrace.instance.runs.single;
        expect(run.result, 'started');
        expect(run.steps.map((s) => s['step']), contains('fallbackAttempt'));
        expect(
          FreeP2pPlaybackTrace.instance.attempts.map((a) => a.selection),
          ['fallback', 'oneClick'],
        );
        expect(find.text('Choose source'), findsNothing);
      });
    });

    testWidgets('no verified source: honest message and the source list',
        (tester) async {
      mobileSize(tester);
      final engine = _Engine(live: const {});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_hyped, _best])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 60);

        expect(player.launched, isEmpty);
        expect(
          find.text(
              'No source was verified as playable right now. Choose one or re-check.'),
          findsOneWidget,
        );
        expect(find.text('Re-check'), findsOneWidget,
            reason: 'the source list opened with its Re-check action');
        expect(FreeP2pPlaybackTrace.instance.runs.single.result,
            'noVerifiedSource');
      });
    });

    testWidgets('direct HTTP keeps its own route: no torrent engine',
        (tester) async {
      mobileSize(tester);
      final engine = _Engine(live: {_best.hash});
      final launched = <String>[];
      DetailsScreenState.debugPlayerLauncher = (launch) async {
        launched.add(launch.url);
        launch.onPlaybackStarted?.call();
      };
      final provider = MockClient((request) async => http.Response(
            jsonEncode({
              'streams': [
                {
                  'name': 'Direct\n1080p',
                  'title': 'Trigger.2025.1080p.WEB-DL.x264-HTTP',
                  'url': 'https://cdn.example.test/trigger.mkv',
                },
              ],
            }),
            200,
          ));
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(
            details(sources: SourceProviderService(client: provider)));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 40);
        expect(launched, ['https://cdn.example.test/trigger.mkv']);
        expect(engine.totalCreates, 0);
      });
    });
  });

  group('Android TV one-click Play', () {
    testWidgets('Play starts automatic selection; no source browser',
        (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        // OK on the focused Play button.
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 60);

        expect(player.launched, hasLength(1));
        expect(find.byType(TvSourceBrowserScreen), findsNothing);
        expect(FreeP2pPlaybackTrace.instance.runs.single.result, 'started');
      });
    });

    testWidgets(
        'a player startup failure falls back to the next verified '
        'source by itself', (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final player = _Player(failStartup: {_best.hash, _second.hash});
      // Only the first launched torrent fails.
      final launcher = player.call;
      var first = true;
      DetailsScreenState.debugPlayerLauncher = (launch) async {
        if (first) {
          first = false;
          return launcher(launch);
        }
        final hash = Uri.parse(launch.url).pathSegments.first;
        player.launched.add(hash);
        player.offeredFallback.add(launch.onStartupFallback != null);
        launch.onPlaybackStarted?.call();
      };
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 80);

        expect(player.launched, hasLength(2));
        expect(player.launched.toSet(), hasLength(2),
            reason: 'never the same torrent twice');
        expect(player.offeredFallback.first, isTrue,
            reason: 'the player may leave because a verified next exists');
        expect(engine.removed, contains(player.launched.first),
            reason: 'the failed attempt was detached before the next one');
        final attempts = FreeP2pPlaybackTrace.instance.attempts;
        expect(attempts.last.outcome.name, 'playerFailure');
        expect(
          attempts.last.stages.map((s) => '${s['stage']}:${s['result']}'),
          contains('sourceFallback:playerLeft'),
        );
        expect(attempts.first.outcome.name, 'playing');
        expect(find.byType(TvSourceBrowserScreen), findsNothing);
      });
    });

    testWidgets(
        'Sources stays reachable with the D-pad and opens the browser '
        'without playing', (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.arrowRight);
        final focused = FocusManager.instance.primaryFocus?.context;
        final sources = find.byKey(const ValueKey('tv-details-sources'));
        expect(sources, findsOneWidget);
        var onSources = false;
        focused?.visitAncestorElements((element) {
          if (element.widget.key == const ValueKey('tv-details-sources')) {
            onSources = true;
            return false;
          }
          return true;
        });
        expect(onSources, isTrue, reason: 'Right from Play reaches Sources');
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 40);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(player.launched, isEmpty);
      });
    });
  });

  group('Android TV episodes', () {
    Future<void> focusFirstEpisode(WidgetTester tester) async {
      await key(tester, LogicalKeyboardKey.arrowDown); // seasons
      await key(tester, LogicalKeyboardKey.arrowDown); // episodes
      var onEpisode = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        if (e.widget.key == const ValueKey('tv-episode-1-1')) {
          onEpisode = true;
          return false;
        }
        return true;
      });
      expect(onEpisode, isTrue, reason: 'the D-pad reaches the episode');
    }

    testWidgets('OK on an episode plays it with one click', (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          item: _series,
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await focusFirstEpisode(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 60);

        expect(player.launched, [_best.hash]);
        expect(find.byType(TvSourceBrowserScreen), findsNothing);
      });
    });

    testWidgets('holding OK on an episode opens its source browser',
        (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          item: _series,
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        expect(
            find.textContaining('hold OK to choose a source'), findsOneWidget);
        await focusFirstEpisode(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 800));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 30);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(player.launched, isEmpty);
      });
    });
  });

  group('ExoPlayer (chosen in Settings) releases the local P2P torrent', () {
    void exoPreferred() => SharedPreferences.setMockInitialValues(
        <String, Object>{'orvix_player_engine_v1': 'exoPlayer'});

    testWidgets('after a normal exit', (tester) async {
      exoPreferred();
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      final opened = <String>[];
      DetailsScreenState.debugPlayerLauncher =
          (_) async => fail('ExoPlayer was chosen; MPV must not open');
      DetailsScreenState.debugExoLauncher = (url) async {
        opened.add(Uri.parse(url).pathSegments.first);
        return const AndroidExoPlayerResult(started: true);
      };
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 60);

        expect(opened, [_best.hash]);
        expect(engine.removed, contains(_best.hash),
            reason: 'the torrent must not keep downloading after ExoPlayer');
        final attempt = FreeP2pPlaybackTrace.instance.attempts.first;
        expect(attempt.outcome.name, 'playing');
        expect(attempt.stages.any((s) => s['result'] == 'exoPlayer'), isTrue);
      });
    });

    testWidgets('after a startup failure the user leaves', (tester) async {
      exoPreferred();
      tvSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final opened = <String>[];
      DetailsScreenState.debugExoLauncher = (url) async {
        opened.add(Uri.parse(url).pathSegments.first);
        return const AndroidExoPlayerResult(failed: true, error: 'decoder');
      };
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 60);

        expect(opened, hasLength(1),
            reason: 'Back on the ExoPlayer error is the user stopping');
        expect(engine.removed, contains(opened.single));
        expect(FreeP2pPlaybackTrace.instance.attempts.first.outcome.name,
            'playerFailure');
        expect(
            FreeP2pPlaybackTrace.instance.runs.single.result, 'stoppedByUser');
      });
    });

    testWidgets('when the details screen is gone before ExoPlayer closes',
        (tester) async {
      exoPreferred();
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      final closing = Completer<AndroidExoPlayerResult?>();
      var opened = false;
      DetailsScreenState.debugExoLauncher = (url) {
        opened = true;
        return closing.future;
      };
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 60);
        expect(opened, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        closing.complete(const AndroidExoPlayerResult(started: true));
        await settle(tester, frames: 10);

        expect(engine.removed, contains(_best.hash));
      });
    });
  });

  group('cloud/debrid routes stay separate', () {
    Future<void> expectCloud(
      WidgetTester tester, {
      bool pikpak = false,
      bool torbox = false,
      bool tv = false,
    }) async {
      if (tv) {
        tvSize(tester);
      } else {
        mobileSize(tester);
      }
      final engine = _Engine(live: {_best.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          pikpak: pikpak,
          torbox: torbox,
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        if (tv) {
          await key(tester, LogicalKeyboardKey.select);
        } else {
          await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        }
        await settle(tester, frames: 40);

        expect(engine.totalCreates, 0,
            reason: 'no live probe and no local engine on a cloud route');
        expect(player.launched, isEmpty, reason: 'no Free P2P auto-play');
        expect(FreeP2pPlaybackTrace.instance.runs, isEmpty);
        expect(FreeP2pPlaybackTrace.instance.attempts, isEmpty,
            reason: 'cloud playback is never traced as local torrent use');
        if (tv) {
          expect(find.byType(TvSourceBrowserScreen), findsOneWidget,
              reason: 'TV with a cloud account keeps its source browser');
        } else {
          expect(find.text('Choose source'), findsOneWidget,
              reason: 'the existing cloud source list opens');
        }
      });
    }

    testWidgets('TorBox', (tester) => expectCloud(tester, torbox: true));
    testWidgets('Real-Debrid', (tester) {
      FlutterSecureStorage.setMockInitialValues(
          {'orvix_real_debrid_token_v1': 'test-token'});
      return expectCloud(tester);
    });
    testWidgets('Premiumize', (tester) {
      FlutterSecureStorage.setMockInitialValues(
          {'orvix_premiumize_token_v1': 'test-key'});
      return expectCloud(tester);
    });
    testWidgets('PikPak', (tester) => expectCloud(tester, pikpak: true));
    testWidgets('TV with TorBox keeps the source browser',
        (tester) => expectCloud(tester, torbox: true, tv: true));
  });
}
