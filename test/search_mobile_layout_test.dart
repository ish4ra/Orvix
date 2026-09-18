import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/search_screen.dart';
import 'package:orvix/services/catalog_service.dart';

class _FakeCatalogService extends CatalogService {
  @override
  Future<List<MediaItem>> search(String query, {int limit = 18}) async {
    return const [
      MediaItem(id: 'tt1', kind: MediaKind.series, title: 'Prison Break', year: '2005'),
      MediaItem(id: 'tt2', kind: MediaKind.movie, title: 'Prison Break', year: '2015'),
      MediaItem(id: 'tt3', kind: MediaKind.movie, title: 'Prison', year: '1987'),
      MediaItem(id: 'tt4', kind: MediaKind.series, title: 'Prisoner', year: '2010'),
    ];
  }
}

void main() {
  testWidgets('phone search uses three compact poster columns', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final catalog = _FakeCatalogService();
    addTearDown(catalog.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchScreen(
            catalog: catalog,
            onOpen: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'prison');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();

    final first = tester.getRect(find.byKey(const ValueKey('search-result-0')));
    final second = tester.getRect(find.byKey(const ValueKey('search-result-1')));
    final third = tester.getRect(find.byKey(const ValueKey('search-result-2')));

    expect((first.top - second.top).abs(), lessThan(1));
    expect((first.top - third.top).abs(), lessThan(1));
    expect(first.left, lessThan(second.left));
    expect(second.left, lessThan(third.left));
    expect(third.right, lessThanOrEqualTo(390));
  });
}
