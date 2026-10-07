import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/app.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/home_screen.dart';
import 'package:orvix/screens/search_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/supporters_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Offline catalog that counts how often Home asks for its rows.
class _CountingCatalog implements CatalogService {
  int homeLoads = 0;

  List<MediaItem> _row(String prefix) => [
        for (var i = 0; i < 8; i++)
          MediaItem(id: 'tt$prefix$i', kind: MediaKind.movie, title: '$prefix $i'),
      ];

  @override
  Future<List<MediaItem>> popularMovies({int limit = 40}) async {
    homeLoads++;
    return _row('Popular');
  }

  @override
  Future<List<MediaItem>> popularSeries({int limit = 40}) async =>
      _row('Series');

  @override
  Future<List<MediaItem>> topRatedMovies({int limit = 40}) async =>
      _row('Top');

  @override
  Future<List<MediaItem>> topRatedSeries({int limit = 40}) async =>
      _row('TopSeries');

  @override
  Future<List<MediaItem>> search(String query, {int limit = 18}) async => [
        MediaItem(id: 'ttsearch', kind: MediaKind.movie, title: 'Found $query'),
      ];

  @override
  Future<MediaItem?> details(MediaItem item) async => item;

  @override
  Future<void> prefetchDetails(MediaItem item) async {}

  @override
  MediaItem? peekDetails(MediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoSupporters implements SupportersRepository {
  @override
  Future<List<OrvixContributor>> fetchContributors() async => const [];

  @override
  Future<List<OrvixSupporter>> fetchPublicSupporters() async => const [];
}

class _SignedOutBackend implements OrvixAccountBackend {
  @override
  OrvixAccountUser? get currentUser => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late OrvixAccountBackend originalBackend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    OrvixAccountService.backend = _SignedOutBackend();
    SupportersService.repository = _NoSupporters();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    OrvixAccountService.backend = originalBackend;
  });

  Future<_CountingCatalog> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Settings' switch rows already raise Flutter's debug-only ListTile ink
    // notice on develop (see desktop_responsive_layout_test.dart). The shell
    // builds every destination, so tolerate that notice and nothing else.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('ListTile background color')) {
        previous?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = previous);

    final catalog = _CountingCatalog();
    final sources = SourceProviderService(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'streams': []}), 200),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: debugBuildOrvixShell(
        catalog: catalog,
        pikpak: PikPakService(),
        transfer: PikPakTransferService(),
        sources: sources,
        torbox: TorBoxService(),
        cloudPreferences: CloudPreferencesService(),
        playback: _FakePlayback(),
        mediaState: MediaStateService(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return catalog;
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> unmount(WidgetTester tester) async {
    // Home rotates its hero on a periodic timer; unmount to stop it.
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final size in const [Size(1200, 800), Size(600, 900)]) {
    final layout = size.width < 720 ? 'compact' : 'rail';

    testWidgets(
        '$layout shell: Home -> Search -> Home keeps the loaded Home state',
        (tester) async {
      final catalog = await pumpShell(tester, size);
      expect(find.text('Popular 0'), findsWidgets);
      expect(catalog.homeLoads, 1);
      final homeState = tester.state(find.byType(HomeScreen));

      await select(tester, 'Search');
      await tester.enterText(find.byType(TextField).first, 'heat');
      await tester.pump(const Duration(seconds: 1));
      final searchState = tester.state(find.byType(SearchScreen));

      await select(tester, 'Home');
      expect(catalog.homeLoads, 1, reason: 'Home must not reload');
      expect(
        identical(tester.state(find.byType(HomeScreen)), homeState),
        isTrue,
        reason: 'Home State must survive a destination change',
      );
      expect(find.text('Popular 0'), findsWidgets);

      await select(tester, 'Search');
      expect(
        identical(tester.state(find.byType(SearchScreen)), searchState),
        isTrue,
      );
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text, 'heat');

      await unmount(tester);
    });
  }

  testWidgets('Home scroll position survives a round trip through Search',
      (tester) async {
    await pumpShell(tester, const Size(1200, 800));
    final homeList = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(Scrollable),
    );
    final vertical = homeList.evaluate().firstWhere(
          (e) =>
              (e.widget as Scrollable).axisDirection == AxisDirection.down,
        );
    final position = (vertical as StatefulElement).state as ScrollableState;
    position.position.jumpTo(240);
    await tester.pump();

    await select(tester, 'Search');
    await select(tester, 'Home');
    expect(position.mounted, isTrue);
    expect(position.position.pixels, 240);

    await unmount(tester);
  });
}
