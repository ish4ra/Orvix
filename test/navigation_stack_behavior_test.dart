import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'player back reveals the existing source picker before title details',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (titleContext) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const Key('open-source-picker'),
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: titleContext,
                      builder: (sheetContext) => SizedBox(
                        height: 240,
                        child: Column(
                          children: [
                            const Text('Source picker'),
                            FilledButton(
                              key: const Key('play-source'),
                              onPressed: () {
                                // This matches Orvix's navigation contract:
                                // do not pop the picker before pushing playback.
                                Navigator.of(titleContext).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (playerContext) => Scaffold(
                                      body: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text('Player'),
                                            FilledButton(
                                              key: const Key('player-back'),
                                              onPressed: () =>
                                                  Navigator.of(playerContext)
                                                      .pop(),
                                              child: const Text('Back'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                              child: const Text('Play source'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: const Text('Title details'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-source-picker')));
      await tester.pumpAndSettle();
      expect(find.text('Source picker'), findsOneWidget);

      await tester.tap(find.byKey(const Key('play-source')));
      await tester.pumpAndSettle();
      expect(find.text('Player'), findsOneWidget);
      expect(find.text('Source picker'), findsNothing);

      await tester.tap(find.byKey(const Key('player-back')));
      await tester.pumpAndSettle();
      expect(find.text('Source picker'), findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Source picker'), findsNothing);
      expect(find.text('Title details'), findsOneWidget);
    },
  );
}
