import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

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

  static final SupabaseClient _client = Supabase.instance.client;
  static final Random _random = Random.secure();

  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  static Future<void> run({
    required void Function(TvDeviceLoginState state) onState,
    required bool Function() isCancelled,
  }) async {
    onState(const TvDeviceLoginState(phase: TvDeviceLoginPhase.starting));
    final nonce = _uuidV4();

    try {
      final raw = await _client.rpc('start_tv_login_session', params: {
        'p_device_nonce': nonce,
        'p_device_name': 'Orvix Android TV',
      });
      if (isCancelled()) return;
      if (raw is! List || raw.isEmpty || raw.first is! Map) {
        throw StateError('TV login service returned an invalid start response.');
      }
      final row = Map<String, dynamic>.from(raw.first as Map);
      final deviceCode = row['device_code']?.toString();
      final userCode = row['user_code']?.toString();
      final verificationUrl = row['verification_uri_complete']?.toString();
      final interval = int.tryParse(row['poll_interval_seconds']?.toString() ?? '') ?? 3;
      if (deviceCode == null || userCode == null || verificationUrl == null) {
        throw StateError('TV login service returned an incomplete start response.');
      }

      onState(TvDeviceLoginState(
        phase: TvDeviceLoginPhase.waiting,
        userCode: userCode,
        verificationUrl: verificationUrl,
      ));

      for (var attempt = 0; attempt < 120 && !isCancelled(); attempt++) {
        await Future<void>.delayed(Duration(seconds: interval.clamp(2, 10)));
        if (isCancelled()) return;

        final pollRaw = await _client.rpc('poll_tv_login_session', params: {
          'p_device_code': deviceCode,
          'p_device_nonce': nonce,
        });
        if (pollRaw is! List || pollRaw.isEmpty || pollRaw.first is! Map) {
          throw StateError('TV login session is no longer available.');
        }
        final status = (pollRaw.first as Map)['status']?.toString().toLowerCase();
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

        final response = await _client.functions.invoke(
          'tv-login-exchange',
          body: {'device_code': deviceCode, 'device_nonce': nonce},
        );
        if (isCancelled()) return;
        if (response.status < 200 || response.status >= 300 || response.data is! Map) {
          throw StateError('Could not exchange the approved TV login.');
        }
        final refreshToken = (response.data as Map)['refresh_token']?.toString();
        if (refreshToken == null || refreshToken.isEmpty) {
          throw StateError('TV login did not return a session.');
        }
        await _client.auth.setSession(refreshToken);
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
