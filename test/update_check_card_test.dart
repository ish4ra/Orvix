import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/services/update_prompt_policy.dart';
import 'package:orvix/widgets/orvix_update_gate.dart';
import 'package:orvix/widgets/update_check_section.dart';

import 'support/fake_github.dart';

AppUpdateService _updates(FakeGitHub github, UpdateTarget target) =>
    AppUpdateService(
      client: github.client(),
      installedVersionLoader: () async => '0.7.10-beta.3',
      platformLoader: () async => UpdatePlatform(target),
    );

Future<void> _start(
  WidgetTester tester,
  FakeGitHub github, {
  UpdateTarget target = UpdateTarget.androidMobile,
  MemoryUpdatePromptStore? store,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: OrvixUpdateGate(
      service: _updates(github, target),
      promptPolicy: UpdatePromptPolicy(store: store ?? MemoryUpdatePromptStore()),
      child: const Scaffold(
        body: SingleChildScrollView(child: UpdateCheckCard()),
      ),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phones: a stable release shows the banner; Later remembers it',
      (tester) async {
    final store = MemoryUpdatePromptStore();
    await _start(tester, FakeGitHub([
      [release('v0.7.10')]
    ]), store: store);
    expect(find.text('Orvix 0.7.10 is available'), findsOneWidget);
    await tester.tap(find.byTooltip('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Orvix 0.7.10 is available'), findsNothing);
    expect(store.value?.version, '0.7.10');
  });

  testWidgets('phones: a beta never shows the automatic banner',
      (tester) async {
    await _start(tester, FakeGitHub([
      [release('v0.7.10-beta.4')]
    ]));
    expect(find.textContaining('is available'), findsNothing);
  });

  testWidgets('Settings finds a beta, labels it and shows its notes',
      (tester) async {
    await _start(tester, FakeGitHub([
      [release('v0.7.10-beta.4', notes: 'Beta notes')]
    ]));
    await tester.tap(find.byKey(const ValueKey('settings-check-updates')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(UpdateCheckCard),
        matching: find.text('Orvix 0.7.10-beta.4 (beta) is available'),
      ),
      findsOneWidget,
    );
    expect(find.text('Install beta'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-update-notes')));
    await tester.pumpAndSettle();
    expect(find.text('Beta notes'), findsOneWidget);
  });

  testWidgets('Settings explains a failed check instead of "up to date"',
      (tester) async {
    await _start(tester, FakeGitHub([const []])..offline = true);
    await tester.tap(find.byKey(const ValueKey('settings-check-updates')));
    await tester.pumpAndSettle();
    expect(find.text('Could not check for updates'), findsOneWidget);
    expect(find.text('Orvix is up to date'), findsNothing);
    expect(find.byKey(const ValueKey('settings-install-update')), findsNothing);
  });

  testWidgets('iOS: no banner, and Settings offers the release page',
      (tester) async {
    await _start(
      tester,
      FakeGitHub([
        [release('v0.7.11')]
      ]),
      target: UpdateTarget.ios,
    );
    expect(find.textContaining('is available'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-check-updates')));
    await tester.pumpAndSettle();
    expect(find.text('Open release page'), findsOneWidget);
    // The update is not pushed into an install banner on iOS.
    expect(find.byTooltip('Later'), findsNothing);
  });
}
