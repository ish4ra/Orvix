import 'dart:async';
import 'dart:math';

import 'orvix_account_backend.dart';
import 'orvix_account_service.dart';

enum TvDeviceLoginPhase { idle, starting, waiting, signingIn, expired, failed }

class TvDeviceLoginState {
  const TvDeviceLoginState({
    this.phase = TvDeviceLoginPhase.idle,
    this.userCode,
    this.verificationUrl,
    this.message,
  });

  final TvDeviceLoginPhase phase;
  final String? userCode;
  final String? verificationUrl;
  final String? message;

  bool get active => phase == TvDeviceLoginPhase.starting ||
      phase == TvDeviceLoginPhase.waiting ||
      phase == TvDeviceLoginPhase.signingIn;
}

class TvDeviceLoginService {
  TvDeviceLoginService._();

  static OrvixTvLoginBackend get _backend => OrvixAccountService.backend;
  static final Random _random = Random.secure();

  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  /// Approves a TV's QR/user code from a signed-in phone.
  static Future<bool> approve(String userCode) =>
      _backend.approveTvLogin(userCode);

  static Future<void> run({
    required void Function(TvDeviceLoginState state) onState,
    required bool Function() isCancelled,
  }) async {
    onState(const TvDeviceLoginState(phase: TvDeviceLoginPhase.starting));
    final nonce = _uuidV4();

    try {
      final start = await _backend.startTvLogin(
        deviceNonce: nonce,
        deviceName: 'Orvix Android TV',
      );
      if (isCancelled()) return;
      final deviceCode = start.deviceCode;
      final userCode = start.userCode;
      final verificationUrl = start.verificationUrl;
      final interval = start.pollIntervalSeconds;

      onState(TvDeviceLoginState(
        phase: TvDeviceLoginPhase.waiting,
        userCode: userCode,
        verificationUrl: verificationUrl,
      ));

      for (var attempt = 0; attempt < 120 && !isCancelled(); attempt++) {
        await Future<void>.delayed(Duration(seconds: interval.clamp(2, 10)));
        if (isCancelled()) return;

        final status = await _backend.pollTvLogin(
          deviceCode: deviceCode,
          deviceNonce: nonce,
        );
        if (status == 'pending') continue;
        if (status == 'expired') {
          onState(const TvDeviceLoginState(
            phase: TvDeviceLoginPhase.expired,
            message: 'QR login expired. Generate a new code.',
          ));
          return;
        }
        if (status != 'approved') {
          throw StateError('TV login session ended unexpectedly.');
        }

        onState(TvDeviceLoginState(
          phase: TvDeviceLoginPhase.signingIn,
          userCode: userCode,
          verificationUrl: verificationUrl,
        ));

        final sessionToken = await _backend.exchangeTvLogin(
          deviceCode: deviceCode,
          deviceNonce: nonce,
        );
        if (isCancelled()) return;
        await _backend.signInWithTvLoginToken(sessionToken);
        return;
      }

      if (!isCancelled()) {
        onState(const TvDeviceLoginState(
          phase: TvDeviceLoginPhase.expired,
          message: 'QR login expired. Generate a new code.',
        ));
      }
    } catch (error) {
      if (!isCancelled()) {
        onState(TvDeviceLoginState(
          phase: TvDeviceLoginPhase.failed,
          message: 'Could not start QR login. Please try again.',
        ));
      }
    }
  }
}
