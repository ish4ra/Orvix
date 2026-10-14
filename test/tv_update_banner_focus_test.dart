import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/update_prompt_policy.dart';
import 'package:orvix/tv/tv_focus.dart';
import 'package:orvix/tv/tv_shell.dart';
import 'package:orvix/tv/tv_widgets.dart';
import 'package:orvix/widgets/orvix_update_gate.dart';
import 'package:orvix/widgets/update_check_section.dart';

import 'support/fake_github.dart';

/// The real updater (discovery, eligibility, asset choice) against a fake
/// GitHub; only the download is replaced, so no file is written.
class _TvUpdates extends AppUpdateService {
  _TvUpdates(this.github, {String installed = '0.7.10-beta.3'})
      : super(
          client: github.client(),
          installedVersionLoader: () async => installed,
          platformLoader: () async =>
              const UpdatePlatform(UpdateTarget.androidTv),
        );

  final FakeGitHub github;
  int downloads = 0;

  /// When set, a download waits for it; otherwise it fails at once.
  Completer<void>? hold;
  void Function(double progress)? progress;

  @override
  Future<File> download(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    downloads++;
    final hold = this.hold;
    if (hold != null) {
      progress = onProgress;
      onProgress?.call(.4);
      await hold.future;
      if (isCancelled?.call() == true) throw StateError('cancelled');
    }
    throw const UpdateFailure('GitHub returned HTTP 503 for the download.');
  }
}

FakeGitHub _github(List<Map<String, Object?>> releases) =>
    FakeGitHub([releases]);

FakeGitHub _stable({String notes = 'Stable notes'}) => _github([
      release('v0.7.10', notes: notes),
      release('v0.7.10-beta.3'),
    ]);

const _destinations = [
  TvDestination(icon: Icons.home, selectedIcon: Icons.home, label: 'Home'),
  TvDestination(
      icon: Icons.settings, selectedIcon: Icons.settings, label: 'Settings'),
];

class _Host extends StatefulWidget {
  const _Host(this.updates, this.policy);

  final AppUpdateService updates;
  final UpdatePromptPolicy policy;

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
        promptPolicy: widget.policy,
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

/// For screens with a running spinner, which never settle.
Future<void> _pressBusy(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _focused(WidgetTester tester, String key) {
  final focus = tester.widget<Focus>(find
      .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Focus))
      .first);
  return focus.focusNode?.hasPrimaryFocus ?? false;
}

bool _notesFocused(WidgetTester tester) =>
    FocusManager.instance.primaryFocus?.context?.widget.key ==
    const ValueKey('tv-update-notes-text');

Finder get _banner => find.byKey(const ValueKey('tv-update-banner'));

