import 'package:flutter/widgets.dart';

/// What [OrvixTelemetryService] should send after an app lifecycle change.
enum TelemetryLifecycleAction {
  /// The app left the screen: stop heartbeats, send `app_backgrounded`.
  backgrounded,

  /// The app is back on screen within the session timeout: restart
  /// heartbeats, send `app_resumed`.
  resumed,

  /// The app is back after the session timeout: start a new session
  /// (`session_start`) and restart heartbeats.
  startNewSession,

  /// The engine is going away: send `session_end`.
  endSession,
}

/// Turns Flutter lifecycle states into telemetry transitions.
///
/// `inactive` keeps the app counted as on screen. Desktop windows report it
/// whenever they lose focus and Android reports it for the notification
/// shade or multi-window, while the app is still visible. Only `hidden` and
/// `paused` move it to the background, and each transition is reported once
/// (Flutter passes through inactive, hidden and paused in a row).
class TelemetrySessionPolicy {
  TelemetrySessionPolicy({
    required bool foreground,
    this.sessionTimeout = const Duration(minutes: 30),
  }) : _foreground = foreground;

  /// Background time after which a return counts as a new session.
  final Duration sessionTimeout;

  bool _foreground;
  bool _ended = false;
  DateTime? _backgroundedAt;

  bool get isForeground => _foreground;
  bool get isEnded => _ended;

  List<TelemetryLifecycleAction> onLifecycle(
    AppLifecycleState state,
    DateTime now,
  ) {
    if (_ended) return const [];
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return const [];
        _foreground = true;
        final backgroundedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (backgroundedAt != null &&
            now.difference(backgroundedAt) >= sessionTimeout) {
          return const [TelemetryLifecycleAction.startNewSession];
        }
        return const [TelemetryLifecycleAction.resumed];
      case AppLifecycleState.inactive:
        return const [];
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_foreground) return const [];
        _foreground = false;
        _backgroundedAt = now;
        return const [TelemetryLifecycleAction.backgrounded];
      case AppLifecycleState.detached:
        _foreground = false;
        _ended = true;
        return const [TelemetryLifecycleAction.endSession];
    }
  }
}

/// The platform label sent with every telemetry message. The Control Center
/// normalizes exactly these labels; keep them stable.
///
/// It names the Orvix build, not the hardware: the TV build (ORVIX_TV) is
/// "Android TV" wherever it runs. The hardware class travels separately as
/// `device_type`.
String telemetryPlatformName({
  required bool isAndroidTvBuild,
  required String operatingSystem,
}) {
  switch (operatingSystem) {
    case 'android':
      return isAndroidTvBuild ? 'Android TV' : 'Android Mobile';
    case 'windows':
      return 'Windows';
    case 'macos':
      return 'macOS';
    case 'ios':
      return 'iOS';
    case 'linux':
      return 'Linux';
    default:
      return operatingSystem;
  }
}
