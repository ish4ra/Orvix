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
        cause: error,
      );
    }
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
