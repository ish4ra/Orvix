import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/desktop_fullscreen_service.dart';
import 'package:orvix/services/player_exit_controller.dart';

/// Mimics window_manager on Windows: `unmaximize` only posts SC_RESTORE, so
/// the window is still maximized for a moment after the call returns.
class _FakeWindow implements DesktopWindowOps {
  _FakeWindow({this.maximized = false, this.restoreDelayPolls = 2});

  bool fullScreen = false;
  bool maximized;
  int restoreDelayPolls;
  bool restoreNeverLands = false;
  bool? maximizedWhenFullScreenRequested;
  final List<String> calls = <String>[];
  int _pendingRestorePolls = -1;

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<bool> isMaximized() async {
    if (_pendingRestorePolls >= 0) {
      if (_pendingRestorePolls == 0 && !restoreNeverLands) {
        maximized = false;
        _pendingRestorePolls = -1;
      } else if (_pendingRestorePolls > 0) {
        _pendingRestorePolls--;
      }
    }
    return maximized;
  }

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
    _pendingRestorePolls = restoreDelayPolls;
  }

  @override
  Future<void> setFullScreen(bool value) async {
    calls.add('setFullScreen($value)');
    if (value) maximizedWhenFullScreenRequested = maximized;
    fullScreen = value;
  }
}

DesktopFullscreenService _service(_FakeWindow window, {bool windows = true}) {
  return DesktopFullscreenService(
    ops: window,
    restoreMaximizeBeforeFullScreen: windows,
    restorePollInterval: Duration.zero,
  );
}

class _Harness {
  _Harness({
    this.desktop = true,
    bool fullScreen = false,
    bool maximized = false,
    this.mounted = true,
  }) : window = _FakeWindow(maximized: maximized) {
    window.fullScreen = fullScreen;
    fs = _service(window);
    controller = PlayerExitController(
      teardown: () {
        teardowns++;
        events.add('teardown-start');
        return teardownGate.future.then((_) {
          if (teardownError != null) throw teardownError!;
          events.add('teardown-done');
        });
      },
      popRoute: () {
        events.add('pop');
        if (!mounted) return false;
        pops++;
        return true;
      },
      desktop: desktop,
      fullscreen: fs,
      trace: traces.add,
    );
  }

  final bool desktop;
  bool mounted;
  final _FakeWindow window;
  late final DesktopFullscreenService fs;
  late final PlayerExitController controller;
  final Completer<void> teardownGate = Completer<void>();
  Object? teardownError;
  int teardowns = 0;
  int pops = 0;
  final List<String> events = <String>[];
  final List<String> traces = <String>[];

  void finishTeardown() {
    if (!teardownGate.isCompleted) teardownGate.complete();
  }
}

