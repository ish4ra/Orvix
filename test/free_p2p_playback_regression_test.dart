import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/screens/tv_source_browser_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/free_p2p_auto_play.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
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

// Regression coverage for the beta.65 Free P2P playback report: automatic
// selection, the player startup path, Android TV source browsing and the
// failure notice.

const _movie = MediaItem(
  id: 'tt0499549',
  kind: MediaKind.movie,
  title: 'Trigger',
  year: '2025',
  runtime: '1h 50m',
);

typedef _Release = ({String tag, String hash, int seeders});

final _best = (tag: 'BEST', hash: 'b' * 40, seeders: 40);
final _second = (tag: 'SECOND', hash: 'c' * 40, seeders: 30);
final _third = (tag: 'THIRD', hash: 'd' * 40, seeders: 20);
final _fourth = (tag: 'FOURTH', hash: 'e' * 40, seeders: 10);

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
                  'title': 'Trigger.2025.1080p.WEB-DL.x264-${r.tag}\n'
                      'Seeders: ${r.seeders} Size: 2.1 GB',
                  'infoHash': r.hash,
                  'fileIdx': 0,
                },
            ],
          }),
          200,
        ));

/// The local stream engine. [live] torrents serve media bytes. With
/// [holdLiveCheck] the first create of every torrent (its live check) does
/// not answer until the test releases it, so the check stays in progress.
/// [rejectPlayback] torrents pass the live check but every playback create
/// is rejected; [rejectPlaybackOnce] rejects only the first one.
class _Engine {
  _Engine({
    required this.live,
    this.holdLiveCheck = false,
    this.rejectPlayback = const <String>{},
    this.rejectPlaybackOnce = const <String>{},
  });

  final Set<String> live;
  final bool holdLiveCheck;
  final Set<String> rejectPlayback;
  final Set<String> rejectPlaybackOnce;
  final creates = <String, int>{};
  final removed = <String>[];
  final _held = <Completer<void>>[];

  int get totalCreates => creates.values.fold(0, (a, b) => a + b);

  void releaseHeld() {
    for (final hold in _held) {
      if (!hold.isCompleted) hold.complete();
    }
  }

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
      if (count == 1 && holdLiveCheck) {
        final hold = Completer<void>();
        _held.add(hold);
        await hold.future;
      }
      if (count > 1 &&
          (rejectPlayback.contains(hash) ||
              (count == 2 && rejectPlaybackOnce.contains(hash)))) {
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

/// Stand-in for the MPV route. [slowStart] torrents behave like a real swarm
/// that needs longer than the player's 30 s startup watchdog: the player
/// reports "taking longer than expected", and media starts afterwards
/// unless the player was told to leave for another source.
class _Player {
  _Player({this.slowStart = const <String>{}});

  final Set<String> slowStart;
  final launched = <String>[];
  final offeredFallback = <bool>[];
  final leftEarly = <String>[];

  Future<void> call(DebugPlayerLaunch launch) async {
    final hash = Uri.parse(launch.url).pathSegments.first;
    launched.add(hash);
    offeredFallback.add(launch.onStartupFallback != null);
    if (slowStart.contains(hash)) {
      launch.onStartupFailed?.call(
        'The stream is taking longer than expected to start. '
        'Orvix will recover automatically if media begins playing.',
      );
      final fallback = launch.onStartupFallback;
      if (fallback != null) {
        // PlayerScreen leaves by itself and stops the stream.
        leftEarly.add(hash);
        await fallback('taking longer than expected');
        return;
      }
    }
    launch.onPlaybackStarted?.call();
  }
}

/// Deterministic probe engine for the automatic-choice unit tests.
class _ProbeEngine implements FreeP2pProbeEngine {
  _ProbeEngine(this.outcomes);

  final Map<String, LocalTorrentProbeResult> outcomes;

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) async =>
      outcomes[source.title] ??
      const LocalTorrentProbeResult(
        playableNow: false,
        bytesReceived: 0,
        elapsed: Duration.zero,
        firstByteLatency: null,
        peers: 0,
        connections: 0,
        downloadSpeedBytesPerSecond: 0,
        sampleWindowsPassed: 0,
      );

  @override
  Future<void> releaseRetained(SourceResult source) async {}

  @override
  Future<void> prepareForPlayback(SourceResult source) async {}

  @override
  Future<void> releaseAll() async {}
}

const _mb = 1024 * 1024;

LocalTorrentProbeResult _readyNow({
  required Duration firstByte,
  required int peers,
}) =>
    LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: _mb,
      elapsed: const Duration(seconds: 1),
      firstByteLatency: firstByte,
      peers: peers,
      connections: peers,
      downloadSpeedBytesPerSecond: 2.5 * _mb,
      sampleWindowsPassed: 2,
      metadataElapsed: const Duration(milliseconds: 900),
    );