Future<void> _start(
  WidgetTester tester,
  AppUpdateService updates, {
  UpdatePromptPolicy? policy,
  Size size = const Size(1920, 1080),
  double ratio = 2,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_Host(
    updates,
    policy ?? UpdatePromptPolicy(store: MemoryUpdatePromptStore()),
  ));
  // The gate checks shortly after start.
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Opens Settings from Home and focuses "Check for updates".
Future<void> _openSettings(WidgetTester tester) async {
  await _press(tester, LogicalKeyboardKey.arrowLeft);
  await _press(tester, LogicalKeyboardKey.arrowDown);
  await _press(tester, LogicalKeyboardKey.select);
  expect(_focused(tester, 'tv-settings-check-updates'), isTrue);
}

void main() {
  setUp(() => PlatformProfile.debugAndroidTvOverride = true);
  tearDown(() {
    PlatformProfile.debugAndroidTvOverride = null;
    TvTopTarget.node.value = null;
  });

  group('automatic stable prompt', () {
    for (final (size, ratio) in <(Size, double)>[
      (const Size(1920, 1080), 2),
      (const Size(1280, 720), 1),
      (const Size(3840, 2160), 3),
    ]) {
      testWidgets(
          'Up reaches the banner and Left/Right/Down work at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _start(tester, _TvUpdates(_stable()), size: size, ratio: ratio);

        expect(_banner, findsOneWidget);
        expect(find.text('Orvix 0.7.10 is available'), findsOneWidget);
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
        await _press(tester, LogicalKeyboardKey.arrowLeft);
        expect(_focused(tester, 'tv-update-install'), isTrue);
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
    }

    testWidgets('a public beta never shows the automatic banner',
        (tester) async {
      await _start(
          tester,
          _TvUpdates(_github([
            release('v0.7.10-beta.999'),
            release('v0.7.10-beta.4'),
          ])));
      expect(_banner, findsNothing);
      // Without a banner, Up at the top keeps its old behaviour.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester, 'Home-a'), isTrue);
    });

    testWidgets('a draft never shows the automatic banner', (tester) async {
      await _start(
          tester, _TvUpdates(_github([release('v0.7.11', draft: true)])));
      expect(_banner, findsNothing);
    });

    testWidgets('a failed check shows nothing and leaves focus alone',
        (tester) async {
      await _start(tester, _TvUpdates(FakeGitHub([rateLimited()])));
      expect(_banner, findsNothing);
      expect(_focused(tester, 'Home-a'), isTrue);
    });

    testWidgets('Up from the first menu item reaches the banner; Back returns',
        (tester) async {
      await _start(tester, _TvUpdates(_stable()));

      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(tester, 'tv-nav-Home'), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester, 'tv-update-install'), isTrue);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(_focused(tester, 'Home-a'), isTrue);
      expect(find.byType(TvShell), findsOneWidget,
          reason: 'Back on the banner must not leave Orvix.');
      // Play/Pause on the banner does nothing harmful.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(_focused(tester, 'tv-update-install'), isTrue);
    });
  });

  group('download from the banner', () {
    testWidgets('OK on Update starts the download; a failure is shown and '
        'Update can be retried', (tester) async {
      final updates = _TvUpdates(_stable());
      await _start(tester, updates);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester, 'tv-update-install'), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
      expect(updates.downloads, 1);
      expect(find.text('Update failed: GitHub returned HTTP 503 for the '
          'download.'), findsOneWidget);
      // Focus stays on the banner instead of disappearing.
      expect(_focused(tester, 'tv-update-install'), isTrue);

      await _press(tester, LogicalKeyboardKey.select);
      expect(updates.downloads, 2);
      expect(_focused(tester, 'tv-update-install'), isTrue);
    });

    testWidgets('while downloading, focus stays put and Cancel is reachable',
        (tester) async {
      final updates = _TvUpdates(_stable())..hold = Completer<void>();
      await _start(tester, updates);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _pressBusy(tester, LogicalKeyboardKey.select);
      expect(find.textContaining('Downloading Orvix 0.7.10'), findsOneWidget);
      expect(find.textContaining('40%'), findsOneWidget);
      expect(_focused(tester, 'tv-update-install'), isTrue,
          reason: 'Progress must not steal or drop focus.');

      updates.progress?.call(.7);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('70%'), findsOneWidget);
      expect(_focused(tester, 'tv-update-install'), isTrue);

      // Right skips nothing: the disabled notes button stays focusable.
      await _pressBusy(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, 'tv-update-notes'), isTrue);
      await _pressBusy(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, 'tv-update-later'), isTrue);
      expect(find.text('Cancel'), findsOneWidget);

      await _pressBusy(tester, LogicalKeyboardKey.select);
      updates.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Downloading'), findsNothing);
      expect(find.textContaining('Update failed'), findsNothing,
          reason: 'A cancelled download is not an error.');
      expect(_banner, findsOneWidget);
      expect(_focused(tester, 'tv-update-later'), isTrue);

      // Down still leaves the banner.
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester, 'Home-a'), isTrue);
    });
  });

  group('release notes', () {
    testWidgets("What's new opens with Update focused and Back closes it",
        (tester) async {
      await _start(tester, _TvUpdates(_stable()));

      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Stable notes'), findsOneWidget);
      expect(_focused(tester, 'tv-update-notes-install'), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, 'tv-update-notes-close'), isTrue);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(find.text('Stable notes'), findsNothing);
      expect(_focused(tester, 'tv-update-notes'), isTrue);
    });

    testWidgets('long notes scroll with the remote and Down returns to the '
        'buttons', (tester) async {
      final notes = List.generate(80, (i) => 'Change number $i').join('\n');
      await _start(tester, _TvUpdates(_stable(notes: notes)));

      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.select);
      expect(_focused(tester, 'tv-update-notes-install'), isTrue);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_notesFocused(tester), isTrue);
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('tv-update-notes-text')),
        matching: find.byType(Scrollable),
      );
      double offset() =>
          tester.state<ScrollableState>(scrollable).position.pixels;
      expect(offset(), 0);

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(offset(), greaterThan(0));
      expect(_notesFocused(tester), isTrue);

      // Keep pressing Down: the notes reach their end, then focus moves on.
      for (var i = 0; i < 40 && _notesFocused(tester); i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focused(tester, 'tv-update-notes-install'), isTrue);
      final max =
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent;
      expect(offset(), closeTo(max, 8));

      await _press(tester, LogicalKeyboardKey.escape);
      expect(find.byKey(const ValueKey('tv-update-notes-text')), findsNothing);
      expect(_focused(tester, 'tv-update-notes'), isTrue);
    });
  });

  group('Later and cooldown', () {
    testWidgets('Later hides the banner, hands focus back and is remembered',
        (tester) async {
      final store = MemoryUpdatePromptStore();
      final policy = UpdatePromptPolicy(store: store);
      await _start(tester, _TvUpdates(_stable()), policy: policy);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.select);
      expect(_banner, findsNothing);
      expect(_focused(tester, 'Home-a'), isTrue);
      expect(store.value?.version, '0.7.10');

      // Without a banner, Up at the top keeps its old behaviour.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester, 'Home-a'), isTrue);

      // A relaunch within the cooldown does not prompt again.
      await tester.pumpWidget(const SizedBox());
      TvTopTarget.node.value = null;
      await _start(tester, _TvUpdates(_stable()), policy: policy);
      expect(_banner, findsNothing);

      // A higher stable release prompts normally.
      await tester.pumpWidget(const SizedBox());
      await _start(
          tester,
          _TvUpdates(_github([release('v0.7.11'), release('v0.7.10')])),
          policy: policy);
      expect(_banner, findsOneWidget);
      expect(find.text('Orvix 0.7.11 is available'), findsOneWidget);
    });

    testWidgets('a manual check ignores the Later cooldown', (tester) async {
      final store = MemoryUpdatePromptStore()
        ..value = (version: '0.7.10', at: DateTime.now().toUtc());
      await _start(tester, _TvUpdates(_stable()),
          policy: UpdatePromptPolicy(store: store));
      expect(_banner, findsNothing);

      await _openSettings(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(
        find.descendant(
          of: find.byType(TvUpdateCheckSection),
          matching: find.text('Orvix 0.7.10 is available'),
        ),
        findsOneWidget,
      );
      expect(_banner, findsOneWidget);
    });
  });

  group('Settings manual check', () {
    testWidgets('no update: up to date, and focus stays on the tile',
        (tester) async {
      await _start(tester, _TvUpdates(_github([release('v0.7.10-beta.3')])));
      await _openSettings(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Orvix is up to date'), findsOneWidget);
      expect(_focused(tester, 'tv-settings-check-updates'), isTrue);
      expect(find.textContaining('rivate'), findsNothing);
      expect(find.textContaining('draft'), findsNothing);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester, 'tv-settings-check-updates'), isTrue,
          reason: 'Nothing to reach below; focus must not vanish.');
    });

    testWidgets('a failed check is explained and can be retried',
        (tester) async {
      final github = FakeGitHub([rateLimited()]);
      await _start(tester, _TvUpdates(github));
      await _openSettings(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text("GitHub's update limit was reached"), findsOneWidget);
      expect(find.text('Orvix is up to date'), findsNothing);
      expect(_focused(tester, 'tv-settings-check-updates'), isTrue);

      github.pages[0] = http.Response('[]', 200);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Orvix is up to date'), findsOneWidget);
    });

    testWidgets('a public beta is found, labelled, and every action is '
        'reachable', (tester) async {
      final updates =
          _TvUpdates(_github([release('v0.7.10-beta.4', notes: 'Beta notes')]));
      await _start(tester, updates);
      expect(_banner, findsNothing);

      await _openSettings(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(
        find.descendant(
          of: find.byType(TvUpdateCheckSection),
          matching: find.text('Orvix 0.7.10-beta.4 (beta) is available'),
        ),
        findsOneWidget,
      );
      // The found update is offered in the banner too.
      expect(_banner, findsOneWidget);

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester, 'tv-settings-install-update'), isTrue);
      expect(find.text('Install beta'), findsOneWidget);

      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, 'tv-settings-update-notes'), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Beta notes'), findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      expect(find.text('Beta notes'), findsNothing);
      expect(_focused(tester, 'tv-settings-update-notes'), isTrue,
          reason: 'Back restores focus to the button that opened the notes.');

      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(tester, 'tv-settings-install-update'), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
      expect(updates.downloads, 1);
      expect(find.textContaining('Update failed'), findsOneWidget);
      expect(_focused(tester, 'tv-settings-install-update'), isTrue);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester, 'tv-settings-check-updates'), isTrue);
    });
  });
}
