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
import 'package:orvix/screens/player_screen.dart';
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

// Recovery of manual Free P2P playback on Android Mobile and Android TV:
// browsing sources never runs a live torrent probe, Play opens the source
// list, and a chosen torrent goes straight to the engine and the player.

const _movie = MediaItem(
  id: 'tt0455275',
  kind: MediaKind.movie,
  title: 'Breakout',
  year: '2005',
  runtime: '44m',
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
                  'title': 'Breakout.S01E01.1080p.WEB-DL.x264-${r.tag}\n'
                      'Seeders: ${r.seeders} Size: 1.1 GB',
                  'infoHash': r.hash,
                  'fileIdx': 0,
                },
            ],
          }),
          200,
        ));

/// The local stream engine. It serves no media bytes at all, so every
/// torrent would fail a live check; manual playback must not care.
class _Engine {
  _Engine({this.rejected = const <String>{}, this.hold});

  /// Torrents the engine rejects on create.
  final Set<String> rejected;

  /// When set, create waits for it (metadata still resolving).
  final Completer<void>? hold;

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
    if (path == '/heartbeat' || path == '/settings') return json({});
    if (path == '/create') {
      final payload =
          jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      final hash = RegExp(r'btih:([a-z0-9]+)')
          .firstMatch(payload['from'] as String)!
          .group(1)!;
      creates[hash] = (creates[hash] ?? 0) + 1;
      if (hold != null) await hold!.future;
      if (rejected.contains(hash)) {
        return json({'error': 'rejected'}, status: 200);
      }
      return json({'guessedFileIdx': 0});
    }
    if (segments.length == 2 && segments[1] == 'remove') {
      removed.add(segments[0]);
      return json({});
    }
    if (segments.isNotEmpty && segments.last == 'stats.json') {
      return json(null, status: 404);
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
  _Player(this.engine, {this.closing});

  final _Engine engine;

  /// When set, the player stays open (playing) until it completes.
  final Completer<void>? closing;
  final launched = <String>[];

  /// Whether the engine had already detached the torrent when the player
  /// opened it.
  final removedBeforeLaunch = <bool>[];

  Future<void> call(DebugPlayerLaunch launch) async {
    final hash = Uri.parse(launch.url).pathSegments.first;
    launched.add(hash);
    removedBeforeLaunch.add(engine.removed.contains(hash));
    launch.onPlaybackStarted?.call();
    if (closing != null) await closing!.future;
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
    bool torbox = false,
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
          torbox: _TorBox(connected: torbox),
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

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 50));
  }

  void expectNoLiveCheckUi() {
    for (final text in const [
      'Recommended',
      'My Priority',
      'Smooth',
      'Re-check',
      'Re-check live',
      'Live report',
      'NOT CHECKED',
      'CHECKING',
    ]) {
      expect(find.text(text), findsNothing, reason: '"$text" is gone');
    }
    expect(find.textContaining('Checking the healthiest'), findsNothing);
    expect(find.textContaining('Checking live P2P'), findsNothing);
    expect(find.textContaining('live check'), findsNothing);
    expect(find.textContaining('No source was verified'), findsNothing);
  }

  group('Android Mobile Free P2P', () {
    testWidgets(
        'Play opens the source list at once and browsing never probes '
        'a torrent', (tester) async {
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

        expect(find.text('Choose source'), findsOneWidget);
        // Browse for a while: still no engine traffic at all.
        await tester.pump(const Duration(seconds: 20));
        await settle(tester, frames: 20);
        expect(engine.totalCreates, 0, reason: 'no live probe');
        expect(engine.streamReads, isEmpty);
        expect(player.launched, isEmpty, reason: 'nothing auto-plays');
        expectNoLiveCheckUi();
        expect(FreeP2pPlaybackTrace.instance.runs, isEmpty,
            reason: 'the automatic one-click run is off');
        // Useful provider metadata stays.
        expect(find.textContaining('x264-FIRST'), findsWidgets);
        expect(find.textContaining('120 seeders'), findsWidgets);
      });
    });

    testWidgets(
        'a chosen torrent goes straight to the engine and the player, '
        'with no live-check approval', (tester) async {
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
        await tester.tap(find.textContaining('x264-SECOND').first);
        await settle(tester, frames: 40);

        expect(player.launched, [_second.hash]);
        expect(engine.creates, {_second.hash: 1},
            reason: 'one playback create, no probe of any other torrent');
        expect(player.removedBeforeLaunch, [false]);
        final attempt = FreeP2pPlaybackTrace.instance.attempts.first;
        expect(attempt.selection, 'manual');
        expect(attempt.outcome.name, 'playing');
        // The player closed: the torrent is released, the list comes back.
        expect(engine.removed, contains(_second.hash));
        expect(find.text('Choose source'), findsOneWidget);
      });
    });

    testWidgets('the playing torrent is never detached while the player is open',
        (tester) async {
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
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 30);
        expect(player.launched, [_first.hash]);

        // Well past every cleanup and handoff timer.
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(seconds: 40));
          await settle(tester, frames: 5);
        }
        expect(engine.removed, isNot(contains(_first.hash)));
        expect(engine.creates, {_first.hash: 1});

        closing.complete();
        await settle(tester, frames: 20);
        expect(engine.removed, contains(_first.hash));
      });
    });

    testWidgets('a pinned source stays first and only plays when chosen',
        (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      final sources = SourceProviderService(client: _provider([_first, _second]));
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(sources: sources));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        // Pin the second release.
        final secondRow = find
            .ancestor(
              of: find.textContaining('x264-SECOND').first,
              matching: find.byType(ListTile),
            )
            .first;
        await tester.tap(find.descendant(
          of: secondRow,
          matching: find.byTooltip('Pin source'),
        ));
        await settle(tester, frames: 10);
        // Close the list and press Play again.
        await tester.tapAt(const Offset(10, 10));
        await settle(tester, frames: 20);
        expect(find.text('Choose source'), findsNothing);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);

        expect(player.launched, isEmpty,
            reason: 'Normal Play opens the list, even with a pin');
        expect(engine.totalCreates, 0);
        final firstTitle =
            tester.getTopLeft(find.textContaining('x264-SECOND').first);
        final secondTitle =
            tester.getTopLeft(find.textContaining('x264-FIRST').first);
        expect(firstTitle.dy, lessThan(secondTitle.dy),
            reason: 'the pinned release is listed first');

        await tester.tap(find.text('Play pinned'));
        await settle(tester, frames: 40);
        expect(player.launched, [_second.hash]);
        expect(engine.creates, {_second.hash: 1});
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
        hold.complete();
        await settle(tester, frames: 30);

        expect(player.launched, isEmpty);
        expect(engine.removed, contains(_first.hash));
        expect(FreeP2pPlaybackTrace.instance.attempts.first.outcome.name,
            'cancelled');
      });
    });

    testWidgets(
        'a rejected torrent shows one short dismissible notice and the list '
        'comes back', (tester) async {
      androidMobile(tester);
      final engine = _Engine(rejected: {_first.hash});
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 20);
        await tester.tap(find.textContaining('x264-FIRST').first);
        await settle(tester, frames: 40);

        expect(player.launched, isEmpty);
        expect(engine.removed, contains(_first.hash));
        final snackBars = tester.widgetList<SnackBar>(find.byType(SnackBar));
        expect(snackBars, hasLength(1));
        expect(snackBars.single.showCloseIcon, isTrue);
        expect(find.text('Choose source'), findsOneWidget,
            reason: 'the user can pick another source at once');
        // It closes by itself.
        await tester.pump(const Duration(seconds: 7));
        await settle(tester, frames: 20);
        expect(find.byType(SnackBar), findsNothing);
      });
    });
  });

  group('Android TV Free P2P', () {
    testWidgets('the source browser opens with plain rows and never probes',
        (tester) async {
      androidTv(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          sources: SourceProviderService(client: _provider([_first, _second])),
        ));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 30);
        await tester.pump(const Duration(seconds: 20));
        await settle(tester, frames: 20);

        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        expect(engine.totalCreates, 0);
        expect(engine.streamReads, isEmpty);
        expect(player.launched, isEmpty);
        expectNoLiveCheckUi();
        expect(find.textContaining('120 seeders'), findsWidgets);
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
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 30);
        expect(find.byType(TvSourceBrowserScreen), findsOneWidget);
        // The first row has focus.
        await key(tester, LogicalKeyboardKey.select);
        await settle(tester, frames: 40);

        expect(player.launched, hasLength(1));
        expect(engine.totalCreates, 1);
        expect(player.removedBeforeLaunch, [false]);
        expect(FreeP2pPlaybackTrace.instance.attempts.first.selection,
            'manual');
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
        expect(FreeP2pPlaybackTrace.instance.runs, isEmpty);
      });
    });
  });

  group('cloud/debrid stays unchanged', () {
    testWidgets('the cloud source list keeps its display modes',
        (tester) async {
      androidMobile(tester);
      final engine = _Engine();
      final player = _Player(engine);
      DetailsScreenState.debugPlayerLauncher = player.call;
      await withEngine(tester, engine, () async {
        await tester.pumpWidget(details(
          torbox: true,
          sources: SourceProviderService(client: _provider([_first])),
        ));
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await settle(tester, frames: 30);

        expect(find.text('Choose source'), findsOneWidget);
        expect(find.text('Recommended'), findsOneWidget);
        expect(find.text('My Priority'), findsOneWidget);
        expect(engine.totalCreates, 0);
      });
    });
  });

  group('player slow start', () {
    final p2p = 'http://127.0.0.1:11470/${'a' * 40}/0';

    test('an Android local P2P stream keeps waiting instead of failing', () {
      expect(
        PlayerScreen.slowStartKeepsWaiting(isAndroid: true, url: p2p),
        isTrue,
      );
    });

    test('other streams and platforms keep the existing startup watchdog', () {
      expect(
        PlayerScreen.slowStartKeepsWaiting(isAndroid: false, url: p2p),
        isFalse,
        reason: 'Windows and macOS are unchanged',
      );
      expect(
        PlayerScreen.slowStartKeepsWaiting(
          isAndroid: true,
          url: 'https://cdn.example.test/movie.mkv',
        ),
        isFalse,
        reason: 'cloud/debrid streams are unchanged',
      );
      expect(
        PlayerScreen.slowStartKeepsWaiting(
          isAndroid: true,
          url: 'http://127.0.0.1:11470/not-a-hash/0',
        ),
        isFalse,
      );
    });
  });
}
