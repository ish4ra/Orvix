// Backend boundary for Orvix accounts, cloud sync and TV device login.
//
// The account UI and OrvixAccountService only use the types in this file. The
// active backend (currently Supabase, see supabase_orvix_account_backend.dart)
// is selected in OrvixAccountService.backend. Moving to another provider means
// writing a new OrvixAccountBackend implementation; the local-first merge
// rules, SharedPreferences/secure-storage handling and the UI stay as they are.
//
// Orvix must stay fully usable without an account, so every caller treats a
// null currentUser as "local only" and never requires the backend to be
// reachable.

/// A signed-in Orvix account.
class OrvixAccountUser {
  const OrvixAccountUser({required this.id, this.email});

  final String id;
  final String? email;
}

/// Outcome of a sign-in, sign-up or verification request.
class OrvixAuthResult {
  const OrvixAuthResult({this.user, this.hasSession = false});

  final OrvixAccountUser? user;

  /// False when the request succeeded but the account still needs email
  /// verification before a session exists.
  final bool hasSession;
}

/// An authentication failure reported by the account backend.
///
/// [message] is the backend's human-readable message; the account UI maps it
/// to friendly text.
class OrvixAuthException implements Exception {
  const OrvixAuthException(
    this.message, {
    this.code,
    this.statusCode,
    this.cause,
  });

  final String message;
  final String? code;
  final String? statusCode;

  /// The backend-specific error this was translated from, if any.
  final Object? cause;

  @override
  String toString() => cause?.toString() ?? 'OrvixAuthException: $message';
}

/// The first step of a TV device login: the code shown on the TV.
class OrvixTvLoginStart {
  const OrvixTvLoginStart({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.pollIntervalSeconds,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int pollIntervalSeconds;
}

/// Email/password accounts and the current session.
abstract interface class OrvixAuthBackend {
  OrvixAccountUser? get currentUser;

  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  });

  Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  });

  /// Verifies the six-digit code sent after sign-up.
  Future<OrvixAuthResult> verifySignupCode({
    required String email,
    required String token,
  });

  Future<void> resendSignupConfirmation({required String email});

  Future<void> signOut();
}

/// Per-account cloud copy of local Orvix state and synced credentials.
///
/// The service decides what to store and how to merge it; the backend only
/// loads and saves it for the signed-in user.
abstract interface class OrvixCloudSyncBackend {
  /// Returns the stored state for [userId], or null when nothing is stored.
  ///
  /// Keys: watchlist, library, progress, home_sections, preferred_cloud,
  /// preferences.
  Future<Map<String, dynamic>?> loadUserState(String userId);

  /// Creates or replaces the stored state for [userId] (same keys as
  /// [loadUserState]).
  Future<void> saveUserState(String userId, Map<String, dynamic> state);

  /// Returns the signed-in user's synced credentials (empty when none).
  Future<Map<String, String>> loadCredentials();

  Future<void> saveCredentials(Map<String, String> credentials);
}

/// Android TV QR/device-code login.
abstract interface class OrvixTvLoginBackend {
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  });

  /// Returns the lower-case session status, e.g. pending, expired, approved.
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  });

  /// Exchanges an approved TV login for a session token for
  /// [signInWithTvLoginToken].
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  });

  Future<void> signInWithTvLoginToken(String token);

  /// Approves a TV's code from a signed-in phone. Returns false when the code
  /// expired or was already used.
  Future<bool> approveTvLogin(String userCode);
}

/// Everything Orvix needs from an account backend.
abstract interface class OrvixAccountBackend
    implements OrvixAuthBackend, OrvixCloudSyncBackend, OrvixTvLoginBackend {}
