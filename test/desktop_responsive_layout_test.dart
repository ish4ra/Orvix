import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/screens/library_screen.dart';
import 'package:orvix/screens/settings_screen.dart';
import 'package:orvix/screens/sources_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Representative desktop widths, from a full-size window down to a narrow
/// one. Tests run on a non-Android host, so screens take their desktop paths.
const _desktopSizes = <Size>[
  Size(1440, 900),
  Size(1100, 800),
  Size(900, 700),
  Size(720, 700),
  Size(600, 700),
  Size(480, 700),
];

const _providerLabels = ['PikPak', 'TorBox', 'Real-Debrid', 'Premiumize'];

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SignedInPikPak implements PikPakService {
  @override
  Future<bool> get isSignedIn async => true;

  @override
  Future<String?> get signedInUsername async => 'viewer@example.com';

  @override
  Future<List<PikPakFile>> listFiles({String parentId = ''}) async => const [
        PikPakFile(id: '1', name: 'Movies', kind: 'drive#folder'),
        PikPakFile(
          id: '2',
          name: 'Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-GROUP.mkv',
          kind: 'drive#file',
          size: '12345678901',
          mimeType: 'video/x-matroska',
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ConnectedTorBox implements TorBoxService {
  @override
  Future<bool> get isConnected async => true;

  @override
  Future<TorBoxAccount> account() async => const TorBoxAccount(
        email: 'someone.with.a.long.address@example.com',
        plan: 'Pro',
      );

  @override
  Future<List<TorBoxItem>> listTorrents({bool fresh = false}) async => const [];

  @override
  Future<List<TorBoxItem>> listWebDownloads({bool fresh = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

/// Pumps [build] and returns every layout overflow Flutter reported. Other
/// errors still fail the test, except the debug-only ListTile ink notice the
/// cloud list rows already raise on develop.
Future<List<String>> _pumpCollectingOverflows(
  WidgetTester tester,
  Widget child, {
  Future<void> Function()? interact,
}) async {
  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (message.contains('overflowed')) {
      overflows.add(message.split('\n').first);
    } else if (!message.contains('ListTile background color')) {
      previous?.call(details);
    }
  };
  try {
    await tester.pumpWidget(_host(child));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    if (interact != null) await interact();
  } finally {
    FlutterError.onError = previous;
  }
  // Unmount and let pending async work and timers settle inside the test.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
  return overflows;
}

LibraryScreen _clouds({PikPakService? pikpak, TorBoxService? torbox}) =>
    LibraryScreen(
      pikpak: pikpak ?? PikPakService(),
      transfer: PikPakTransferService(),
      torbox: torbox ?? TorBoxService(),
      cloudPreferences: CloudPreferencesService(),
      playback: _FakePlayback(),
      onAuthChanged: () {},
    );

void _expectSingleLine(WidgetTester tester, String label) {
  for (final element in find.text(label).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final oneLineHeight = paragraph.getMinIntrinsicHeight(double.infinity);
    final fullWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      paragraph.size.height,
      lessThanOrEqualTo(oneLineHeight + 0.5),
      reason: '"$label" wrapped onto several lines',
    );
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(fullWidth - 0.5),
      reason: '"$label" was squeezed narrower than its text',
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Clouds provider selector', () {
    Widget header({
      required ValueChanged<CloudProvider> onSelected,
      CloudProvider provider = CloudProvider.pikpak,
      bool mobile = false,
    }) =>
        Align(
          alignment: Alignment.topLeft,
          child: CloudsHeader(
            provider: provider,
            onSelected: onSelected,
            mobile: mobile,
          ),
        );

    testWidgets('wide desktop keeps the title and labelled segments on one row',
        (tester) async {
      await _setSize(tester, const Size(1440, 900));
      final overflows =
          await _pumpCollectingOverflows(tester, header(onSelected: (_) {}),
              interact: () async {
        expect(find.byType(SegmentedButton<CloudProvider>), findsOneWidget);
        expect(find.byKey(const ValueKey('clouds-provider-menu')), findsNothing);
        final title = tester.getRect(find.text('Clouds'));
        final selector =
            tester.getRect(find.byType(SegmentedButton<CloudProvider>));
        expect((title.center.dy - selector.center.dy).abs(), lessThan(4));
        expect(selector.left, greaterThan(title.right));
        for (final label in _providerLabels) {
          _expectSingleLine(tester, label);
        }
      });
      expect(overflows, isEmpty);
    });

    testWidgets('medium desktop width moves the selector below the title',
        (tester) async {
      // Wide enough for the labelled selector alone, not beside the title.
      await _setSize(tester, const Size(1000, 700));
      final overflows =
          await _pumpCollectingOverflows(tester, header(onSelected: (_) {}),
              interact: () async {
        expect(find.byType(SegmentedButton<CloudProvider>), findsOneWidget);
        final title = tester.getRect(find.text('Clouds'));
        final selector =
            tester.getRect(find.byType(SegmentedButton<CloudProvider>));
        expect(selector.top, greaterThanOrEqualTo(title.bottom));
        for (final label in _providerLabels) {
          _expectSingleLine(tester, label);
        }
      });
      expect(overflows, isEmpty);
    });

    for (final size in _desktopSizes) {
      testWidgets(
          'desktop ${size.width.toInt()}px never crushes provider labels',
          (tester) async {
        await _setSize(tester, size);
        final overflows = await _pumpCollectingOverflows(
          tester,
          header(onSelected: (_) {}, provider: CloudProvider.realDebrid),
          interact: () async {
            final hasSegments =
                find.byType(SegmentedButton<CloudProvider>).evaluate().isNotEmpty;
            final hasMenu = find
                .byKey(const ValueKey('clouds-provider-menu'))
                .evaluate()
                .isNotEmpty;
            expect(hasSegments != hasMenu, isTrue);
            // Every label on screen (segments, or the selected value in the
            // menu) stays on one line at its natural width.
            for (final label in _providerLabels) {
              _expectSingleLine(tester, label);
            }
            if (hasMenu) expect(find.text('Real-Debrid'), findsOneWidget);
          },
        );
        expect(overflows, isEmpty);
      });
    }

    testWidgets('narrow desktop keeps all four providers selectable',
        (tester) async {
      await _setSize(tester, const Size(480, 700));
      var current = CloudProvider.pikpak;
      final picked = <CloudProvider>[];
      late StateSetter rebuild;
      final overflows = await _pumpCollectingOverflows(
        tester,
        StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return header(
            provider: current,
            onSelected: (provider) {
              picked.add(provider);
              rebuild(() => current = provider);
            },
          );
        }),
        interact: () async {
          final menu = find.byKey(const ValueKey('clouds-provider-menu'));
          expect(menu, findsOneWidget);
          expect(find.byType(SegmentedButton<CloudProvider>), findsNothing);
          for (final provider in [
            CloudProvider.torbox,
            CloudProvider.realDebrid,
            CloudProvider.premiumize,
            CloudProvider.pikpak,
          ]) {
            await tester.tap(menu);
            await tester.pumpAndSettle();
            // Every provider is listed in the open menu.
            for (final label in _providerLabels) {
              expect(find.text(label), findsWidgets);
            }
            await tester.tap(find.text(provider.label).last);
            await tester.pumpAndSettle();
            expect(current, provider);
            // The field shows the newly selected provider.
            expect(find.text(provider.label), findsOneWidget);
          }
        },
      );
      expect(picked, [
        CloudProvider.torbox,
        CloudProvider.realDebrid,
        CloudProvider.premiumize,
        CloudProvider.pikpak,
      ]);
      expect(overflows, isEmpty);
    });

    testWidgets('layout follows available width, not platform identity',
        (tester) async {
      // Same desktop platform state, two widths: the layout must differ.
      final layouts = <CloudsHeaderLayout>[];
      for (final width in [1440.0, 480.0]) {
        await _setSize(tester, Size(width, 700));
        await tester.pumpWidget(_host(Builder(
          builder: (context) {
            layouts.add(CloudsHeader.layoutFor(context, width - 64));
            return header(onSelected: (_) {});
          },
        )));
      }
      expect(layouts, [CloudsHeaderLayout.inline, CloudsHeaderLayout.menu]);
    });

    testWidgets('full Clouds screen adapts on a narrow desktop window',
        (tester) async {
      await _setSize(tester, const Size(480, 700));
      final overflows =
          await _pumpCollectingOverflows(tester, _clouds(), interact: () async {
        expect(
            find.byKey(const ValueKey('clouds-provider-menu')), findsOneWidget);
        expect(find.text('Connect PikPak'), findsOneWidget);
      });
      expect(overflows, isEmpty);
    });

    testWidgets('Android Mobile keeps its full-width compact segments',
        (tester) async {
      await _setSize(tester, const Size(390, 800));
      await tester.pumpWidget(
        _host(header(onSelected: (_) {}, mobile: true)),
      );
      final button = tester.widget<SegmentedButton<CloudProvider>>(
        find.byType(SegmentedButton<CloudProvider>),
      );
      expect(button.expandedInsets, EdgeInsets.zero);
      expect(button.showSelectedIcon, isFalse);
      expect(button.segments.map((s) => s.icon), everyElement(isNull));
      expect(button.segments.length, 4);
      expect(find.byKey(const ValueKey('clouds-provider-menu')), findsNothing);
      final selector =
          tester.getRect(find.byType(SegmentedButton<CloudProvider>));
      expect(selector.width, closeTo(390 - 40, 0.5));
      expect(selector.top,
          greaterThanOrEqualTo(tester.getRect(find.text('Clouds')).bottom));
    });

    // Android TV uses TvCloudProviderTabs (tv_screens_test.dart).
  });

  group('Cloud library headers', () {
    testWidgets('PikPak header uses an icon Refresh on narrow desktop',
        (tester) async {
      await _setSize(tester, const Size(480, 700));
      final overflows = await _pumpCollectingOverflows(
          tester, _clouds(pikpak: _SignedInPikPak()), interact: () async {
        expect(find.byTooltip('Refresh'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Refresh'), findsNothing);
        expect(find.text('Sign out'), findsOneWidget);
        _expectSingleLine(tester, 'My PikPak');
      });
      expect(overflows, isEmpty);
    });

    testWidgets('PikPak header keeps the labelled Refresh on wide desktop',
        (tester) async {
      await _setSize(tester, const Size(1440, 900));
      final overflows = await _pumpCollectingOverflows(
          tester, _clouds(pikpak: _SignedInPikPak()), interact: () async {
        expect(find.widgetWithText(OutlinedButton, 'Refresh'), findsOneWidget);
        expect(find.text('Sign out'), findsOneWidget);
      });
      expect(overflows, isEmpty);
    });

    for (final size in _desktopSizes) {
      testWidgets('TorBox connected header fits at ${size.width.toInt()}px',
          (tester) async {
        SharedPreferences.setMockInitialValues(
            {'orvix_preferred_cloud_v1': 'torbox'});
        await _setSize(tester, size);
        final overflows = await _pumpCollectingOverflows(
            tester, _clouds(torbox: _ConnectedTorBox()), interact: () async {
          expect(find.text('Sign out'), findsOneWidget);
          expect(find.byTooltip('Refresh').evaluate().length +
                  find.widgetWithText(OutlinedButton, 'Refresh')
                      .evaluate()
                      .length,
              1);
        });
        expect(overflows, isEmpty);
      });
    }
  });

  group('Settings, Sources and Details at narrow desktop widths', () {
    for (final size in _desktopSizes) {
      testWidgets('Settings has no overflow at ${size.width.toInt()}px',
          (tester) async {
        await _setSize(tester, size);
        final overflows =
            await _pumpCollectingOverflows(tester, const SettingsScreen());
        expect(overflows, isEmpty);
      });

      testWidgets('Sources has no overflow at ${size.width.toInt()}px',
          (tester) async {
        await _setSize(tester, size);
        final overflows = await _pumpCollectingOverflows(
          tester,
          SourcesScreen(sources: SourceProviderService()),
          interact: () async {
            expect(find.text('Torrentio-compatible engine'), findsOneWidget);
          },
        );
        expect(overflows, isEmpty);
      });

      testWidgets(
          'Details hero keeps its actions reachable at ${size.width.toInt()}px',
          (tester) async {
        await _setSize(tester, size);
        final overflows = await _pumpCollectingOverflows(
          tester,
          DetailsScreen(
            item: const MediaItem(
              id: 'tt0167260',
              kind: MediaKind.movie,
              title: 'The Lord of the Rings: The Return of the King',
              year: '2003',
              runtime: '201 min',
              rating: 9.0,
              genres: ['Adventure', 'Drama', 'Fantasy'],
              description:
                  'Gandalf and Aragorn lead the World of Men against the army '
                  'of Sauron to draw his gaze from Frodo and Sam as they '
                  'approach Mount Doom with the One Ring.',
            ),
            catalog: _OfflineCatalog(),
            pikpak: PikPakService(),
            transfer: PikPakTransferService(),
            sources: SourceProviderService(),
            torbox: TorBoxService(),
            cloudPreferences: CloudPreferencesService(),
            playback: _FakePlayback(),
            mediaState: MediaStateService(),
          ),
          interact: () async {
            for (final action in [
              'Play',
              'Find Sources',
              'Add to Library',
              'Watchlist',
            ]) {
              final finder = find.text(action);
              expect(finder, findsOneWidget);
              await tester.ensureVisible(finder);
              await tester.pump();
              // Hit-testable means it is laid out on screen and not clipped.
              expect(finder.hitTestable(), findsOneWidget, reason: action);
            }
          },
        );
        expect(overflows, isEmpty);
      });
    }
  });
}
