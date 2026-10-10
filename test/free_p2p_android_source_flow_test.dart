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
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/free_p2p_playback_trace.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/player_engine_preferences_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Android Mobile and Android TV Free P2P source flow: every entry point opens
// the familiar source list at once, nothing probes torrents in the
// background, and a chosen source (checked or not) goes straight to the
// engine and the player, which may need minutes to start.

const _movie = MediaItem(
  id: 'tt0903747',
  kind: MediaKind.movie,
  title: 'Breakout',
  year: '2008',
  runtime: '47m',
);

typedef _Release = ({String tag, String hash, int seeders});

final _first = (tag: 'FIRST', hash: 'a' * 40, seeders: 120);
final _second = (tag: 'SECOND', hash: 'b' * 40, seeders: 40);

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
  @override
  Future<bool> get isSignedIn async => false;

  @override
  Future<List<PikPakFile>> listFiles({String parentId = ''}) async =>
      const <PikPakFile>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TorBox implements TorBoxService {
  @override
  Future<bool> get isConnected async => false;

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
                  'title': 'Breakout.2008.1080p.WEB-DL.x264-${r.tag}\n'
                      'Seeders: ${r.seeders} Size: 1.1 GB',
                  'infoHash': r.hash,
                  'fileIdx': 3,
                },
            ],
          }),
          200,
        ));

/// The local stream engine. It serves no media bytes, so any live check
/// would fail every torrent; manual playback must not care.
class _Engine {
  _Engine({this.hold, this.missedHeartbeats = 0});

  /// When set, create waits for it (magnet metadata still resolving).
  final Completer<void>? hold;

  /// Heartbeats to drop after the first create (a busy engine).
  int missedHeartbeats;

  final creates = <String, int>{};
  final removed = <String>[];
  final streamReads = <String>[];

  int get totalCreates => creates.values.fold(0, (a, b) => a + b);

  late final MockClient client = MockClient.streaming((request, body) async {
    final path = request.url.path;
    final segments = request.url.pathSegments;
    http.StreamedResponse json(Object? value, {int status = 200}) =>
        http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(jsonEncode(value ?? {}))),
          status,
        );
    if (path == '/heartbeat' && creates.isNotEmpty && missedHeartbeats > 0) {
      missedHeartbeats--;
      throw http.ClientException('busy', request.url);
    }
    if (path == '/heartbeat' || path == '/settings') return json({});
    if (path == '/create') {
      final payload =
          jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      final hash = RegExp(r'btih:([a-z0-9]+)')
          .firstMatch(payload['from'] as String)!
          .group(1)!;
      creates[hash] = (creates[hash] ?? 0) + 1;
      if (hold != null) await hold!.future;
      return json({'guessedFileIdx': 3});
    }
    if (segments.length == 2 && segments[1] == 'remove') {
      removed.add(segments[0]);
      return json({});
    }
    if (segments.isNotEmpty && segments.last == 'stats.json') {
      return json({'peers': 2, 'connections': 2}, status: 200);
    }
    if (segments.length == 2) {
      streamReads.add(segments[0]);
      return http.StreamedResponse(const Stream<List<int>>.empty(), 206);
    }
    return json(null, status: 404);
  });
}

/// Stand-in for the MPV route.
class _Player {
  _Player(this.engine, {this.closing, this.startPlayback = true});

  final _Engine engine;
  final Completer<void>? closing;
  final bool startPlayback;
  final launched = <String>[];
  final urls = <String>[];
  final removedBeforeLaunch = <bool>[];
  DebugPlayerLaunch? last;

