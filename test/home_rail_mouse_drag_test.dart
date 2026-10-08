import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/home_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<MediaItem> _row(String prefix) => [
      for (var i = 0; i < 14; i++)
        MediaItem(id: 'tt$prefix$i', kind: MediaKind.movie, title: '$prefix $i'),
    ];

class _OfflineCatalog implements CatalogService {
  @override
  Future<List<MediaItem>> popularMovies({int limit = 40}) async =>
      _row('Popular');

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
  Future<MediaItem?> details(MediaItem item) async => item;

  @override
  Future<void> prefetchDetails(MediaItem item) async {}

  @override
  MediaItem? peekDetails(MediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Every poster shares one title, so whichever item the shuffled hero picks,
/// the hero shows the same text as the rail cards.
class _SharedTitleCatalog extends _OfflineCatalog {
  static const title = 'Shared title';

  List<MediaItem> _shared(String prefix) => [
        for (final item in _row(prefix))
          MediaItem(id: item.id, kind: item.kind, title: title),
      ];

  @override
  Future<List<MediaItem>> popularMovies({int limit = 40}) async =>
      _shared('Popular');

  @override
  Future<List<MediaItem>> popularSeries({int limit = 40}) async =>
      _shared('Series');

  @override
  Future<List<MediaItem>> topRatedMovies({int limit = 40}) async =>
      _shared('Top');

  @override
  Future<List<MediaItem>> topRatedSeries({int limit = 40}) async =>
      _shared('TopSeries');
}

class _ContinueState implements MediaStateService {
  @override
  Future<List<ContinueWatchingEntry>> continueWatching({int limit = 24}) async =>
      [
        for (final item in _row('Resume'))
          ContinueWatchingEntry(
            item: item,
            position: const Duration(minutes: 10),
            duration: const Duration(minutes: 90),
            updatedAt: DateTime(2026, 10, 1),
          ),
      ];

  @override
  Future<List<MediaItem>> library() async => const [];

  @override
  Future<List<MediaItem>> watchlist() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Every horizontal Scrollable on Home: the media and Continue Watching rails.
final Finder _horizontalRails = find.byWidgetPredicate(
  (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
);

/// The card title [label] inside a horizontal rail.
///
/// Home shuffles its hero candidates, so the same title can also be shown
/// by the hero, which is not inside any horizontal rail. Scoping the lookup
/// to the rails keeps the target independent of the hero pick.
Finder _railCard(String label) =>
    find.descendant(of: _horizontalRails, matching: find.text(label)).first;

/// The horizontal rail that holds [card].
ScrollableState _railOf(WidgetTester tester, Finder card) {
  final element = find
      .ancestor(of: card, matching: _horizontalRails)
      .evaluate()
      .first;
  return (element as StatefulElement).state as ScrollableState;
}

Future<void> _pumpNarrowHome(
  WidgetTester tester, {
  CatalogService? catalog,
}) async {
  // Below the 900px wide-desktop breakpoint: the generic Home layout with
  // plain horizontal ListViews (_MediaRail / _ContinueRail).
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HomeScreen(
        catalog: catalog ?? _OfflineCatalog(),
        sources: SourceProviderService(
          client: MockClient(
            (_) async => http.Response(jsonEncode({'streams': []}), 200),
          ),
        ),
        mediaState: _ContinueState(),
        onOpen: (_) {},
        onResume: (_) {},
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<double> _drag(
  WidgetTester tester,
  String label,
  PointerDeviceKind kind,
) async {
  final card = _railCard(label);
  final rail = _railOf(tester, card);
  final before = rail.position.pixels;
  await tester.dragFrom(
    tester.getCenter(card),
    const Offset(-260, 0),
    kind: kind,
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
  return rail.position.pixels - before;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('narrow Windows Home: poster and Continue Watching rails drag '
      'with the mouse', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpNarrowHome(tester);

    expect(await _drag(tester, 'Popular 0', PointerDeviceKind.mouse),
        greaterThan(100));
    expect(await _drag(tester, 'Resume 0', PointerDeviceKind.mouse),
        greaterThan(100));
    // Touch keeps working too.
    expect(await _drag(tester, 'Series 0', PointerDeviceKind.touch),
        greaterThan(100));

    await unmount(tester);
  });

  testWidgets('Android keeps its default rail drag devices', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpNarrowHome(tester);

    expect(await _drag(tester, 'Popular 0', PointerDeviceKind.touch),
        greaterThan(100));
    // Mouse drag stays as it was on Android (Flutter's default: off).
    expect(await _drag(tester, 'Series 0', PointerDeviceKind.mouse), 0);

    await unmount(tester);
  });

  testWidgets('rail helper picks the rail card when the hero shows the same '
      'title', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpNarrowHome(tester, catalog: _SharedTitleCatalog());

    const title = _SharedTitleCatalog.title;
    final all = find.text(title);
    final inRails = find.descendant(
      of: _horizontalRails,
      matching: find.text(title),
    );
    // The hero copy exists and sits outside every horizontal rail, ahead of
    // the rail cards: an unscoped `.first` lookup would land on it.
    final heroCopies = all.evaluate().toSet()
      ..removeAll(inRails.evaluate());
    expect(heroCopies, hasLength(1));
    expect(all.evaluate().first, heroCopies.single);
    expect(
      find.ancestor(of: all.first, matching: _horizontalRails),
      findsNothing,
    );

    final card = _railCard(title);
    expect(heroCopies.contains(card.evaluate().single), isFalse);
    expect(find.ancestor(of: card, matching: _horizontalRails), findsWidgets);
    expect(await _drag(tester, title, PointerDeviceKind.mouse),
        greaterThan(100));

    await unmount(tester);
  });
}
