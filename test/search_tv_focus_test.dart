import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/search_screen.dart';
import 'package:orvix/services/catalog_service.dart';

class _FakeCatalogService extends CatalogService {
  @override
  Future<List<MediaItem>> search(String query, {int limit = 18}) async {
    return const [
      MediaItem(
        id: 'tt0133093',
        kind: MediaKind.movie,
        title: 'The Matrix',
        year: '1999',
      ),
      MediaItem(
        id: 'tt0234215',
        kind: MediaKind.movie,
        title: 'The Matrix Reloaded',
        year: '2003',
      ),
    ];
  }
}

void main() {
  testWidgets('D-pad down moves Search focus to the first result', (tester) async {
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

    final fieldFinder = find.byType(TextField);
    await tester.enterText(fieldFinder, 'matrix');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(fieldFinder);
    expect(field.focusNode?.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('search-result-0')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    final firstCard = find.byKey(const ValueKey('search-result-0'));
    final inkWellFinder = find.descendant(
      of: firstCard,
      matching: find.byType(InkWell),
    );
    final inkWell = tester.widget<InkWell>(inkWellFinder.first);
    expect(inkWell.focusNode?.hasFocus, isTrue);
  });
}
