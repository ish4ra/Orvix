import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android TV remotes do not all emit the same logical key for the OK button.
bool isTvActivateKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA ||
    key == LogicalKeyboardKey.space;

/// Reliable "tap OK / hold OK" recognizer for DPAD remotes.
///
/// A held remote key produces KeyDown -> KeyRepeat* -> KeyUp. Pointer
/// onLongPress callbacks do not cover that path, so TV rows need a keyboard
/// state machine instead.
class TvHoldOk {
  TvHoldOk({
    required this.onTap,
    required this.onHold,
    this.dwell = const Duration(milliseconds: 600),
  });

  final VoidCallback onTap;
  final VoidCallback onHold;
  final Duration dwell;

  Timer? _timer;
  bool _sawDown = false;
  bool _holdFired = false;

  KeyEventResult handle(KeyEvent event) {
    if (!isTvActivateKey(event.logicalKey)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      if (_sawDown) return KeyEventResult.handled;
      _sawDown = true;
      _holdFired = false;
      _timer?.cancel();
      _timer = Timer(dwell, () {
        _timer = null;
        if (!_sawDown || _holdFired) return;
        _holdFired = true;
        onHold();
      });
      return KeyEventResult.handled;
    }

    if (event is KeyRepeatEvent) {
      // The long-press is ours. Do not let a repeated OK key activate a
      // newly-opened dialog button through Flutter's shortcut layer.
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      _timer?.cancel();
      _timer = null;
      final wasOurs = _sawDown;
      final held = _holdFired;
      _sawDown = false;
      _holdFired = false;
      if (wasOurs && !held) onTap();
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _sawDown = false;
    _holdFired = false;
  }
}

/// A dialog opened while OK is still physically held must swallow the repeat
/// tail, otherwise the first repeat can immediately activate its autofocus
/// button and make the long-press appear broken.
class TvHeldKeyGuard extends StatelessWidget {
  const TvHeldKeyGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyRepeatEvent && isTvActivateKey(event.logicalKey)) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