SourceResult _episodeTorrent(
  String title, {
  required String hashChar,
  required String quality,
  required String releaseQuality,
  required int sizeBytes,
  required int seeders,
}) =>
    SourceResult(
      provider: 'Torrentio',
      title: title,
      resource: 'magnet:?xt=urn:btih:${hashChar * 40}',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
      quality: quality,
      releaseQuality: releaseQuality,
      sizeBytes: sizeBytes,
      seeders: seeders,
      torrentFileIndex: 3,
    );

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
      engine.releaseHeld();
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

  group('automatic choice follows measured live evidence', () {
    // A series episode: no runtime, so the bitrate need cannot separate the
    // two files and both read READY NOW.
    final heavy = _episodeTorrent(
      'Show.S01E01.2160p.BluRay.REMUX.DV.HEVC.AV1-HEAVY',
      hashChar: 'h',
      quality: '2160P',
      releaseQuality: 'REMUX',
      sizeBytes: 18 * 1024 * _mb,
      seeders: 40,
    );
    final light = _episodeTorrent(
      'Show.S01E01.1080p.WEB-DL.x264-LIGHT',
      hashChar: 'l',
      quality: '1080P',
      releaseQuality: 'WEB-DL',
      sizeBytes: 1200 * _mb,
      seeders: 40,
    );
    Map<String, LocalTorrentProbeResult> outcomes() => {
          heavy.title: _readyNow(
            firstByte: const Duration(milliseconds: 1500),
            peers: 4,
          ),
          light.title: _readyNow(
            firstByte: const Duration(milliseconds: 300),
            peers: 12,
          ),
        };

    test(
        'Normal Play picks the faster, compatible file, not the largest '
        'release', () async {
      final sources = SourceProviderService();
      final probe = FreeP2pLiveProbeService(engine: _ProbeEngine(outcomes()));
      expect(
        await probe.probeBestCandidate([heavy, light], sources),
        same(light),
      );
    });

    test('Quick Play makes the same measured choice', () async {
      final sources = SourceProviderService();
      final probe = FreeP2pLiveProbeService(engine: _ProbeEngine(outcomes()));
      await probe.probeTopCandidates([heavy, light], sources);
      expect(probe.quickPlayCandidate([heavy, light], sources), same(light));
    });

    test('the My Priority display order still follows the user', () async {
      final sources = SourceProviderService();
      final probe = FreeP2pLiveProbeService(engine: _ProbeEngine(outcomes()))
        ..setDisplayMode(SourceDisplayMode.myPriority);
      await probe.probeTopCandidates([heavy, light], sources);
      expect(probe.rank([heavy, light], sources).first, same(heavy),
          reason: 'display order is the user\'s choice; playback is not');
    });
  });

  group('reopening a title reuses fresh live evidence', () {
    final light = _episodeTorrent(
      'Show.S01E01.1080p.WEB-DL.x264-LIGHT',
      hashChar: 'l',
      quality: '1080P',
      releaseQuality: 'WEB-DL',
      sizeBytes: 1200 * _mb,
      seeders: 40,
    );
    final other = _episodeTorrent(
      'Show.S01E01.720p.WEB-DL.x264-OTHER',
      hashChar: 'o',
      quality: '720P',
      releaseQuality: 'WEB-DL',
      sizeBytes: 700 * _mb,
      seeders: 20,
    );

    test('a second check of the same rows probes nothing again', () async {
      final sources = SourceProviderService();
      final evidence = FreeP2pLiveEvidence();
      final probed = <String>[];
      final results = [light, other];
      FreeP2pLiveProbeService session() => FreeP2pLiveProbeService(
            evidence: evidence,
            probeRunner: (source) async {
              probed.add(source.title);
              return _readyNow(
                firstByte: const Duration(milliseconds: 300),
                peers: 12,
              );
            },
          );

      await session().probeTopCandidates(results, sources);
      expect(probed, hasLength(2));

      final again = session();
      await again.probeTopCandidates(results, sources);
      expect(probed, hasLength(2), reason: 'evidence is still fresh');
      expect(again.healthFor(light)?.isLive, isTrue);
      expect(await session().probeBestCandidate(results, sources),
          same(light));
      expect(probed, hasLength(2),
          reason: 'Normal Play reuses a fresh READY NOW result');
    });

    test('Re-check still starts from scratch', () async {
      final sources = SourceProviderService();
      final evidence = FreeP2pLiveEvidence();
      var probes = 0;
      FreeP2pLiveProbeService session() => FreeP2pLiveProbeService(
            evidence: evidence,
            probeRunner: (source) async {
              probes++;
              return _readyNow(
                firstByte: const Duration(milliseconds: 300),
                peers: 12,
              );
            },
          );
      await session().probeTopCandidates([light, other], sources);
      await session().recheck([light, other], sources);
      expect(probes, 4);
    });
  });

  group('Android Mobile playback', () {
    testWidgets('opening a title starts no torrent check', (tester) async {
      mobileSize(tester);
      final engine = _Engine(live: {_best.hash});
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester, frames: 60);
        expect(engine.totalCreates, 0);
      });
    });

    testWidgets(
        'Sources lists rows at once and plays an unchecked row while the '
        'live check is still running', (tester) async {
      mobileSize(tester);
      final engine = _Engine(
        live: {_best.hash, _second.hash},
        holdLiveCheck: true,
      );
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Find Sources'));
        await settle(tester, frames: 20);

        expect(find.text('Choose source'), findsOneWidget);
        expect(find.textContaining('x264-SECOND'), findsWidgets);
        expect(find.textContaining('Checking live P2P sources'), findsNothing);

        await tester.tap(find.textContaining('x264-SECOND').first);
        await settle(tester, frames: 40);
        expect(player.launched, [_second.hash],
            reason: 'a manual choice never waits for the live check');
      });
    });

    testWidgets('a failed automatic attempt still allows a manual retry',
        (tester) async {
      mobileSize(tester);
      final engine = _Engine(
        live: {_best.hash},
        rejectPlaybackOnce: {_best.hash},
      );
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 80);

        expect(player.launched, isEmpty);
        expect(find.text('Choose source'), findsOneWidget);
        // Each provider lists the torrent; any of its rows is the same choice.
        await tester.tap(find.textContaining('x264-BEST').first);
        await settle(tester, frames: 40);
        expect(player.launched, [_best.hash],
            reason: 'START FAILED is no ban on a manual choice');
      });
    });

    testWidgets('automatic fallback stops after its attempt limit',
        (tester) async {
      mobileSize(tester);
      final all = [_best, _second, _third, _fourth];
      final engine = _Engine(
        live: {for (final r in all) r.hash},
        rejectPlayback: {for (final r in all) r.hash},
      );
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider(all)),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 120);

        final attempts = FreeP2pPlaybackTrace.instance.attempts;
        expect(attempts, hasLength(FreeP2pAutoPlay.defaultMaxAttempts));
        expect(engine.creates.values, everyElement(lessThanOrEqualTo(2)),
            reason: 'one live check and at most one attempt per torrent');
        expect(engine.creates.values.where((count) => count == 2),
            hasLength(FreeP2pAutoPlay.defaultMaxAttempts));
        expect(player.launched, isEmpty);
        expect(find.text('Choose source'), findsOneWidget);
      });
    });

    testWidgets(
        'the failure notice can be closed and goes away by itself, even with '
        'its Copy report action', (tester) async {
      mobileSize(tester);
      final engine = _Engine(
        live: {_best.hash},
        rejectPlayback: {_best.hash},
      );
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 60);

        final notice = find.byType(SnackBar);
        expect(notice, findsOneWidget);
        final snackBar = tester.widget<SnackBar>(notice);
        expect(snackBar.action?.label, 'Copy report');

        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 4)));
          await tester.pump(const Duration(seconds: 1));
        }
        expect(find.byType(SnackBar), findsNothing,
            reason: 'a notice with an action must still go away by itself');
        expect(snackBar.showCloseIcon, isTrue);
        expect(snackBar.duration, lessThanOrEqualTo(const Duration(seconds: 8)));
      });
    });
  });

  group('Android TV playback', () {
    testWidgets(
        'Play opens the source browser at once; a row plays with no live '
        'check', (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final player = _Player();
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 20);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(find.textContaining('Checking live P2P sources'), findsNothing);
        expect(player.launched, isEmpty, reason: 'nothing auto-plays');
        expect(engine.totalCreates, 0, reason: 'browsing probes nothing');

        // OK on the focused first row.
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 40);
        expect(player.launched, hasLength(1));
        expect(engine.totalCreates, 1, reason: 'only the chosen torrent');
      });
    });

    // A manual choice on Android. The Android TV override is the only way to
    // select Android playback on a test host; Android Mobile shares this
    // player path.
    testWidgets(
        'a chosen source that starts slowly keeps its player and plays',
        (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash, _second.hash});
      final player = _Player(slowStart: {_best.hash, _second.hash});
      DetailsScreenState.debugPlayerLauncher = player.call;
      final screen = GlobalKey<DetailsScreenState>();
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          key: screen,
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester);
        unawaited(screen.currentState!.resumeContinueWatching(_movie, null));
        await settle(tester, frames: 40);
        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        // OK on the focused first row.
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 80);

        expect(player.leftEarly, isEmpty,
            reason: 'the player is never told to abandon a slow start');
        expect(player.offeredFallback, everyElement(isFalse));
        expect(player.launched, hasLength(1));
        expect(FreeP2pPlaybackTrace.instance.attempts.first.outcome.name,
            'playing');
      });
    });

    testWidgets('opening a title starts no torrent check', (tester) async {
      tvSize(tester);
      final engine = _Engine(live: {_best.hash});
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_best, _second])),
        ));
        await settle(tester, frames: 60);
        expect(engine.totalCreates, 0);
      });
    });
  });
}
