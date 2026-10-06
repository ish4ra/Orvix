import 'package:supabase_flutter/supabase_flutter.dart';

import 'orvix_account_backend.dart';

/// The active Orvix account backend: Supabase Auth, the `orvix_user_state`
/// table, the credential RPCs and the TV login RPCs/Edge Function.
///
/// Supabase-specific types stay inside this adapter. Supabase [AuthException]s
/// (from any call, including database calls that refresh the session) are
/// rethrown as [OrvixAuthException]; other errors pass through unchanged.
class SupabaseOrvixAccountBackend implements OrvixAccountBackend {
  /// Uses [client] when given, otherwise the app-wide client created by
  /// `Supabase.initialize` in main.dart (resolved lazily on each call).
  SupabaseOrvixAccountBackend({SupabaseClient? client}) : _injected = client;

  static const userStateTable = 'orvix_user_state';

  final SupabaseClient? _injected;

  SupabaseClient get _client => _injected ?? Supabase.instance.client;

  static OrvixAccountUser? _toUser(User? user) =>
      user == null ? null : OrvixAccountUser(id: user.id, email: user.email);

  static OrvixAuthResult _toResult(AuthResponse response) => OrvixAuthResult(
        user: _toUser(response.user),
        hasSession: response.session != null,
      );

  static Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on AuthException catch (error) {
      throw OrvixAuthException(
        error.message,
        code: error.code,
        statusCode: error.statusCode,
        kind: _kindOf(error),
        retryAfterSeconds: _retryAfterSeconds(error.message),
        cause: error,
      );
    }
  }

  static OrvixAuthErrorKind _kindOf(AuthException error) {
    final message = error.message.toLowerCase();
    // A retryable error without an HTTP status never reached Supabase.
    if (error is AuthRetryableFetchException && error.statusCode == null) {
      return OrvixAuthErrorKind.network;
    }
    if (error is AuthSessionMissingException) {
      return OrvixAuthErrorKind.sessionMissing;
    }
    switch (error.code) {
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return OrvixAuthErrorKind.rateLimited;
      // Supabase reports wrong, used and expired codes all as otp_expired.
      case 'otp_expired':
        return OrvixAuthErrorKind.invalidCode;
      case 'email_address_invalid':
        return OrvixAuthErrorKind.invalidEmail;
      case 'weak_password':
        return OrvixAuthErrorKind.weakPassword;
      case 'same_password':
        return OrvixAuthErrorKind.samePassword;
      case 'session_not_found':
      case 'session_expired':
      case 'bad_jwt':
        return OrvixAuthErrorKind.sessionMissing;
    }
    if (error.statusCode == '429' || message.contains('security purposes')) {
      return OrvixAuthErrorKind.rateLimited;
    }
    if (message.contains('token has expired') ||
        message.contains('invalid token') ||
        message.contains('otp expired') ||
        message.contains('invalid otp')) {
      return OrvixAuthErrorKind.invalidCode;
    }
    if (message.contains('validate email') ||
        message.contains('invalid email') ||
        (message.contains('email address') && message.contains('invalid'))) {
      return OrvixAuthErrorKind.invalidEmail;
    }
    return OrvixAuthErrorKind.unknown;
  }

  /// Reads the wait time from Supabase's "you can only request this after
  /// N seconds" message.
  static int? _retryAfterSeconds(String message) {
    final match = RegExp(r'after (\d+) seconds?').firstMatch(message);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  @override
  OrvixAccountUser? get currentUser => _toUser(_client.auth.currentUser);

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) =>
      _guard(() async => _toResult(await _client.auth.signInWithPassword(
            email: email,
            password: password,
          )));

  @override
  Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  }) =>
      _guard(() async => _toResult(await _client.auth.signUp(
            email: email,
            password: password,
          )));

  @override
  Future<OrvixAuthResult> verifySignupCode({
    required String email,
    required String token,
  }) =>
      // Supabase's six-digit email OTP flow is verified as an email OTP.
      // `signup` is still required by resend(), but using it here can make a
      // freshly generated email code fail with the generic otp_expired error.
      _guard(() async => _toResult(await _client.auth.verifyOTP(
            type: OtpType.email,
            email: email,
            token: token,
          )));

  @override
  Future<void> resendSignupConfirmation({required String email}) =>
      // Supabase resend only accepts the signup type for signup confirmations.
      _guard(() => _client.auth.resend(type: OtpType.signup, email: email));

  @override
  Future<void> requestPasswordRecovery({required String email}) =>
      // Sends the "Reset Password" email template, which shows {{ .Token }}
      // as a six-digit code (supabase/email-templates/reset-password.html).
      // No redirect URL: the code is entered in the app, not opened as a link.
      // Supabase answers the same way for unknown addresses.
      _guard(() => _client.auth.resetPasswordForEmail(email));

  @override
  Future<void> verifyPasswordRecoveryCode({
    required String email,
    required String token,
  }) =>
      _guard(() async {
        final response = await _client.auth.verifyOTP(
          type: OtpType.recovery,
          email: email,
          token: token,
        );
        if (response.session == null) {
          throw AuthSessionMissingException(
              'Password recovery did not start a session.');
        }
      });

  @override
  Future<void> updateRecoveredPassword({required String newPassword}) =>
      _guard(() async {
        await _client.auth.updateUser(UserAttributes(password: newPassword));
      });

  @override
  Future<void> endPasswordRecovery() =>
      // Local scope: only this device's recovery session is revoked.
      _guard(() => _client.auth.signOut(scope: SignOutScope.local));

  @override
  Future<void> signOut() => _guard(() => _client.auth.signOut());

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async {
    final rows = await _guard(() => _client
        .from(userStateTable)
        .select()
        .eq('user_id', userId)
        .limit(1));
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {
    await _guard(() => _client.from(userStateTable).upsert({
          'user_id': userId,
          ...state,
        }, onConflict: 'user_id'));
  }

  @override
  Future<Map<String, String>> loadCredentials() async {
    final raw = await _guard(() => _client.rpc('load_orvix_credentials'));
    return raw is Map
        ? raw.map((key, value) =>
            MapEntry(key.toString(), value?.toString() ?? ''))
        : <String, String>{};
  }

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {
    await _guard(() => _client
        .rpc('save_orvix_credentials', params: {'p_payload': credentials}));
  }

  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) async {
    final raw = await _guard(() => _client.rpc('start_tv_login_session', params: {
          'p_device_nonce': deviceNonce,
          'p_device_name': deviceName,
        }));
    if (raw is! List || raw.isEmpty || raw.first is! Map) {
      throw StateError('TV login service returned an invalid start response.');
    }
    final row = Map<String, dynamic>.from(raw.first as Map);
    final deviceCode = row['device_code']?.toString();
    final userCode = row['user_code']?.toString();
    final verificationUrl = row['verification_uri_complete']?.toString();
    final interval =
        int.tryParse(row['poll_interval_seconds']?.toString() ?? '') ?? 3;
    if (deviceCode == null || userCode == null || verificationUrl == null) {
      throw StateError('TV login service returned an incomplete start response.');
    }
    return OrvixTvLoginStart(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: verificationUrl,
      pollIntervalSeconds: interval,
    );
  }

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    final raw = await _guard(() => _client.rpc('poll_tv_login_session', params: {
          'p_device_code': deviceCode,
          'p_device_nonce': deviceNonce,
        }));
    if (raw is! List || raw.isEmpty || raw.first is! Map) {
      throw StateError('TV login session is no longer available.');
    }
    return (raw.first as Map)['status']?.toString().toLowerCase();
  }

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    final response = await _guard(() => _client.functions.invoke(
          'tv-login-exchange',
          body: {'device_code': deviceCode, 'device_nonce': deviceNonce},
        ));
    if (response.status < 200 ||
        response.status >= 300 ||
        response.data is! Map) {
      throw StateError('Could not exchange the approved TV login.');
    }
    final refreshToken = (response.data as Map)['refresh_token']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw StateError('TV login did not return a session.');
    }
    return refreshToken;
  }

  @override
  Future<void> signInWithTvLoginToken(String token) =>
      _guard(() => _client.auth.setSession(token));

  @override
  Future<bool> approveTvLogin(String userCode) async {
    final approved = await _guard(() => _client.rpc(
          'approve_tv_login_session',
          params: {'p_user_code': userCode},
        ));
    return approved == true;
  }
}
