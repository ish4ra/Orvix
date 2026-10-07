import 'dart:async';

import 'desktop_fullscreen_service.dart';

/// Why the player is being left. Only the visible Back button and keyboard
/// Escape differ in how they treat desktop fullscreen.
enum PlayerExitIntent {
  /// Visible Back button: one action leaves fullscreen and the player.
  backButton,

  /// Keyboard Escape: leaves fullscreen first, then the player on the next
  /// press.
  escapeKey,

  /// Hardware/system back handled by the route itself.
  systemBack,

  /// Next episode: the window keeps its fullscreen state for the next player.
  nextEpisode,

  /// Startup engine fallback (Android MPV to ExoPlayer).
  startupFallback,
}

/// Owns the player's single logical exit.
///
/// However many Back/Escape/next/fallback requests arrive, and in whatever
/// order, one exit runs the teardown once and pops the route at most once.
/// Requests that arrive after the exit started are ignored.
class PlayerExitController {
  PlayerExitController({
    required Future<void> Function() teardown,
    required bool Function() popRoute,
    required bool desktop,
    DesktopFullscreenService? fullscreen,
    void Function(String event)? trace,
  })  : _teardown = teardown,
        _popRoute = popRoute,
        _desktop = desktop,
        _fullscreen = fullscreen,
        _trace = trace;

  final Future<void> Function() _teardown;
  final bool Function() _popRoute;
  final bool _desktop;
  final DesktopFullscreenService? _fullscreen;
  final void Function(String event)? _trace;

  Future<void>? _teardownFuture;
  PlayerExitIntent? _intent;
  bool _popped = false;
  bool _escapeInFlight = false;

  /// True once any exit has claimed the route.
  bool get exiting => _intent != null;
  bool get teardownStarted => _teardownFuture != null;
  PlayerExitIntent? get intent => _intent;

  DesktopFullscreenService get _fs =>
      _fullscreen ?? DesktopFullscreenService.instance;

  /// Runs the player teardown once; later callers share the same future.
  Future<void> prepareExit() {
    return _teardownFuture ??= _teardown();
  }

  /// Visible Back button, next episode and startup fallback. Returns whether
  /// this call performed the route pop.
  Future<bool> leave(PlayerExitIntent intent) async {
    if (exiting) return false;
    _intent = intent;
    _trace?.call('exit-start intent=${intent.name}');
    // Teardown starts synchronously, so no player callback acts after this.
    await _awaitTeardown();
    // Restore the window only after libmpv has stopped, so the window resize
    // never overlaps the native stop, and before the pop, so the previous
    // screen appears in the restored window.
    if (_desktop &&
        (intent == PlayerExitIntent.backButton ||
            intent == PlayerExitIntent.escapeKey)) {
      await _leaveFullScreen();
    }
    return _popOnce();
  }

  /// Keyboard Escape: in fullscreen it only leaves fullscreen, otherwise it
  /// leaves the player. Returns whether this call performed the route pop.
  Future<bool> escape() async {
    if (exiting || _escapeInFlight) return false;
    if (_desktop) {
      _escapeInFlight = true;
      try {
        final leftFullScreen = await _fs.exitFullScreen();
        if (leftFullScreen) {
          _trace?.call('escape-left-fullscreen');
          return false;
        }
      } catch (error) {
        _trace?.call('fullscreen-exit-error type=${error.runtimeType}');
      } finally {
        _escapeInFlight = false;
      }
    }
    return leave(PlayerExitIntent.escapeKey);
  }

  /// Hardware/system back. The route pops itself when this returns true.
  Future<bool> allowSystemPop() async {
    if (exiting) return false;
    _intent = PlayerExitIntent.systemBack;
    _trace?.call('exit-start intent=systemBack');
    await _awaitTeardown();
    if (_desktop) await _leaveFullScreen();
    _popped = true;
    return true;
  }

  Future<void> _awaitTeardown() async {
    try {
      await prepareExit();
    } catch (error) {
      // The route must still close; report it instead of leaving Back dead.
      _trace?.call('exit-teardown-error type=${error.runtimeType}');
    }
  }

  Future<void> _leaveFullScreen() async {
    try {
      await _fs.exitFullScreen();
    } catch (error) {
      _trace?.call('fullscreen-exit-error type=${error.runtimeType}');
    }
  }

  bool _popOnce() {
    if (_popped) return false;
    _popped = true;
    final popped = _popRoute();
    _trace?.call('exit-pop done=$popped');
    return popped;
  }
}
