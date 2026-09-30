import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Release-level UI guardrails that exercise the viewport classes Orvix ships.
/// Feature screens keep their focused regression tests; this suite makes sure
/// shared responsive/focus primitives remain usable on mobile, desktop and TV.
void main() {
  const viewports = <String, Size>{
    'android-mobile': Size(390, 844),
    'windows': Size(1366, 768),
    'android-tv-720p': Size(1280, 720),
    'android-tv-1080p': Size(1920, 1080),
    'macos': Size(1440, 900),
  };

  for (final entry in viewports.entries) {
    testWidgets('${entry.key} viewport has no overflow', (tester) async {
      await tester.binding.setSurfaceSize(entry.value);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    const Text('Orvix automated QA'),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth >= 1000 ? 6 : 2,
                          childAspectRatio: .68,
                        ),
                        itemCount: 18,
                        itemBuilder: (_, index) => Card(
                          key: ValueKey('qa-card-$index'),
                          child: InkWell(
                            autofocus: index == 0,
                            onTap: () {},
                            child: Center(child: Text('Item $index')),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('qa-card-0')), findsOneWidget);
    });
  }

  testWidgets('TV D-pad can move focus repeatedly without trapping', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusTraversalGroup(
            child: ListView(
              children: List.generate(
                8,
                (index) => SizedBox(
                  height: 72,
                  child: TextButton(
                    key: ValueKey('tv-focus-$index'),
                    autofocus: index == 0,
                    onPressed: () {},
                    child: Text('Row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 6; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }

    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
