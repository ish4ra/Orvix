import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/telemetry_session_policy.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 21, 12);

  group('TelemetrySessionPolicy', () {
    test('desktop focus loss (inactive) keeps the app online and silent', () {
      final policy = TelemetrySessionPolicy(foreground: true);
      expect(policy.onLifecycle(AppLifecycleState.inactive, t0), isEmpty);
      expect(policy.isForeground, isTrue);
      expect(policy.onLifecycle(AppLifecycleState.resumed, t0), isEmpty,
          reason: 'no app_resumed event for a focus change');
    });

    test('going to the background is reported once, not per state', () {
      final policy = TelemetrySessionPolicy(foreground: true);
      final actions = [
        ...policy.onLifecycle(AppLifecycleState.inactive, t0),
        ...policy.onLifecycle(AppLifecycleState.hidden, t0),
        ...policy.onLifecycle(AppLifecycleState.paused, t0),
      ];
      expect(actions, [TelemetryLifecycleAction.backgrounded]);
      expect(policy.isForeground, isFalse);
    });

    test('a short background returns to the same session', () {
      final policy = TelemetrySessionPolicy(foreground: true);
      policy.onLifecycle(AppLifecycleState.paused, t0);
      final actions = [
        ...policy.onLifecycle(AppLifecycleState.hidden, t0),
        ...policy.onLifecycle(AppLifecycleState.inactive, t0),
        ...policy.onLifecycle(
          AppLifecycleState.resumed,
          t0.add(const Duration(minutes: 29)),
        ),
      ];
      expect(actions, [TelemetryLifecycleAction.resumed]);
      expect(policy.isForeground, isTrue);
    });

    test('returning after the session timeout starts a new session', () {
      final policy = TelemetrySessionPolicy(foreground: true);
      policy.onLifecycle(AppLifecycleState.paused, t0);
      expect(
        policy.onLifecycle(
          AppLifecycleState.resumed,
          t0.add(const Duration(minutes: 30)),
        ),
        [TelemetryLifecycleAction.startNewSession],
      );
    });

    test('an app launched in the background resumes without a new session', () {
      final policy = TelemetrySessionPolicy(foreground: false);
      expect(policy.onLifecycle(AppLifecycleState.resumed, t0),
          [TelemetryLifecycleAction.resumed]);
    });

    test('detached ends the session and nothing is sent afterwards', () {
      final policy = TelemetrySessionPolicy(foreground: true);
      expect(policy.onLifecycle(AppLifecycleState.detached, t0),
          [TelemetryLifecycleAction.endSession]);
      expect(policy.isEnded, isTrue);
      expect(policy.onLifecycle(AppLifecycleState.resumed, t0), isEmpty);
      expect(policy.onLifecycle(AppLifecycleState.detached, t0), isEmpty);
    });
  });

  group('telemetryPlatformName', () {
    test('keeps the labels the Control Center normalizes', () {
      String name(String os, {bool tv = false}) =>
          telemetryPlatformName(isAndroidTvBuild: tv, operatingSystem: os);
      expect(name('android', tv: true), 'Android TV');
      expect(name('android'), 'Android Mobile');
      expect(name('windows'), 'Windows');
      expect(name('macos'), 'macOS');
      expect(name('ios'), 'iOS');
      expect(name('linux'), 'Linux');
      expect(name('fuchsia'), 'fuchsia');
    });

    test('the TV flag only affects Android', () {
      expect(
        telemetryPlatformName(isAndroidTvBuild: true, operatingSystem: 'windows'),
        'Windows',
      );
    });
  });

  test('telemetry client never blocks startup on a failing step', () {
    final source = File('lib/services/orvix_telemetry_service.dart')
        .readAsStringSync();
    expect(source, contains('Future<void> initialize() async'));
    expect(source, contains('await _initialize();'));
    expect(source, contains('.timeout(_initStepTimeout)'));
    expect(source, contains('.timeout(_requestTimeout)'));
    // Failed sends are not retried in a loop.
    expect(source.toLowerCase(), isNot(contains('retry')));
  });
}
