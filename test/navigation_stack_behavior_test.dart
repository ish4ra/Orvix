import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'player back reopens cached source picker before title details',
    (tester) async {
      final cachedSources = <String>['Source A', 'Source B'];
      var providerResolveCount = 0;

      Future<void> openCachedSourceFlow(BuildContext titleContext) async {
        providerResolveCount++;
        while (titleContext.mounted) {
          final selected = await showModalBottomSheet<String>(
            context: titleContext,
            builder: (sheetContext) => SizedBox(
              height: 240,
              child: Column(
                children: [
                  const Text('Source picker'),
                  for (final source in cachedSources)
                    FilledButton(
                      key: Key('play-$source'),
                      onPressed: () => Navigator.pop(sheetContext, source),
                      child: Text(source),
                    ),
                ],
              ),
            ),
          );
          if (selected == null || !titleContext.mounted) return;

          await Navigator.of(titleContext).push<void>(
            MaterialPageRoute<void>(
              builder: (playerContext) => Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Player: $selected'),
                      FilledButton(
                        key: const Key('player-back'),
                        onPressed: () => Navigator.of(playerContext).pop(),
                        child: const Text('Back'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          // No provider resolve here. The loop reuses cachedSources.
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (titleContext) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const Key('open-source-picker'),
                  onPressed: () => openCachedSourceFlow(titleContext),
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
      expect(providerResolveCount, 1);

      await tester.tap(find.byKey(const Key('play-Source A')));
      await tester.pumpAndSettle();
      expect(find.text('Player: Source A'), findsOneWidget);
      expect(find.text('Source picker'), findsNothing);

      await tester.tap(find.byKey(const Key('player-back')));
      await tester.pumpAndSettle();
      expect(find.text('Source picker'), findsOneWidget);
      expect(providerResolveCount, 1);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Source picker'), findsNothing);
      expect(find.text('Title details'), findsOneWidget);
      expect(providerResolveCount, 1);
    },
  );
}
