import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// The window operations the player's fullscreen flow needs.
///
/// Kept as a tiny seam so the state handling below can be tested without a
/// native window.
abstract class DesktopWindowOps {
  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool value);
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
}

class WindowManagerWindowOps implements DesktopWindowOps {
  const WindowManagerWindowOps();

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> setFullScreen(bool value) => windowManager.setFullScreen(value);

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();
}

/// Desktop player fullscreen with the window state restored on exit.
///
/// window_manager 0.5.2 on Windows only removes the caption and uses the full
/// monitor rect when the window is *not* maximized. From a maximized window it
/// keeps the title bar and the maximized work-area bounds, so the taskbar
/// stays visible. Its `unmaximize` only posts SC_RESTORE, so the restore has
/// to be observed before fullscreen is requested. The maximized state is put
/// back after fullscreen is left.
///
/// Every operation runs in order on one queue, so repeated F/F11/button
/// presses always act on the real state left by the previous press.
class DesktopFullscreenService {
  DesktopFullscreenService({
    DesktopWindowOps ops = const WindowManagerWindowOps(),
    bool? restoreMaximizeBeforeFullScreen,
    Duration restorePollInterval = const Duration(milliseconds: 20),
    int restorePollAttempts = 30,
  })  : _ops = ops,
        _restoreMaximizeBeforeFullScreen =
            restoreMaximizeBeforeFullScreen ?? Platform.isWindows,
        _restorePollInterval = restorePollInterval,
        _restorePollAttempts = restorePollAttempts;

  static DesktopFullscreenService instance = DesktopFullscreenService();

  final DesktopWindowOps _ops;
  final bool _restoreMaximizeBeforeFullScreen;
  final Duration _restorePollInterval;
  final int _restorePollAttempts;

  bool _maximizeOnExit = false;
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<bool> isFullScreen() => _ops.isFullScreen();

  /// F, F11 and the fullscreen button.
  Future<void> toggle() => _serial(() async {
        if (await _ops.isFullScreen()) {
          await _leave();
        } else {
          await _enter();
        }
      });

  /// Leaves fullscreen if it is active. Returns whether it was active.
  Future<bool> exitFullScreen() => _serial(() async {
        if (!await _ops.isFullScreen()) return false;
        await _leave();
        return true;
      });

  Future<void> _enter() async {
    _maximizeOnExit = false;
    if (_restoreMaximizeBeforeFullScreen && await _ops.isMaximized()) {
      await _ops.unmaximize();
      var restored = false;
      for (var attempt = 0; attempt < _restorePollAttempts; attempt++) {
        if (!await _ops.isMaximized()) {
          restored = true;
          break;
        }
        await Future<void>.delayed(_restorePollInterval);
      }
      // If the restore never landed, window_manager's own maximized path
      // re-maximizes on exit, so do not maximize a second time.
      _maximizeOnExit = restored;
    }
    await _ops.setFullScreen(true);
  }

  Future<void> _leave() async {
    await _ops.setFullScreen(false);
    if (_maximizeOnExit) {
      _maximizeOnExit = false;
      await _ops.maximize();
    }
  }
}
