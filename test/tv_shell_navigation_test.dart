import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/tv/tv_shell.dart';
import 'package:orvix/tv/tv_widgets.dart';

const _destinations = [
  TvDestination(icon: Icons.home, selectedIcon: Icons.home, label: 'Home'),
  TvDestination(
      icon: Icons.search, selectedIcon: Icons.search, label: 'Search'),
  TvDestination(
      icon: Icons.settings, selectedIcon: Icons.settings, label: 'Settings'),
];

/// A host for TvShell with simple screens of buttons.
class _Host extends StatefulWidget {
  const _Host({this.removable});

  final ValueNotifier<bool>? removable;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int index = 0;

  Widget _screen(int i) {
    final name = _destinations[i].label;
    return ListView(
      padding: const EdgeInsets.all(30),
      children: [
        Row(children: [
          TvButton(
            key: ValueKey('$name-a'),
            label: '$name A',
            onPressed: () {},
          ),
          const SizedBox(width: 12),
          TvButton(
            key: ValueKey('$name-b'),
            label: '$name B',
            onPressed: () {},
          ),
        ]),
        const SizedBox(height: 16),
        if (i != 2 || (widget.removable?.value ?? true))
          TvButton(
            key: ValueKey('$name-c'),
            label: '$name C',
            onPressed: () {},
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: widget.removable ?? ValueNotifier(true),
        builder: (context, _, __) => TvShell(
          destinations: _destinations,
          selectedIndex: index,
          onSelected: (value) => setState(() => index = value),
          screenBuilder: (context, i) => _screen(i),
        ),
      ),
    );
  }
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

bool _focused(WidgetTester tester, String key) {
  final focus = tester.widget<Focus>(find
      .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Focus))
      .first);
  return focus.focusNode?.hasPrimaryFocus ?? false;
}

TvShellState _shell(WidgetTester tester) =>
    tester.state<TvShellState>(find.byType(TvShell));

void main() {
  testWidgets('starts in Home content and moves between content and menu',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    expect(_focused(tester, 'Home-a'), isTrue);
    expect(_shell(tester).navigationHasFocus, isFalse);

    // Inside content Left moves left first...
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'Home-b'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(tester, 'Home-a'), isTrue);

    // ...and at the left edge opens the menu on the current destination.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_shell(tester).navigationHasFocus, isTrue);
    expect(_focused(tester, 'tv-nav-Home'), isTrue);

    // Left in the menu stays there; Right goes back to where the user was.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(tester, 'tv-nav-Home'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'Home-a'), isTrue);
  });

  testWidgets('every destination is reachable and OK enters it',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    for (final destination in _destinations.skip(1)) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester, 'tv-nav-${destination.label}'), isTrue);
    }
    // Moves stop at the end of the menu instead of wrapping.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'tv-nav-Settings'), isTrue);

    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('Settings-a')), findsOneWidget);
    expect(_focused(tester, 'Settings-a'), isTrue);
    expect(_shell(tester).navigationHasFocus, isFalse);
  });

  testWidgets('a destination remembers its focused control', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    // Open Search, move to its third control.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Search-c'), isTrue);

    // Go Home through the menu and back to Search.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_focused(tester, 'Home-a'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_focused(tester, 'Search-c'), isTrue);
  });

  testWidgets('Back returns to Home; Home lets Back leave the app',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_focused(tester, 'Settings-a'), isTrue);

    // Back on Settings goes Home, once, and does not leave Orvix.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state<_HostState>(find.byType(_Host)).index, 0);
    expect(_focused(tester, 'Home-a'), isTrue);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));

    // Back on Home is not intercepted.
    final popScope = tester.widget<PopScope<Object?>>(
        find.byWidgetPredicate((widget) => widget is PopScope).first);
    expect(popScope.canPop, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  testWidgets('focus comes back when the focused control disappears',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final removable = ValueNotifier(true);
    await tester.pumpWidget(_Host(removable: removable));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Settings-c'), isTrue);

    removable.value = false;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('Settings-c')), findsNothing);
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(primary, isNot(isA<FocusScopeNode>()));
    expect(_focused(tester, 'Settings-a'), isTrue);
  });
}
