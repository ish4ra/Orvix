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
  /// [passwordCheckAuth] creates the separate auth client used by
  /// [verifyCurrentPassword]; tests replace it.
  SupabaseOrvixAccountBackend({
    SupabaseClient? client,
    GoTrueClient Function()? passwordCheckAuth,
  })  : _injected = client,
        _passwordCheckAuth = passwordCheckAuth;

  static const userStateTable = 'orvix_user_state';
  static const deleteAccountFunction = 'delete-account';

  final SupabaseClient? _injected;
  final GoTrueClient Function()? _passwordCheckAuth;

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
      case 'reauthentication_needed':
        return OrvixAuthErrorKind.reauthenticationRequired;
      case 'invalid_credentials':
        return OrvixAuthErrorKind.invalidCredentials;
      // Wrong, used or expired reauthentication code.
      case 'reauthentication_not_valid':
        return OrvixAuthErrorKind.invalidCode;
      case 'session_not_found':
      case 'session_expired':
      case 'bad_jwt':
        return OrvixAuthErrorKind.sessionMissing;
    }
    if (error.statusCode == '429' || message.contains('security purposes')) {
      return OrvixAuthErrorKind.rateLimited;
    }
    if (message.contains('requires reauthentication')) {
      return OrvixAuthErrorKind.reauthenticationRequired;
    }
    if (message.contains('invalid login credentials')) {
      return OrvixAuthErrorKind.invalidCredentials;
    }
    if (message.contains('nonce has expired') ||
        message.contains('token has expired') ||
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
  Future<void> changePassword({
    required String newPassword,
    String? verificationCode,
  }) =>
      // With "Secure password change" on, Supabase Auth accepts a password
      // update without a nonce only while the session is less than 24 hours
      // old; otherwise it answers reauthentication_needed. The nonce is the
      // code sent by reauthenticate(). Supabase keeps this session and signs
      // the account out of its other sessions.
      _guard(() async {
        await _client.auth.updateUser(UserAttributes(
          password: newPassword,
          nonce: verificationCode,
        ));
      });

  @override
  Future<void> requestReauthentication() =>
      // Sends the "Reauthentication" email template, which shows {{ .Token }}
      // (supabase/email-templates/reauthentication.html).
      _guard(() => _client.auth.reauthenticate());

  /// The Auth URL of the project whose REST URL is [restUrl]; SupabaseClient
  /// serves both from one base URL (<url>/rest/v1 and <url>/auth/v1).
  static String authUrlFor(String restUrl) {
    const rest = '/rest/v1';
    final base = restUrl.endsWith(rest)
        ? restUrl.substring(0, restUrl.length - rest.length)
        : restUrl;
    return '$base/auth/v1';
  }

  /// A separate, non-persisted auth client for checking the current password.
  /// Signing in with it never replaces or refreshes the app's own session, so
  /// a failed or mismatched check cannot change who is signed in.
  GoTrueClient _newPasswordCheckAuth() {
    final factory = _passwordCheckAuth;
    if (factory != null) return factory();
    return GoTrueClient(
      url: authUrlFor(_client.rest.url),
      headers: _client.auth.headers,
      autoRefreshToken: false,
      flowType: AuthFlowType.implicit,
    );
  }

  @override
  Future<OrvixPasswordProof> verifyCurrentPassword({
    required String email,
    required String password,
  }) =>
      // Supabase's reauthenticate() nonce only authorizes a password update,
      // so the current password is confirmed with a normal password sign-in.
      // Its fresh access token carries a "password" amr entry, which the
      // delete-account Edge Function requires to be recent.
      _guard(() async {
        final auth = _newPasswordCheckAuth();
        try {
          final response = await auth.signInWithPassword(
            email: email,
            password: password,
          );
          final session = response.session;
          final user = response.user ?? session?.user;
          if (session == null || user == null) {
            throw AuthSessionMissingException(
                'Password confirmation did not start a session.');
          }
          return _SupabasePasswordProof(
            userId: user.id,
            auth: auth,
            accessToken: session.accessToken,
          );
        } catch (_) {
          auth.dispose();
          rethrow;
        }
      });

  @override
  Future<void> discardPasswordProof(OrvixPasswordProof proof) async {
    if (proof is! _SupabasePasswordProof || proof.discarded) return;
    proof.discarded = true;
    try {
      // Revokes only the confirmation session. After a deletion the user no
      // longer exists, which signOut already ignores.
      await proof.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
    } finally {
      proof.auth.dispose();
    }
  }

  @override
  Future<void> deleteAccount(OrvixPasswordProof proof) async {
    if (proof is! _SupabasePasswordProof || proof.discarded) {
      throw const OrvixAuthException(
        'Confirm the current password before deleting the account.',
        kind: OrvixAuthErrorKind.sessionMissing,
      );
    }
    try {
      // No body: the function deletes the user of this access token only.
      await _client.functions.invoke(
        deleteAccountFunction,
        headers: {'Authorization': 'Bearer ${proof.accessToken}'},
      );
    } on FunctionException catch (error) {
      if (!_alreadyDeleted(error)) throw _deletionFailure(error);
    } catch (error) {
      // The request may have reached the server before the connection
      // failed; only a confirmed missing account counts as deleted.
      if (!await _accountIsGone(proof)) {
        throw OrvixAuthException(
          'Could not reach the account deletion service.',
          kind: OrvixAuthErrorKind.network,
          cause: error,
        );
      }
    }
    await _signOutDeletedAccount();
  }

  static String? _functionError(FunctionException error) {
    final details = error.details;
    return details is Map ? details['error']?.toString() : null;
  }

  /// A retry after a deletion whose response was lost.
  static bool _alreadyDeleted(FunctionException error) =>
      error.status == 410 && _functionError(error) == 'account_not_found';

  static OrvixAuthException _deletionFailure(FunctionException error) {
    final code = _functionError(error);
    final kind = switch ((error.status, code)) {
      (401, 'reauthentication_required') =>
        OrvixAuthErrorKind.reauthenticationRequired,
      (401, _) => OrvixAuthErrorKind.sessionMissing,
      (429, _) => OrvixAuthErrorKind.rateLimited,
      _ => OrvixAuthErrorKind.unknown,
    };
    // Only the function's short error code is kept, never response bodies.
    return OrvixAuthException(
      'Account deletion failed.',
      code: code ?? 'account_deletion_failed',
      statusCode: '${error.status}',
      kind: kind,
    );
  }

  static Future<bool> _accountIsGone(_SupabasePasswordProof proof) async {
    try {
      await proof.auth.getUser(proof.accessToken);
      return false;
    } on AuthException catch (error) {
      return error.code == 'user_not_found';
    } catch (_) {
      return false;
    }
  }

  /// Clears this device's session for an account that no longer exists.
  /// The local session is removed before signOut contacts the server, so a
  /// failed server call still leaves this device signed out.
  Future<void> _signOutDeletedAccount() async {
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

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

class _SupabasePasswordProof extends OrvixPasswordProof {
  _SupabasePasswordProof({
    required super.userId,
    required this.auth,
    required this.accessToken,
  });

  /// The confirmation session's own client; never the app's client.
  final GoTrueClient auth;
  final String accessToken;
  bool discarded = false;
}