  Future<void> call(DebugPlayerLaunch launch) async {
    final hash = Uri.parse(launch.url).pathSegments.first;
    launched.add(hash);
    urls.add(launch.url);
    removedBeforeLaunch.add(engine.removed.contains(hash));
    last = launch;
    if (startPlayback) launch.onPlaybackStarted?.call();
    if (closing != null) await closing!.future;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FreeP2pPlaybackTrace.instance.clear();
    LocalTorrentService.instance.patientMetadataPollInterval =
        const Duration(seconds: 5);
  });
  tearDown(() {
    DetailsScreenState.debugPlayerLauncher = null;
    DetailsScreenState.debugExoLauncher = null;
    DetailsScreenState.debugAndroidPlaybackOverride = null;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames * 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Widget details({
    required SourceProviderService sources,
    Key? key,
  }) =>
      MaterialApp(
        home: DetailsScreen(
          key: key,
          item: _movie,
          catalog: _OfflineCatalog(),
          pikpak: _PikPak(),
          transfer: PikPakTransferService(),
          sources: sources,
          torbox: _TorBox(),
          cloudPreferences: CloudPreferencesService(),
          playback: _FakePlayback(),
          mediaState: MediaStateService(),
        ),
      );

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

  void androidMobile(WidgetTester tester) {
    DetailsScreenState.debugAndroidPlaybackOverride = true;
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  void androidTv(WidgetTester tester) {
    PlatformProfile.debugAndroidTvOverride = true;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  void expectNoBlockingLiveCheck() {
    expect(find.textContaining('Checking the healthiest'), findsNothing);
    expect(find.textContaining('Checking live P2P'), findsNothing);
    expect(find.text('CHECKING'), findsNothing);
    expect(find.text('Checking live…'), findsNothing);
    expect(find.text('No live source'), findsNothing);
  }

  void expectFamiliarSourceList() {
    expect(find.text('Choose source'), findsOneWidget);
    // The beta.68 controls are all still there…
    for (final label in const ['Free P2P', 'Compatibility', 'Smooth', 'Sort']) {
      expect(find.text(label), findsOneWidget, reason: '"$label" is kept');
    }
    expect(find.byTooltip('Pin source'), findsWidgets);
    expect(find.textContaining('Quick Play'), findsOneWidget);
    expect(find.textContaining('torrent / P2P'), findsWidgets);
    expect(find.textContaining('seeders reported'), findsWidgets);
    expect(find.textContaining('1.1 GB'), findsWidgets);
    // …and the unwanted redesign is not.
    for (final label in const ['Recommended', 'My Priority', 'Copy report']) {
      expect(find.text(label), findsNothing, reason: '"$label" stays out');
    }
  }

  group('Android Mobile', () {
    testWidgets('opening a title starts no torrent at all', (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.pump(const Duration(seconds: 30));
        await settle(tester, frames: 10);
        expect(engine.totalCreates, 0);
        expect(engine.streamReads, isEmpty);
      });
    });

    for (final entry in const ['Play', 'Find Sources']) {
      testWidgets(
          '$entry opens the familiar source list at once and browsing never '
          'probes a torrent', (tester) async {
        androidMobile(tester);
        final engine = _Engine();
        final player = _Player(engine);
        DetailsScreenState.debugPlayerLauncher = player.call;
        await withEngine(tester, engine, () async {
          await tester.pumpWidget(details(
            sources:
                SourceProviderService(client: _provider([_first, _second])),
          ));
          await settle(tester);
          await tester.tap(find.text(entry).first);
          await settle(tester, frames: 20);

          expectFamiliarSourceList();
          expectNoBlockingLiveCheck();
          // Browse for a while: still no engine traffic and no auto-play.
          await tester.pump(const Duration(seconds: 30));
          await settle(tester, frames: 20);
          expect(engine.totalCreates, 0, reason: 'no live probe');
          expect(engine.streamReads, isEmpty);
          expect(player.launched, isEmpty);
          expectNoBlockingLiveCheck();
        });
      });
    }

    testWidgets(
        'Quick Play starts the unverified top source with no live-check gate',
        (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        final quickPlay = find.ancestor(
          of: find.textContaining('Quick Play'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(tester.widget<ButtonStyleButton>(quickPlay).onPressed,
            isNotNull,
            reason: 'unverified does not mean unplayable');
        await tester.tap(quickPlay);
        await settle(tester, frames: 40);
        expect(player.launched, [_first.hash]);
        expect(engine.creates, {_first.hash: 1});
      });
    });

    testWidgets(
        'a chosen source keeps its identity and file index and stays attached '
        'while the player needs it', (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final closing = Completer<void>();
      final player = _Player(engine, closing: closing);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-SECOND').first);
        await settle(tester, frames: 30);

        expect(player.launched, [_second.hash]);
        expect(Uri.parse(player.urls.single).pathSegments, [_second.hash, '3'],
            reason: 'the provider fileIdx routes the exact file');
        expect(engine.creates, {_second.hash: 1},
            reason: 'one playback create, no probe of any other torrent');
        expect(player.removedBeforeLaunch, [false]);

        // Well past every cleanup and handoff timer.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(seconds: 40));
          await settle(tester, frames: 5);
        }
        expect(engine.removed, isNot(contains(_second.hash)));
        expect(engine.creates, {_second.hash: 1});
        expect(engine.creates.containsKey(_first.hash), isFalse,
            reason: 'nothing else competes with the chosen torrent');

        closing.complete();
        await settle(tester, frames: 20);
        expect(engine.removed, contains(_second.hash),
            reason: 'the torrent is released when the player exits');
        expect(find.text('Choose source'), findsOneWidget);
      });
    });

    testWidgets(
        'slow magnet metadata keeps waiting past three minutes, then plays '
        'with no failure recorded', (tester) async {
      androidMobile(tester);
      final hold = Completer<void>();
      final engine = _Engine(hold: hold);
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      final sources = SourceProviderService(client: _provider([_first]));
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(sources: sources));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 10);

        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(seconds: 5));
          await settle(tester, frames: 1);
        }
        expect(player.launched, isEmpty, reason: 'still resolving');
        expect(find.textContaining('Finding peers for this torrent'),
            findsOneWidget);
        expect(engine.removed, isNot(contains(_first.hash)));
        expect(find.byType(SnackBar), findsNothing,
            reason: 'no startup failure for a slow swarm');

        hold.complete();
        await settle(tester, frames: 40);
        expect(player.launched, [_first.hash]);
        expect(engine.creates, {_first.hash: 1}, reason: 'same request');
        final results = await sources.resolve(_movie, includeLowQuality: true);
        expect(sources.playbackHistoryRank(results.first), 2,
            reason: 'it played; no failure penalty');
      });
    });

    testWidgets('Back while the torrent is preparing cancels and detaches it',
        (tester) async {
      androidMobile(tester);
      final hold = Completer<void>();
      final engine = _Engine(hold: hold);
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 10);
        expect(engine.creates, {_first.hash: 1});

        await tester.binding.handlePopRoute();
        await settle(tester, frames: 10);
        expect(find.text('Choose source'), findsOneWidget,
            reason: 'Back returns to the same list at once');
        await tester.pump(const Duration(seconds: 6));
        await settle(tester, frames: 10);
        hold.complete();
        await settle(tester, frames: 30);

        expect(player.launched, isEmpty);
        expect(engine.removed, contains(_first.hash));
        expect(FreeP2pPlaybackTrace.instance.attempts.first.outcome.name,
            'cancelled');
      });
    });

    testWidgets(
        'Continue Watching opens the list immediately, even with a pinned '
        'source, and never runs a blocking live check', (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      final screen = GlobalKey<DetailsScreenState>();
      final sources = SourceProviderService(client: _provider([_first, _second]));
      final results = await sources.resolve(_movie, includeLowQuality: true);
      final second = results.firstWhere((r) => r.resource.contains(_second.hash));
      await sources.pinSource(
        sources.sourceTargetKey(_movie),
        second,
        seriesWide: false,
      );
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(key: screen, sources: sources));
        await settle(tester);
        unawaited(screen.currentState!.resumeContinueWatching(_movie, null));
        await settle(tester, frames: 30);

        expect(find.text('Choose source'), findsOneWidget);
        expectNoBlockingLiveCheck();
        expect(player.launched, isEmpty, reason: 'nothing auto-plays');
        expect(engine.totalCreates, 0);
        // The pin is listed first and is one tap away.
        expect(find.text('Play pinned'), findsOneWidget);
        await tester.tap(find.text('Play pinned'));
        await settle(tester, frames: 40);
        expect(player.launched, [_second.hash]);
      });
    });

    testWidgets('closing ExoPlayer releases its local torrent',
        (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final exoUrls = <String>[];
      DetailsScreenState.debugExoLauncher = (url) async {
        exoUrls.add(url);
        return const AndroidExoPlayerResult(started: true);
      };
      DetailsScreenState.debugPlayerLauncher = (_) async {
        fail('ExoPlayer was chosen; MPV must not open');
      };
      await PlayerEnginePreferencesService.set(
        PlayerEnginePreference.exoPlayer,
      );
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 40);

        expect(exoUrls, hasLength(1));
        expect(engine.removed, contains(_first.hash),
            reason: 'no torrent keeps downloading after the player closed');
      });
    });
  });

  group('Android TV', () {
    testWidgets(
        'Play opens the source browser at once; nothing is probed until '
        'Re-check live is pressed', (tester) async {
      androidTv(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 30);
        await tester.pump(const Duration(seconds: 30));
        await settle(tester, frames: 20);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(engine.totalCreates, 0);
        expect(engine.streamReads, isEmpty);
        expect(player.launched, isEmpty);
        expectNoBlockingLiveCheck();
        // Familiar TV controls are kept.
        for (final label in const [
          'Free P2P',
          'Smooth',
          'Default',
          'Order',
          'Compatible only',
          'Re-check live',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
      });
    });

    testWidgets('OK on a row plays that torrent directly', (tester) async {
      androidTv(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 30);
        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 40);

        expect(player.launched, hasLength(1));
        expect(engine.totalCreates, 1);
        expect(player.removedBeforeLaunch, [false]);
      });
    });

    testWidgets('Continue Watching opens the browser instead of auto-playing',
        (tester) async {
      androidTv(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      final screen = GlobalKey<DetailsScreenState>();
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          key: screen,
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        unawaited(screen.currentState!.resumeContinueWatching(_movie, null));
        await settle(tester, frames: 40);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(player.launched, isEmpty);
        expect(engine.totalCreates, 0);
        expectNoBlockingLiveCheck();
      });
    });
  });

  group('review follow-ups', () {
    testWidgets('one missed engine heartbeat does not end a slow resolve',
        (tester) async {
      androidMobile(tester);
      final hold = Completer<void>();
      final engine = _Engine(hold: hold, missedHeartbeats: 1);
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 10);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 5));
          await settle(tester, frames: 1);
        }
        expect(engine.missedHeartbeats, 0, reason: 'a heartbeat was missed');
        expect(find.byType(SnackBar), findsNothing);
        hold.complete();
        await settle(tester, frames: 40);
        expect(player.launched, [_first.hash]);
      });
    });

    testWidgets('a second OK on TV never opens a second player',
        (tester) async {
      androidTv(tester);
      final engine = _Engine();
      final closing = Completer<void>();
      final player = _Player(engine, closing: closing);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 30);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester, frames: 40);
        expect(player.launched, hasLength(1));
        expect(engine.totalCreates, 1);
        closing.complete();
        await settle(tester, frames: 20);
      });
    });
  });

  group('probe contention', () {
    SourceResult torrent(int i) => SourceResult(
          provider: 'Torrentio',
          title: 'Release $i',
          resource: 'magnet:?xt=urn:btih:${'$i'.padLeft(40, 'c')}',
          isMagnet: true,
          sortMode: SourceSortMode.seeders,
          seeders: 100 - i,
          sizeBytes: 1024 * 1024 * 1024,
          torrentFileIndex: 0,
        );

    test(
        'once a source is handed to playback a background check starts no '
        'further probe', () async {
      final started = <String>[];
      final pending = <Completer<LocalTorrentProbeResult>>[];
      final session = FreeP2pLiveProbeService(probeRunner: (source) {
        started.add(source.title);
        final completer = Completer<LocalTorrentProbeResult>();
        pending.add(completer);
        return completer.future;
      });
      final results = [for (var i = 0; i < 9; i++) torrent(i)];
      final run = session.probeTopCandidates(results, SourceProviderService());
      await Future<void>.delayed(Duration.zero);
      expect(started, hasLength(FreeP2pLiveProbeService.probeConcurrency));

      await session.prepareForPlayback(results[7]);
      for (final completer in pending) {
        completer.complete(const LocalTorrentProbeResult(
          playableNow: false,
          bytesReceived: 0,
          elapsed: Duration(seconds: 5),
          firstByteLatency: null,
          peers: 0,
          connections: 0,
          downloadSpeedBytesPerSecond: 0,
          sampleWindowsPassed: 0,
          outcome: LocalTorrentProbeStatus.stalled,
        ));
      }
      await run;
      expect(started, hasLength(FreeP2pLiveProbeService.probeConcurrency),
          reason: 'no new torrent session competes with the chosen stream');

      // The player closed; a Re-check may probe again.
      session.resumeAfterPlayback();
      expect(session.acceptsNewProbes, isTrue);
    });
  });

  group('failure history', () {
    test('only answers about the torrent itself count against it', () {
      expect(
        DetailsScreenState.isSourceSpecificTorrentFailure(
          const LocalTorrentException('Local torrent engine returned HTTP 500.'),
        ),
        isTrue,
      );
      expect(
        DetailsScreenState.isSourceSpecificTorrentFailure(
          const LocalTorrentException('Local torrent engine: invalid torrent'),
        ),
        isTrue,
      );
      expect(
        DetailsScreenState.isSourceSpecificTorrentFailure(
          const LocalTorrentException(
            'Could not send the torrent to the local streaming engine: x',
          ),
        ),
        isFalse,
        reason: 'an engine/transport problem is not the release',
      );
      expect(
        DetailsScreenState.isSourceSpecificTorrentFailure(
          const LocalTorrentException(
            'The local torrent engine timed out while resolving magnet '
            'metadata: no peers were found for this torrent.',
          ),
        ),
        isFalse,
        reason: 'a slow swarm is not a failure',
      );
      expect(
        DetailsScreenState.isSourceSpecificTorrentFailure(
          const LocalTorrentCancelled(),
        ),
        isFalse,
      );
    });
  });
}
