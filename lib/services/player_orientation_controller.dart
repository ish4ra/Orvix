import 'dart:async';

import 'package:flutter/services.dart';

/// Fullscreen policy of the Android ExoPlayer screen.
///
/// Phones (shortest side under 600 dp) play in landscape with the system
/// bars hidden. Tablets and unfolded foldables keep whatever orientation the
/// user holds them in and only hide the system bars. Android TV is already
/// landscape (manifest) and is left alone.
///
/// On exit the app returns to its normal policy: no orientation lock (the
/// app declares none) and edge-to-edge system bars, so it is never left
/// locked in landscape, and a tablet or a phone held in landscape with
/// auto-rotate on is not forced back to portrait.
class PlayerOrientationController {
  PlayerOrientationController({
    required this.isTv,
    Future<void> Function(List<DeviceOrientation>)? setOrientations,
    Future<void> Function(SystemUiMode)? setUiMode,
  })  : _setOrientations =
            setOrientations ?? SystemChrome.setPreferredOrientations,
        _setUiMode = setUiMode ??
            ((mode) => SystemChrome.setEnabledSystemUIMode(mode));

  static const double phoneShortestSide = 600;
  static const landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// The app's own policy: no lock.
  static const appDefault = <DeviceOrientation>[];

  final bool isTv;
  final Future<void> Function(List<DeviceOrientation>) _setOrientations;
  final Future<void> Function(SystemUiMode) _setUiMode;

  bool _entered = false;
  bool _lockedLandscape = false;

  bool get active => _entered;
  bool get lockedLandscape => _lockedLandscape;

  /// Enters fullscreen for a screen whose shortest side is [shortestSide].
  Future<void> enter(double shortestSide) async {
    if (isTv || _entered) return;
    _entered = true;
    _lockedLandscape = shortestSide < phoneShortestSide;
    await _setUiMode(SystemUiMode.immersiveSticky);
    if (_lockedLandscape) await _setOrientations(landscape);
  }

  /// Re-applies fullscreen after the app returns from the background; some
  /// Android builds show the system bars again on resume.
  Future<void> resume() async {
    if (!_entered) return;
    await _setUiMode(SystemUiMode.immersiveSticky);
    if (_lockedLandscape) await _setOrientations(landscape);
  }

  /// Leaves fullscreen and restores the app's normal policy.
  Future<void> exit() async {
    if (!_entered) return;
    _entered = false;
    final wasLocked = _lockedLandscape;
    _lockedLandscape = false;
    if (wasLocked) await _setOrientations(appDefault);
    await _setUiMode(SystemUiMode.edgeToEdge);
  }
}