void main() {
  group('desktop fullscreen', () {
    test('windowed -> fullscreen -> windowed restores without maximizing',
        () async {
      final window = _FakeWindow();
      final fs = _service(window);

      await fs.toggle();
      expect(window.fullScreen, isTrue);
      await fs.toggle();
      expect(window.fullScreen, isFalse);
      expect(window.maximized, isFalse);
      expect(window.calls, ['setFullScreen(true)', 'setFullScreen(false)']);
    });

    test('maximized window is restored before true fullscreen and '
        'maximized again afterwards (Windows)', () async {
      final window = _FakeWindow(maximized: true, restoreDelayPolls: 3);
      final fs = _service(window);

      await fs.toggle();
      expect(window.fullScreen, isTrue);
      // window_manager only drops the caption and uses the monitor rect for a
      // non-maximized window. The restore must have landed first.
      expect(window.maximizedWhenFullScreenRequested, isFalse);

      expect(await fs.exitFullScreen(), isTrue);
      expect(window.fullScreen, isFalse);
      expect(window.maximized, isTrue);
      expect(window.calls, [
        'unmaximize',
        'setFullScreen(true)',
        'setFullScreen(false)',
        'maximize',
      ]);
    });

    test('a restore that never lands does not maximize twice on exit',
        () async {
      final window = _FakeWindow(maximized: true)..restoreNeverLands = true;
      final fs = DesktopFullscreenService(
        ops: window,
        restoreMaximizeBeforeFullScreen: true,
        restorePollInterval: Duration.zero,
        restorePollAttempts: 4,
      );

      await fs.toggle();
      expect(window.fullScreen, isTrue);
      await fs.toggle();
      expect(window.calls, [
        'unmaximize',
        'setFullScreen(true)',
        'setFullScreen(false)',
      ]);
    });

    test('macOS/Linux keep the direct window_manager fullscreen call',
        () async {
      final window = _FakeWindow(maximized: true);
      final fs = _service(window, windows: false);

      await fs.toggle();
      await fs.toggle();
      expect(window.calls, ['setFullScreen(true)', 'setFullScreen(false)']);
      expect(window.maximized, isTrue);
    });

    test('repeated toggles run in order on the real state', () async {
      final window = _FakeWindow(maximized: true);
      final fs = _service(window);

      final first = fs.toggle();
      final second = fs.toggle();
      final third = fs.toggle();
      await Future.wait([first, second, third]);

      expect(window.fullScreen, isTrue);
      expect(window.calls, [
        'unmaximize',
        'setFullScreen(true)',
        'setFullScreen(false)',
        'maximize',
        'unmaximize',
        'setFullScreen(true)',
      ]);
    });

    test('exitFullScreen is a no-op while windowed', () async {
      final window = _FakeWindow();
      final fs = _service(window);

      expect(await fs.exitFullScreen(), isFalse);
      expect(window.calls, isEmpty);
    });
  });

  group('player exit', () {
    test('visible Back while fullscreen leaves fullscreen and the player in '
        'one action', () async {
      final h = _Harness(fullScreen: true, maximized: false);

      final back = h.controller.leave(PlayerExitIntent.backButton);
      await pumpEventQueue();
      expect(h.teardowns, 1);
      expect(h.pops, 0, reason: 'never pop before the native stop finished');

      h.finishTeardown();
      expect(await back, isTrue);
      expect(h.window.fullScreen, isFalse);
      expect(h.pops, 1);
      // Native stop first, then the window restore, then the route pop.
      expect(h.events, ['teardown-start', 'teardown-done', 'pop']);
      expect(h.window.calls, ['setFullScreen(false)']);
    });

    test('visible Back from a maximized fullscreen restores maximized',
        () async {
      final h = _Harness(maximized: true);
      await h.fs.toggle();
      expect(h.window.fullScreen, isTrue);
      expect(h.window.maximized, isFalse);

      h.finishTeardown();
      expect(await h.controller.leave(PlayerExitIntent.backButton), isTrue);
      expect(h.window.fullScreen, isFalse);
      expect(h.window.maximized, isTrue);
      expect(h.pops, 1);
    });

    test('Escape while fullscreen only leaves fullscreen and stays in player',
        () async {
      final h = _Harness(fullScreen: true);

      expect(await h.controller.escape(), isFalse);
      expect(h.window.fullScreen, isFalse);
      expect(h.teardowns, 0);
      expect(h.pops, 0);
      expect(h.controller.exiting, isFalse);
    });

    test('second Escape while windowed leaves the player', () async {
      final h = _Harness(fullScreen: true)..finishTeardown();

      await h.controller.escape();
      expect(h.pops, 0);
      expect(await h.controller.escape(), isTrue);
      expect(h.teardowns, 1);
      expect(h.pops, 1);
    });

    test('duplicated Escape delivery while leaving fullscreen is dropped',
        () async {
      final h = _Harness(fullScreen: true)..finishTeardown();

      final first = h.controller.escape();
      final duplicate = h.controller.escape();
      expect(await first, isFalse);
      expect(await duplicate, isFalse);
      expect(h.teardowns, 0);
      expect(h.pops, 0);
    });

    test('failed-playback Back works with one click (windowed)', () async {
      final h = _Harness()..finishTeardown();

      expect(await h.controller.leave(PlayerExitIntent.backButton), isTrue);
      expect(h.teardowns, 1);
      expect(h.pops, 1);
      expect(h.window.calls, isEmpty);
    });

    test('repeated Back presses share one teardown and pop once', () async {
      final h = _Harness();

      final presses = [
        h.controller.leave(PlayerExitIntent.backButton),
        h.controller.leave(PlayerExitIntent.backButton),
        h.controller.leave(PlayerExitIntent.backButton),
      ];
      h.finishTeardown();
      final results = await Future.wait(presses);

      expect(results.where((popped) => popped), hasLength(1));
      expect(h.teardowns, 1);
      expect(h.pops, 1);
    });

    test('every exit path during a pending teardown shares it', () async {
      // A teardown that cannot finish yet is what Back sees while libmpv is
      // still opening a slow source (stop queues behind the open).
      final h = _Harness();

      final back = h.controller.leave(PlayerExitIntent.backButton);
      final escape = h.controller.escape();
      final system = h.controller.allowSystemPop();
      final next = h.controller.leave(PlayerExitIntent.nextEpisode);
      final fallback = h.controller.leave(PlayerExitIntent.startupFallback);
      final shared = h.controller.prepareExit();
      await pumpEventQueue();
      expect(h.pops, 0);

      h.finishTeardown();
      await shared;
      expect(await back, isTrue);
      expect(await escape, isFalse);
      expect(await system, isFalse);
      expect(await next, isFalse);
      expect(await fallback, isFalse);
      expect(h.teardowns, 1);
      expect(h.pops, 1);
      expect(h.controller.intent, PlayerExitIntent.backButton);
    });

    test('next episode cannot run once Back started', () async {
      final h = _Harness()..finishTeardown();

      await h.controller.leave(PlayerExitIntent.backButton);
      expect(await h.controller.leave(PlayerExitIntent.nextEpisode), isFalse);
      expect(h.pops, 1);
    });

    test('Back is ignored once next episode owns the exit', () async {
      final h = _Harness(fullScreen: true)..finishTeardown();

      expect(await h.controller.leave(PlayerExitIntent.nextEpisode), isTrue);
      expect(await h.controller.leave(PlayerExitIntent.backButton), isFalse);
      expect(h.pops, 1);
      // Next episode keeps the window fullscreen for the next player.
      expect(h.window.fullScreen, isTrue);
    });

    test('a failing teardown still closes the route once', () async {
      final h = _Harness()
        ..teardownError = StateError('stop failed')
        ..finishTeardown();

      expect(await h.controller.leave(PlayerExitIntent.backButton), isTrue);
      expect(await h.controller.leave(PlayerExitIntent.backButton), isFalse);
      expect(h.pops, 1);
      expect(h.traces, contains('exit-teardown-error type=StateError'));
    });

    test('a route that is already gone is never popped again', () async {
      final h = _Harness(mounted: false)..finishTeardown();

      expect(await h.controller.leave(PlayerExitIntent.backButton), isFalse);
      expect(await h.controller.leave(PlayerExitIntent.backButton), isFalse);
      expect(h.events.where((e) => e == 'pop'), hasLength(1));
      expect(h.pops, 0);
    });

    test('Android Mobile/TV: Back and hardware back never touch the window',
        () async {
      final h = _Harness(desktop: false, fullScreen: true)..finishTeardown();

      expect(await h.controller.allowSystemPop(), isTrue);
      expect(await h.controller.allowSystemPop(), isFalse);
      expect(await h.controller.leave(PlayerExitIntent.backButton), isFalse);
      expect(h.teardowns, 1);
      expect(h.window.calls, isEmpty);
      // The route pops itself for a system back.
      expect(h.pops, 0);
    });

    test('Android Back button keeps teardown-then-pop', () async {
      final h = _Harness(desktop: false)..finishTeardown();

      expect(await h.controller.escape(), isTrue);
      expect(h.events, ['teardown-start', 'teardown-done', 'pop']);
      expect(h.window.calls, isEmpty);
    });
  });

  group('player screen wiring', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    test('visible Back buttons and Escape are separate intents', () {
      expect(player, isNot(contains('_handleEscape,')));
      expect(
        RegExp(r'onPressed: _handleBackButton,').allMatches(player),
        hasLength(4),
      );
      expect(player, contains('await _exit.leave(PlayerExitIntent.backButton);'));
      expect(player, contains('_handleEscapeKey();'));
      expect(player, contains('await _exit.escape();'));
      expect(player, contains('return _exit.allowSystemPop();'));
    });

    test('F, F11 and the fullscreen button share one fullscreen path', () {
      expect(
        player,
        contains(
          'key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11',
        ),
      );
      expect(player, contains('await DesktopFullscreenService.instance.toggle();'));
      expect(player, isNot(contains('windowManager.setFullScreen')));
    });

    test('failure card sits above the controls overlay off Android TV', () {
      final controls = player.indexOf('child: _controls(context),');
      final card = player.indexOf(
        'if (_error != null && !PlatformProfile.isAndroidTv)\n'
        '                  _errorView(context),',
      );
      expect(controls, greaterThan(0));
      expect(card, greaterThan(controls));
      // Android TV keeps its focus-driven layout unchanged.
      final tvCard = player.indexOf(
        'if (_error != null && PlatformProfile.isAndroidTv)\n'
        '                  _errorView(context),',
      );
      expect(tvCard, inInclusiveRange(1, controls));
    });

    test('startup work stops once the exit begins', () {
      expect(player, contains('isCancelled: () => _closing,'));
      expect(player, contains("_traceExit('open-returned-after-exit');"));
      expect(player, contains("_traceExit('open-error-after-exit"));
      final open = player.substring(
        player.indexOf('Future<void> _open() async {'),
        player.indexOf('void _onPlaybackError(String message) {'),
      );
      final play = open.indexOf('await widget.playback.player.play();');
      final seek = open.indexOf('await widget.playback.player.seek(resume);');
      final timer = open.indexOf('_startupTimer = Timer(');
      for (final index in [play, seek, timer]) {
        expect(index, greaterThan(0));
        expect(
          open.substring(0, index).lastIndexOf('if (_closing) return;'),
          greaterThan(open.indexOf('isCancelled: () => _closing,')),
        );
      }

      expect(playback, contains('bool Function()? isCancelled,'));
      final cancelled =
          playback.indexOf('if (isCancelled?.call() == true) return;');
      expect(cancelled, greaterThan(0));
      expect(playback.indexOf('await player.open('), greaterThan(cancelled));
    });

    test('next episode and late callbacks are gated by the exit', () {
      expect(
        player,
        contains('if (onNext == null || _advancing || _exit.exiting) return;'),
      );
      expect(
        player,
        contains('if (!await _exit.leave(PlayerExitIntent.nextEpisode)) return;'),
      );
      expect(player, contains('if (_closing || _playbackStarted || _failureReported) return false;'));
      expect(player, contains('if (_closing ||\n        _preflightWarmup ||\n        _aiSubtitleLoading'));
      // Timeout still guards non-P2P streams, but local Android torrents
      // must not fail merely for taking longer than 30 seconds.
      expect(player, contains('if (!waitingForLocalP2p) {'));
      expect(player, contains('if (!mounted || _closing) return;'));
      expect(player, contains('if (_hasPlaybackActivity())'));
      expect(player, contains('if (!_exitPrepared && !_exit.teardownStarted) {'));
    });
  });
}
