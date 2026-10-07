import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/playback_preparation.dart';

void main() {
  group('PlaybackPreparationController', () {
    test('normal preparation completes and reports success', () async {
      final controller = PlaybackPreparationController();
      var ran = false;
      final done = controller.run(() async {
        expect(controller.isPreparing, isTrue);
        expect(PlaybackPreparation.current, isNotNull);
        ran = true;
      });
      expect(await done, isTrue);
      expect(ran, isTrue);
      expect(controller.isPreparing, isFalse);
    });

    test('cancel returns at once; late completion never opens the player',
        () async {
      final controller = PlaybackPreparationController();
      final resolve = Completer<String>();
      var playerOpened = false;

      final done = controller.run(() async {
        await resolve.future;
        // Same checkpoint Details runs right before pushing a player route.
        PlaybackPreparation.throwIfCurrentCancelled();
        playerOpened = true;
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.cancelActive(), isTrue);
      expect(await done, isFalse);
      expect(controller.isPreparing, isFalse);

      resolve.complete('http://127.0.0.1:11470/late/0');
      await Future<void>.delayed(Duration.zero);
      expect(playerOpened, isFalse);
    });

    test('a late error from cancelled work is ignored', () async {
      final controller = PlaybackPreparationController();
      final resolve = Completer<void>();
      final done = controller.run(() => resolve.future);
      await Future<void>.delayed(Duration.zero);
      controller.cancelActive();
      expect(await done, isFalse);
      resolve.completeError(StateError('engine went away'));
      // No unhandled error reaches the test zone.
      await Future<void>.delayed(Duration.zero);
    });

    test('errors of a live preparation still reach the caller', () async {
      final controller = PlaybackPreparationController();
      await expectLater(
        controller.run(() async => throw StateError('no peers')),
        throwsStateError,
      );
      expect(controller.isPreparing, isFalse);
    });

    test('a newer preparation is not affected by an older cancelled one',
        () async {
      final controller = PlaybackPreparationController();
      final first = Completer<void>();
      PlaybackPreparation? older;
      final firstDone = controller.run(() async {
        older = PlaybackPreparation.current;
        await first.future;
      });
      await Future<void>.delayed(Duration.zero);
      controller.cancelActive();
      await firstDone;

      final second = Completer<void>();
      PlaybackPreparation? newer;
      final secondDone = controller.run(() async {
        newer = PlaybackPreparation.current;
        await second.future;
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.isLatest(older!), isFalse);
      expect(controller.isLatest(newer!), isTrue);
      expect(newer!.isCancelled, isFalse);

      first.complete();
      second.complete();
      expect(await secondDone, isTrue);
    });

    test('cancelActive with nothing preparing is a no-op', () {
      expect(PlaybackPreparationController().cancelActive(), isFalse);
      expect(PlaybackPreparation.current, isNull);
      PlaybackPreparation.throwIfCurrentCancelled();
    });
  });

  group('source list -> preparing -> player navigation', () {
    late PlaybackPreparationController controller;
    late Completer<String> resolve;
    late int providerFetches;

    Widget title() => Builder(
          builder: (titleContext) => StatefulBuilder(
            builder: (context, setState) => PopScope(
              canPop: !controller.isPreparing,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) controller.cancelActive();
              },
              child: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Title details'),
                      if (controller.isPreparing) const Text('Preparing…'),
                      FilledButton(
                        onPressed: () async {
                          providerFetches++;
                          const cachedSources = ['Source A', 'Source B'];
                          await runSourcePlaybackLoop<String>(
                            controller: controller,
                            isActive: () => titleContext.mounted,
                            onPreparationChanged: () {
                              if (titleContext.mounted) setState(() {});
                            },
                            onError: (_) {},
                            chooseSource: () => showModalBottomSheet<String>(
                              context: titleContext,
                              builder: (sheetContext) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Source list'),
                                  for (final source in cachedSources)
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(sheetContext, source),
                                      child: Text(source),
                                    ),
                                ],
                              ),
                            ),
                            prepareAndPlay: (source) async {
                              await resolve.future;
                              PlaybackPreparation.throwIfCurrentCancelled();
                              if (!titleContext.mounted) return;
                              await Navigator.of(titleContext).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => Scaffold(
                                    body: Text('Player: $source'),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                        child: const Text('Find Sources'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    Future<void> pumpApp(WidgetTester tester) async {
      controller = PlaybackPreparationController();
      resolve = Completer<String>();
      providerFetches = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (homeContext) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(homeContext).push(
                MaterialPageRoute<void>(builder: (_) => title()),
              ),
              child: const Text('Home'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Source A'));
      await tester.pumpAndSettle();
      expect(find.text('Preparing…'), findsOneWidget);
    }

    testWidgets('normal preparation opens the player; player Back returns '
        'to the source list, then the title', (tester) async {
      await pumpApp(tester);

      resolve.complete('http://127.0.0.1:11470/ok/0');
      await tester.pumpAndSettle();
      expect(find.text('Player: Source A'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Player: Source A'), findsNothing);
      expect(find.text('Source list'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Source list'), findsNothing);
      expect(find.text('Title details'), findsOneWidget);
      expect(providerFetches, 1);
    });

    testWidgets('Back while preparing returns to the source list; a late '
        'resolve never opens the player', (tester) async {
      await pumpApp(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Title details'), findsOneWidget);
      expect(find.text('Source list'), findsOneWidget);
      expect(find.text('Preparing…'), findsNothing);

      resolve.complete('http://127.0.0.1:11470/late/0');
      await tester.pumpAndSettle();
      expect(find.textContaining('Player:'), findsNothing);
      expect(find.text('Source list'), findsOneWidget);
      expect(providerFetches, 1);
    });
  });
}
