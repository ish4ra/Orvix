import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/tv/tv_focus.dart';
import 'package:orvix/tv/tv_shell.dart';
import 'package:orvix/tv/tv_widgets.dart';
import 'package:orvix/widgets/orvix_update_gate.dart';
import 'package:orvix/widgets/update_check_section.dart';

const _update = AppUpdateInfo(
  tag: 'v0.7.10-beta.1',
  version: '0.7.10-beta.1',
  title: 'Orvix Internal 0.7.10-beta.1',
  notes: 'Private notes',
  releaseUrl: '',
  assetName: 'Orvix-v0.7.10-beta.1-Android-TV.apk',
  assetUrl: '',
  internalVersion: '0.7.10-beta.1',
);

/// Offers [_update] (or nothing) without touching the network.
class _FakeUpdates extends AppUpdateService {
  _FakeUpdates({this.offer = true})
      : super(installedVersionLoader: () async => '0.7.9');

  bool offer;
  int downloads = 0;

  @override
  Future<UpdateCheckReport> checkForUpdateReport() async => UpdateCheckReport(
        installedVersion: '0.7.9',
        update: offer ? _update : null,
        publicStatus: PublicUpdateStatus.upToDate,
        private: PrivateUpdateCheck(
          offer
              ? PrivateUpdateStatus.available
              : PrivateUpdateStatus.noNewerBuild,
          update: offer ? _update : null,
          draftsVisible: 1,
        ),
      );

  @override
  Future<File> download(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    downloads++;
    throw StateError('test download');
  }
}

const _destinations = [
  TvDestination(icon: Icons.home, selectedIcon: Icons.home, label: 'Home'),
  TvDestination(
      icon: Icons.settings, selectedIcon: Icons.settings, label: 'Settings'),
];

class _Host extends StatefulWidget {
  const _Host(this.updates);

  final _FakeUpdates updates;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: OrvixUpdateGate(
        service: widget.updates,
        child: TvShell(
          destinations: _destinations,
          selectedIndex: index,
          onSelected: (value) => setState(() => index = value),
          screenBuilder: (context, i) => i == 0
              ? ListView(
                  padding: const EdgeInsets.all(30),
                  children: [
                    Row(children: [
                      TvButton(
                        key: const ValueKey('Home-a'),
                        label: 'Home A',
                        onPressed: () {},
                      ),
                    ]),
                    const SizedBox(height: 16),
                    TvButton(
                      key: const ValueKey('Home-b'),
                      label: 'Home B',
                      onPressed: () {},
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(30),
                  children: const [TvUpdateCheckSection()],
                ),
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

Future<void> _start(WidgetTester tester, _FakeUpdates updates) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_Host(updates));
  // The gate checks shortly after start.
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => PlatformProfile.debugAndroidTvOverride = true);
  tearDown(() {
    PlatformProfile.debugAndroidTvOverride = null;
    TvTopTarget.node.value = null;
  });

  testWidgets('Up at the top of a destination reaches the update banner',
      (tester) async {
    await _start(tester, _FakeUpdates());

    expect(find.byKey(const ValueKey('tv-update-banner')), findsOneWidget);
    expect(_focused(tester, 'Home-a'), isTrue,
        reason: 'The banner never steals focus when it appears.');

    // Up inside the destination still moves inside it first.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Home-b'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'Home-a'), isTrue);

    // At the top edge Up goes to the banner's Update button.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'tv-update-install'), isTrue);

    // Left/Right move between the banner actions and stop at its ends.
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'tv-update-notes'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'tv-update-later'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'tv-update-later'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'tv-update-later'), isTrue);

    // Down returns to where the user was.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Home-a'), isTrue);
  });

  testWidgets('Up from the first menu item reaches the banner; Back returns',
      (tester) async {
    await _start(tester, _FakeUpdates());

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(tester, 'tv-nav-Home'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'tv-update-install'), isTrue);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(_focused(tester, 'Home-a'), isTrue);
    expect(find.byType(TvShell), findsOneWidget,
        reason: 'Back on the banner must not leave Orvix.');
  });

  testWidgets('OK on Update starts the download; failures are shown',
      (tester) async {
    final updates = _FakeUpdates();
    await _start(tester, updates);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'tv-update-install'), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    expect(updates.downloads, 1);
    expect(find.textContaining('Update failed'), findsOneWidget);
    // Focus stays on the banner instead of disappearing.
    expect(_focused(tester, 'tv-update-install'), isTrue);
  });

  testWidgets("What's new opens with Update focused and Back closes it",
      (tester) async {
    await _start(tester, _FakeUpdates());

    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.text('Private notes'), findsOneWidget);
    expect(_focused(tester, 'tv-update-notes-install'), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, 'tv-update-notes-close'), isTrue);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.text('Private notes'), findsNothing);
    expect(_focused(tester, 'tv-update-notes'), isTrue);
  });

  testWidgets('Later hides the banner and hands focus back', (tester) async {
    await _start(tester, _FakeUpdates());

    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('tv-update-banner')), findsNothing);
    expect(_focused(tester, 'Home-a'), isTrue);

    // Without a banner, Up at the top keeps its old behaviour.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, 'Home-a'), isTrue);
  });

  testWidgets('Settings check for updates is reachable and offers install',
      (tester) async {
    final updates = _FakeUpdates(offer: false);
    await _start(tester, updates);
    expect(find.byKey(const ValueKey('tv-update-banner')), findsNothing);

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_focused(tester, 'tv-settings-check-updates'), isTrue);

    await _press(tester, LogicalKeyboardKey.select);
    expect(find.text('Orvix is up to date'), findsOneWidget);
    expect(find.text('Private channel: no newer test build.'), findsOneWidget);

    updates.offer = true;
    await _press(tester, LogicalKeyboardKey.select);
    expect(
      find.descendant(
        of: find.byType(TvUpdateCheckSection),
        matching: find.text('Orvix 0.7.10-beta.1 is available'),
      ),
      findsOneWidget,
    );
    // The same update is now offered in the banner too.
    expect(find.byKey(const ValueKey('tv-update-banner')), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'tv-settings-install-update'), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    expect(updates.downloads, 1);
  });
}
