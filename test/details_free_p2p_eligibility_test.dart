import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _movie = MediaItem(
  id: 'tt0499549',
  kind: MediaKind.movie,
  title: 'Trigger',
  year: '2025',
);

final _infoHash = 'c' * 40;
const _release = 'Trigger.2025.1080p.WEB-DL.x264-GROUP';

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
  _PikPak({required this.signedIn});

  final bool signedIn;

  @override
  Future<bool> get isSignedIn async => signedIn;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TorBox implements TorBoxService {
  _TorBox({required this.connected});

  final bool connected;

  @override
  Future<bool> get isConnected async => connected;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

MockClient _provider() => MockClient((request) async => http.Response(
      jsonEncode({
        'streams': [
          {
            'name': 'Torrentio\n1080p',
            'title': '$_release\nSeeders: 140 Size: 2.1 GB',
            'infoHash': _infoHash,
            'fileIdx': 0,
          },
        ],
      }),
      200,
    ));

/// Three releases with distinct reported seeders and resolutions.
MockClient _threeReleases() => MockClient((request) async => http.Response(
      jsonEncode({
        'streams': [
          {
            'name': 'Torrentio\n2160p',
            'title': 'Trigger.2025.2160p.WEB-DL.x265-AAA\nSeeders: 5 Size: 8.1 GB',
            'infoHash': 'a' * 40,
            'fileIdx': 0,
          },
          {
            'name': 'Torrentio\n1080p',
            'title': 'Trigger.2025.1080p.WEB-DL.x264-BBB\nSeeders: 100 Size: 2.1 GB',
            'infoHash': 'b' * 40,
            'fileIdx': 0,
          },
          {
            'name': 'Torrentio\n720p',
            'title': 'Trigger.2025.720p.WEB-DL.x264-CCC\nSeeders: 20 Size: 1.2 GB',
            'infoHash': 'd' * 40,
            'fileIdx': 0,
          },
        ],
      }),
      200,
    ));

/// Local engine stand-in. Torrent creation is held until the test releases
/// it, so a live check stays in progress ("checking").
class _Engine {
  final creates = <Completer<http.Response>>[];

  late final client = MockClient((request) async {
    if (request.url.path == '/create') {
      final held = Completer<http.Response>();
      creates.add(held);
      return held.future;
    }
    return http.Response('{}', 200);
  });

  void releaseAll() {
    for (final held in creates) {
      if (!held.isCompleted) held.complete(http.Response('stopped', 500));
    }
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens Details -> Find Sources and returns once the picker is shown.
  Future<void> openPicker(
    WidgetTester tester,
    SourceProviderService sources, {
    bool pikpak = false,
    bool torbox = false,
    String expectText = _release,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: DetailsScreen(
        item: _movie,
        catalog: _OfflineCatalog(),
        pikpak: _PikPak(signedIn: pikpak),
        transfer: PikPakTransferService(),
        sources: sources,
        torbox: _TorBox(connected: torbox),
        cloudPreferences: CloudPreferencesService(),
        playback: _FakePlayback(),
        mediaState: MediaStateService(),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('Find Sources'));
    await settle(tester);
    expect(find.textContaining(expectText), findsWidgets,
        reason: 'source picker is open');
  }

  Future<void> close(WidgetTester tester, _Engine engine) async {
    engine.releaseAll();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<void> expectFreeP2p(
    WidgetTester tester, {
    required bool enabled,
    bool pikpak = false,
    bool torbox = false,
  }) async {
    final engine = _Engine();
    await http.runWithClient(() async {
      await openPicker(
        tester,
        SourceProviderService(client: _provider()),
        pikpak: pikpak,
        torbox: torbox,
      );
      expect(
        find.textContaining('free P2P ranking on'),
        enabled ? findsOneWidget : findsNothing,
      );
      expect(
        engine.creates.isNotEmpty,
        enabled,
        reason: enabled
            ? 'Free P2P runs the live check'
            : 'a cloud/debrid path must not start Free P2P probing',
      );
      await close(tester, engine);
    }, () => engine.client);
  }

  group('Free P2P eligibility uses one cloud/debrid check', () {
    testWidgets('no cloud or debrid provider: Free P2P is on', (tester) async {
      await expectFreeP2p(tester, enabled: true);
    });

    testWidgets('TorBox connected: Free P2P is not auto-enabled',
        (tester) async {
      await expectFreeP2p(tester, enabled: false, torbox: true);
    });

    testWidgets('Real-Debrid connected: Free P2P is not auto-enabled',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(
        {'orvix_real_debrid_token_v1': 'test-token'},
      );
      await expectFreeP2p(tester, enabled: false);
    });

    testWidgets('Premiumize connected: Free P2P is not auto-enabled',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(
        {'orvix_premiumize_token_v1': 'test-key'},
      );
      await expectFreeP2p(tester, enabled: false);
    });

    testWidgets('PikPak signed in: same cloud path as playback, no Free P2P',
        (tester) async {
      await expectFreeP2p(tester, enabled: false, pikpak: true);
    });
  });

  testWidgets('an unprobed pinned magnet cannot use Free P2P Quick Play',
      (tester) async {
    final engine = _Engine();
    await http.runWithClient(() async {
      final sources = SourceProviderService(client: _provider());
      final results = await sources.resolve(_movie, includeLowQuality: true);
      await sources.pinSource(sources.sourceTargetKey(_movie), results.first);

      await openPicker(tester, sources);

      // The pin keeps its badge and its live check is still in progress.
      expect(find.text('Pinned • CHECKING'), findsWidgets);
      final quickPlay = find.widgetWithText(FilledButton, 'Checking live…');
      expect(quickPlay, findsOneWidget);
      expect(tester.widget<FilledButton>(quickPlay).onPressed, isNull,
          reason: 'Quick Play needs a confirmed-live torrent, pin or not');
      expect(find.widgetWithText(FilledButton, 'Play pinned'), findsNothing);
      // Changing display order must not disable the Free P2P safety gate.
      await tester.tap(find.widgetWithText(FilterChip, 'Free P2P'));
      await settle(tester);
      // Turning off display ranking must not bypass playback safety.
      // The active probing spinner is hidden with the display mode,
      // but the unconfirmed pinned torrent remains unplayable via Quick Play.
      final afterToggle = find.widgetWithText(FilledButton, 'No live source');
      expect(afterToggle, findsOneWidget);
      expect(tester.widget<FilledButton>(afterToggle).onPressed, isNull);
      // The pinned row itself stays selectable for a manual choice.
      expect(find.textContaining(_release), findsWidgets);

      await close(tester, engine);
    }, () => engine.client);
  });

  group('Source Priority while the picker is open', () {
    const seedersFirst = <String>[
      'seeders',
      'resolution',
      'fileSize',
      'releaseQuality',
      'cache',
    ];

    List<String> rowOrder(WidgetTester tester) {
      final tags = ['AAA', 'BBB', 'CCC'];
      double top(String tag) =>
          tester.getTopLeft(find.textContaining('-$tag').first).dy;
      return [...tags]..sort((a, b) => top(a).compareTo(top(b)));
    }

    Future<void> resetToDefault(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sort'));
      await settle(tester);
      await tester.tap(find.text('Reset default'));
      await settle(tester);
    }

    testWidgets('no cloud: Free P2P follows the saved priority and reorders '
        'at once', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'orvix_source_priority_v6': seedersFirst});
      final engine = _Engine();
      await http.runWithClient(() async {
        await openPicker(
          tester,
          SourceProviderService(client: _threeReleases()),
          expectText: 'Trigger.2025.1080p.WEB-DL.x264-BBB',
        );
        expect(find.textContaining('free P2P ranking on'), findsOneWidget);
        expect(engine.creates, isNotEmpty, reason: 'the live check runs');
        // Every check is still in flight: one unchecked group, ordered by
        // reported seeders.
        expect(rowOrder(tester), ['BBB', 'CCC', 'AAA']);
        // Row positions above verify ordering; provider metadata text
        // may appear in multiple rows or additional visible widgets.
        expect(find.textContaining('100 seeders reported'), findsWidgets);

        await resetToDefault(tester);
        // Default priority: release quality ties, then resolution.
        expect(rowOrder(tester), ['AAA', 'BBB', 'CCC']);

        await close(tester, engine);
      }, () => engine.client);
    });

    testWidgets('cloud/debrid: the saved priority sorts and reorders without '
        'any Free P2P probe', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'orvix_source_priority_v6': seedersFirst});
      final engine = _Engine();
      await http.runWithClient(() async {
        await openPicker(
          tester,
          SourceProviderService(client: _threeReleases()),
          torbox: true,
          expectText: 'Trigger.2025.1080p.WEB-DL.x264-BBB',
        );
        expect(find.textContaining('free P2P ranking on'), findsNothing);
        expect(rowOrder(tester), ['BBB', 'CCC', 'AAA']);

        await resetToDefault(tester);
        expect(rowOrder(tester), ['AAA', 'BBB', 'CCC']);

        // Choosing the Free P2P order by hand does not start torrent probes
        // for sources that playback sends to the cloud service.
        await tester.tap(find.widgetWithText(FilterChip, 'Free P2P'));
        await settle(tester);
        expect(engine.creates, isEmpty);
        expect(rowOrder(tester), ['AAA', 'BBB', 'CCC']);

        await close(tester, engine);
      }, () => engine.client);
    });
  });
}
