import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/search_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/platform_profile.dart';

class _FakeCatalogService extends CatalogService {
  @override
  Future<List<MediaItem>> search(String query, {int limit = 18}) async {
    return const [
      MediaItem(id: 'tt0133093', kind: MediaKind.movie, title: 'The Matrix', year: '1999'),
      MediaItem(id: 'tt0234215', kind: MediaKind.movie, title: 'The Matrix Reloaded', year: '2003'),
    ];
  }

  @override
  Future<MediaItem?> details(MediaItem item) async => item;

  @override
  MediaItem? peekDetails(MediaItem item) => null;
}

final _touch = TargetPlatformVariant(
  {TargetPlatform.android, TargetPlatform.iOS},
);
final _desktop = TargetPlatformVariant(
  {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux},
);

/// Search hosted the way the app shell hosts it: kept alive and switched
/// with [active], with Details pushed on the same navigator.
class _Host extends StatelessWidget {
  const _Host({required this.catalog, required this.active});

  final CatalogService catalog;
  final ValueListenable<bool> active;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, value, _) => SearchScreen(
            catalog: catalog,
            active: value,
            onOpen: (item) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(),
                  body: Text('Details ${item.title}'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

FocusNode _fieldFocus(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).focusNode!;

bool _keyboardVisible(WidgetTester tester) => tester.testTextInput.isVisible;

Future<void> _pumpHost(
  WidgetTester tester,
  ValueNotifier<bool> active,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final catalog = _FakeCatalogService();
  addTearDown(catalog.dispose);
  await tester.pumpWidget(_Host(catalog: catalog, active: active));
  await tester.pumpAndSettle();
}

void main() {
  group('phone and tablet', () {
    testWidgets('opening Search does not focus the field or open the keyboard',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);

      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
    }, variant: _touch);

    testWidgets('switching to Search from another tab does not open the keyboard',
        (tester) async {
      final active = ValueNotifier(false);
      await _pumpHost(tester, active);

      active.value = true;
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
    }, variant: _touch);

    testWidgets('tapping the field focuses it and opens the keyboard',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isTrue);
      expect(_keyboardVisible(tester), isTrue);
    }, variant: _touch);

    testWidgets('leaving Search closes the keyboard and coming back keeps it '
        'closed', (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_keyboardVisible(tester), isTrue);

      active.value = false;
      await tester.pumpAndSettle();
      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);

      active.value = true;
      await tester.pumpAndSettle();
      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
    }, variant: _touch);

    testWidgets('returning from Details does not refocus the field',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);
      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(_fieldFocus(tester).hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey('search-result-0')));
      await tester.pumpAndSettle();
      expect(find.text('Details The Matrix'), findsOneWidget);
      expect(_keyboardVisible(tester), isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Details The Matrix'), findsNothing);
      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
      // The query and results are kept.
      expect(find.byKey(const ValueKey('search-result-0')), findsOneWidget);
    }, variant: _touch);

    testWidgets('tapping outside the field closes the keyboard', (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_keyboardVisible(tester), isTrue);

      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
    }, variant: _touch);

    testWidgets('clearing the query does not open the keyboard by itself',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);
      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(_keyboardVisible(tester), isFalse);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Clear'), findsNothing);
      expect(_fieldFocus(tester).hasFocus, isFalse);
      expect(_keyboardVisible(tester), isFalse);
    }, variant: _touch);
  });

  group('desktop', () {
    testWidgets('opening Search keeps keyboard-first focus on the field',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);

      expect(_fieldFocus(tester).hasFocus, isTrue);
    }, variant: _desktop);

    testWidgets('switching back to Search focuses the field again',
        (tester) async {
      final active = ValueNotifier(false);
      await _pumpHost(tester, active);
      expect(_fieldFocus(tester).hasFocus, isFalse);

      active.value = true;
      await tester.pumpAndSettle();
      expect(_fieldFocus(tester).hasFocus, isTrue);
    }, variant: _desktop);

    testWidgets('clearing the query goes straight back to typing',
        (tester) async {
      final active = ValueNotifier(true);
      await _pumpHost(tester, active);
      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();
      _fieldFocus(tester).unfocus();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isTrue);
    }, variant: _desktop);
  });

  group('Android TV', () {
    setUp(() => PlatformProfile.debugAndroidTvOverride = true);
    tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

    testWidgets('opening or returning to Search never opens the keyboard',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final catalog = _FakeCatalogService();
      addTearDown(catalog.dispose);
      final active = ValueNotifier(true);
      await tester.pumpWidget(_Host(catalog: catalog, active: active));
      await tester.pumpAndSettle();
      expect(_keyboardVisible(tester), isFalse);

      active.value = false;
      await tester.pumpAndSettle();
      active.value = true;
      await tester.pumpAndSettle();
      expect(_keyboardVisible(tester), isFalse);
      // DPAD focus and OK-to-type stay covered by tv_screens_test.dart.
    });
  });
}
