import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_preferences_service.dart';
import 'orvix_account_backend.dart';
import 'secure_storage_factory.dart';
import 'supabase_orvix_account_backend.dart';

/// The account/cloud-sync facade used by the UI and app lifecycle.
///
/// Local-first: Orvix data lives in SharedPreferences and secure storage, and
/// is merged with the cloud copy only while signed in. All backend access goes
/// through [backend] (see orvix_account_backend.dart).
class OrvixAccountService {
  OrvixAccountService._();

  /// The active account backend. Supabase is the only production backend;
  /// replace this to move Orvix accounts to another provider (or in tests).
  static OrvixAccountBackend get backend => _backend;
  static set backend(OrvixAccountBackend value) {
    _backend = value;
    _deletedUserId = null;
  }

  static OrvixAccountBackend _backend = SupabaseOrvixAccountBackend();

  static const _watchlistKey = 'pikora_watchlist_v1';
  static const _libraryKey = 'pikora_media_library_v1';
  static const _progressKey = 'pikora_continue_watching_v1';
  static const _recoveryPendingKey = 'orvix_password_recovery_pending_v1';
  static const _localOnlyPreferenceKeys = <String>{
    'pikora_source_addons',
    'pikora_integrated_torrentio_url_v1',
    _recoveryPendingKey,
  };

  /// Password rules checked before asking the backend. Six characters is the
  /// existing sign-up minimum; 72 is the longest password Supabase accepts.
  static const minPasswordLength = 6;
  static const maxPasswordLength = 72;

  /// True between a verified recovery code and the end of password recovery.
  static bool _recoverySessionActive = false;

  /// True from the password check until the deleted account is signed out.
  static bool _accountDeletionInProgress = false;

  /// The account deleted during this run. A stale session for it is never
  /// treated as signed in again.
  static String? _deletedUserId;

  /// The secure-storage keys of each provider that follow the Orvix account.
  ///
  /// PikPak's CAPTCHA token and device id are deliberately missing: they
  /// belong to this device and are recreated by PikPak when needed.
  static const _providerCredentialKeys = <CloudProvider, List<String>>{
    CloudProvider.torbox: ['orvix_torbox_api_token_v1'],
    CloudProvider.realDebrid: ['orvix_real_debrid_token_v1'],
    CloudProvider.premiumize: ['orvix_premiumize_token_v1'],
    CloudProvider.pikpak: [
      'pikpak_access_token',
      'pikpak_refresh_token',
      'pikpak_username',
      'pikpak_user_id',
    ],
  };
  static final List<String> _credentialKeys = [
    for (final keys in _providerCredentialKeys.values) ...keys,
  ];

  /// Device-local bookkeeping for credential sync, kept in secure storage
  /// and never uploaded. See [_CredentialSyncState].
  static const _credentialSyncStateKey = 'orvix_credential_sync_state_v1';
  static final FlutterSecureStorage _secureStorage = createOrvixSecureStorage();

  /// Credential syncs run one at a time so a provider change and a full
  /// merge never read and write the cloud copy over each other.
  static bool _credentialSyncRunning = false;
  static final List<Completer<void>> _credentialSyncWaiters = [];

  static final ValueNotifier<int> _providerCredentialRevision =
      ValueNotifier<int>(0);

  /// Increases whenever a sync restores or replaces a provider credential
  /// on this device, so provider screens that are already open can check
  /// their connection again without being rebuilt.
  static ValueListenable<int> get providerCredentialRevision =>
      _providerCredentialRevision;

  /// The secure-storage keys of [provider] that sync with the account.
  static List<String> providerCredentialKeys(CloudProvider provider) =>
      _providerCredentialKeys[provider]!;

  /// The signed-in user. A password recovery session is not a sign-in: while
  /// one is active this stays null, so nothing syncs into that account.
  static OrvixAccountUser? get currentUser {
    if (_recoverySessionActive) return null;
    final user = backend.currentUser;
    if (user != null && user.id == _deletedUserId) return null;
    return user;
  }

  static bool get isSignedIn => currentUser != null;

  /// Whether [deleteAccount] is running. Cloud sync and TV approval are
  /// paused meanwhile so nothing is written back into the account.
  static bool get isDeletingAccount => _accountDeletionInProgress;

  /// Whether cloud data may still be written for [user]: it is the signed-in
  /// account and is not being deleted.
  static bool _cloudWritesAllowed(OrvixAccountUser user) =>
      !_accountDeletionInProgress && currentUser?.id == user.id;

  /// Signs in, then merges the account into this device.
  ///
  /// Throws only when signing in fails. A sync problem after a successful
  /// sign-in is reported in [OrvixSignInResult.sync]; the user stays signed
  /// in and Sync now retries.
  static Future<OrvixSignInResult> signIn({
    required String email,
    required String password,
  }) async {
    final response = await backend.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    return OrvixSignInResult(response, sync: await mergeCloudIntoLocal());
  }

  /// Same contract as [signIn]; nothing syncs until a session exists.
  static Future<OrvixSignInResult> signUp({
    required String email,
    required String password,
  }) async {
    final response = await backend.signUp(
      email: email.trim(),
      password: password,
    );
    return OrvixSignInResult(
      response,
      sync: response.hasSession ? await mergeCloudIntoLocal() : null,
    );
  }

  /// Same contract as [signIn]; nothing syncs until a session exists.
  static Future<OrvixSignInResult> verifySignupOtp({
    required String email,
    required String token,
  }) async {
    final response = await backend.verifySignupCode(
      email: email.trim(),
      token: token.trim(),
    );
    return OrvixSignInResult(
      response,
      sync: response.hasSession ? await mergeCloudIntoLocal() : null,
    );
  }

  static Future<void> resendSignupConfirmation({
    required String email,
  }) {
    return backend.resendSignupConfirmation(email: email.trim());
  }

  static Future<void> signOut() => backend.signOut();

  /// Whether a recovery code was verified and a new password can be set.
  static bool get isPasswordRecoveryVerified => _recoverySessionActive;

  /// Sends (or resends) a password recovery code to [email].
  static Future<void> requestPasswordRecovery({required String email}) {
    return backend.requestPasswordRecovery(email: email.trim());
  }

  /// Verifies the recovery code. The recovery session that this starts never
  /// counts as signed in; finish with [updateRecoveredPassword] or
  /// [cancelPasswordRecovery].
  static Future<void> verifyPasswordRecovery({
    required String email,
    required String token,
  }) async {
    await _endRecoverySession();
    if (backend.currentUser != null) {
      throw StateError('Sign out before resetting the account password.');
    }
    // Set before the request so nothing syncs into the account the moment
    // the session appears, and marked on disk so a recovery interrupted by
    // the app closing is discarded on the next start.
    _recoverySessionActive = true;
    await _setRecoveryPending(true);
    try {
      await backend.verifyPasswordRecoveryCode(
        email: email.trim(),
        token: token.trim(),
      );
    } catch (_) {
      await _endRecoverySession();
      rethrow;
    }
  }

  /// Sets the new password and ends the recovery session, leaving this device
  /// signed out so the user signs in with the new password.
  ///
  /// When the backend rejects the password itself (too weak, unchanged) the
  /// recovery session is kept so another password can be tried without a new
  /// code. When the session is gone the user has to request a new code.
  static Future<void> updateRecoveredPassword({
    required String newPassword,
  }) async {
    if (!_recoverySessionActive) {
      throw const OrvixAuthException(
        'Password recovery session is missing.',
        kind: OrvixAuthErrorKind.sessionMissing,
      );
    }
    try {
      await backend.updateRecoveredPassword(newPassword: newPassword);
    } on OrvixAuthException catch (error) {
      if (error.kind == OrvixAuthErrorKind.sessionMissing) {
        await _endRecoverySession();
      }
      rethrow;
    }
    await _endRecoverySession();
  }

  /// Changes the signed-in user's password; this device stays signed in and
  /// nothing is synced. When the backend asks for a verification code
  /// ([OrvixAuthErrorKind.reauthenticationRequired]), send one with
  /// [requestPasswordChangeCode] and retry with [verificationCode].
  static Future<void> changePassword({
    required String newPassword,
    String? verificationCode,
  }) async {
    // currentUser is null during password recovery, so a recovery session is
    // never used here.
    if (currentUser == null) {
      throw const OrvixAuthException(
        'Sign in before changing the account password.',
        kind: OrvixAuthErrorKind.sessionMissing,
      );
    }
    final code = verificationCode?.trim();
    await backend.changePassword(
      newPassword: newPassword,
      verificationCode: code == null || code.isEmpty ? null : code,
    );
  }

  /// Sends (or resends) the verification code needed by [changePassword].
  static Future<void> requestPasswordChangeCode() async {
    if (currentUser == null) {
      throw const OrvixAuthException(
        'Sign in before changing the account password.',
        kind: OrvixAuthErrorKind.sessionMissing,
      );
    }
    await backend.requestReauthentication();
  }

  /// Permanently deletes the signed-in account and its cloud data after
  /// confirming [currentPassword], then leaves this device signed out.
  ///
  /// Local Orvix data (library, watchlist, progress, preferences and
  /// device-stored provider credentials) is kept. Nothing syncs while this
  /// runs. When anything fails the account is not reported as deleted and,
  /// unless the server already removed it, this device stays signed in.
  /// The password is passed straight to the backend and never kept.
  static Future<void> deleteAccount({required String currentPassword}) async {
    final user = currentUser;
    if (user == null) {
      throw const OrvixAuthException(
        'Sign in before deleting the account.',
        kind: OrvixAuthErrorKind.sessionMissing,
      );
    }
    if (_accountDeletionInProgress) {
      throw StateError('Account deletion is already in progress.');
    }
    final email = user.email?.trim() ?? '';
    if (email.isEmpty) {
      throw const OrvixAuthException(
        'The account has no email address to confirm the password with.',
      );
    }

    _accountDeletionInProgress = true;
    OrvixPasswordProof? proof;
    try {
      proof = await backend.verifyCurrentPassword(
        email: email,
        password: currentPassword,
      );
      // Only the account that started the deletion may be deleted.
      if (proof.userId != user.id || currentUser?.id != user.id) {
        throw const OrvixAuthException(
          'The signed-in account changed during account deletion.',
          kind: OrvixAuthErrorKind.accountChanged,
        );
      }
      await backend.deleteAccount(proof);
      _deletedUserId = user.id;
    } finally {
      if (proof != null) {
        try {
          await backend.discardPasswordProof(proof);
        } catch (_) {}
      }
      _accountDeletionInProgress = false;
    }
  }

  /// Abandons password recovery and discards any recovery session.
  static Future<void> cancelPasswordRecovery() => _endRecoverySession();

  static Future<void> _endRecoverySession() async {
    if (_recoverySessionActive) {
      try {
        await backend.endPasswordRecovery();
      } catch (_) {
        // The local session is discarded even when the server call fails.
      }
      _recoverySessionActive = false;
    }
    await _setRecoveryPending(false);
  }

  static Future<void> _setRecoveryPending(bool pending) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pending) {
        await prefs.setBool(_recoveryPendingKey, true);
      } else if (prefs.containsKey(_recoveryPendingKey)) {
        await prefs.remove(_recoveryPendingKey);
      }
    } catch (_) {}
  }

  /// Discards a recovery session left behind when the app closed mid-reset.
  static Future<void> _discardInterruptedRecovery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_recoveryPendingKey) != true) return;
      if (backend.currentUser != null) {
        await backend.endPasswordRecovery();
      }
      await prefs.remove(_recoveryPendingKey);
    } catch (_) {}
  }

  static Future<void> restoreSignedInState() async {
    await _discardInterruptedRecovery();
    if (!isSignedIn) return;
    try {
      await mergeCloudIntoLocal();
    } catch (_) {
      // Keep Orvix fully usable offline/local-first when cloud sync is unavailable.
    }
  }

  static Future<void> pushLocalStateIfSignedIn() async {
    final user = currentUser;
    if (user == null || !_cloudWritesAllowed(user)) return;

    final prefs = await SharedPreferences.getInstance();
    final watchlist =
        _decodeJsonValue(prefs.getString(_watchlistKey), const <dynamic>[]);
    final library =
        _decodeJsonValue(prefs.getString(_libraryKey), const <dynamic>[]);
    final progress = _decodeJsonValue(
        prefs.getString(_progressKey), const <String, dynamic>{});
    final preferences = _collectAppPreferences(prefs);

    if (!_cloudWritesAllowed(user)) return;
    await backend.saveUserState(user.id, {
      'watchlist': watchlist,
      'library': library,
      'progress': progress,
      'home_sections':
          preferences['pikora_home_sections_v1'] ?? const <dynamic>[],
      'preferred_cloud':
          preferences['orvix_preferred_cloud_v1']?.toString() ?? 'pikpak',
      'preferences': preferences,
    });
  }

  /// Reconciles this device's provider credentials with the account.
  ///
  /// Per credential, against what this device last reconciled:
  /// * changed here (connected, reconnected or refreshed): this device's
  ///   value is uploaded;
  /// * unchanged here but replaced in the cloud by another device: the cloud
  ///   value is adopted;
  /// * missing here: the cloud value is restored, unless this device
  ///   explicitly disconnected the provider ([providerDisconnected]), in
  ///   which case it is removed from the cloud instead;
  /// * removed from the cloud by another device: kept here, not re-uploaded.
  /// Before the first reconciliation for an account every value present
  /// here counts as changed here.
  ///
  /// A failed upload never touches this device's credentials; the next sync
  /// retries. Credential values are never logged or put into errors.
  static Future<void> syncCredentialsIfSignedIn() async {
    final user = currentUser;
    if (user == null || !_cloudWritesAllowed(user)) return;
    await _serializeCredentials(() => _syncCredentials(user));
  }

  /// Uploads [provider]'s credentials right after it was connected on this
  /// device (its service has already stored them). Never throws: when only
  /// the upload fails, the provider stays connected here and the next sync
  /// retries.
  static Future<ProviderCredentialSyncResult> providerConnected(
      CloudProvider provider) {
    return _changeProviderCredentials(provider, disconnected: false);
  }

  /// Removes [provider]'s credentials from the account right after it was
  /// disconnected on this device (its service has already deleted them).
  /// Other providers are untouched. Never throws: when the cloud cannot be
  /// reached, the removal is remembered and finished by a later sync, so the
  /// old credential is never restored.
  static Future<ProviderCredentialSyncResult> providerDisconnected(
      CloudProvider provider) {
    return _changeProviderCredentials(provider, disconnected: true);
  }

  static Future<ProviderCredentialSyncResult> _changeProviderCredentials(
    CloudProvider provider, {
    required bool disconnected,
  }) async {
    final keys = providerCredentialKeys(provider);
    final user = currentUser;
    final signedIn = user != null && _cloudWritesAllowed(user);
    try {
      return await _serializeCredentials(() async {
        final state = await _readCredentialSyncState();
        final ownState = signedIn && state.userId == user.id;
        if (disconnected) {
          // The fingerprints of a disconnected provider are never needed
          // again; without an account the cloud copy is left alone.
          state.synced.removeWhere((key, _) => keys.contains(key));
          if (signedIn) {
            if (!ownState) {
              state
                ..synced.clear()
                ..removed.clear();
            }
            state.removed.addAll(keys);
            await _writeCredentialSyncState(state, userId: user.id);
          } else if (state.userId != null) {
            await _writeCredentialSyncState(state, userId: state.userId!);
          }
        } else if (ownState && state.removed.any(keys.contains)) {
          state.removed.removeWhere(keys.contains);
          await _writeCredentialSyncState(state, userId: user.id);
        }
        if (!signedIn) return ProviderCredentialSyncResult.localOnly;
        return await _syncCredentials(user)
            ? ProviderCredentialSyncResult.synced
            : ProviderCredentialSyncResult.localOnly;
      });
    } catch (_) {
      // The error may come from the backend; it is not passed on so no
      // response detail can reach the UI next to a credential.
      return ProviderCredentialSyncResult.failed;
    }
  }

  static Future<T> _serializeCredentials<T>(
      Future<T> Function() action) async {
    while (_credentialSyncRunning) {
      final turn = Completer<void>();
      _credentialSyncWaiters.add(turn);
      await turn.future;
    }
    _credentialSyncRunning = true;
    try {
      return await action();
    } finally {
      _credentialSyncRunning = false;
      if (_credentialSyncWaiters.isNotEmpty) {
        _credentialSyncWaiters.removeAt(0).complete();
      }
    }
  }

  /// Returns false when nothing was synced because the account may no
  /// longer be written to.
  static Future<bool> _syncCredentials(OrvixAccountUser user) async {
    if (!_cloudWritesAllowed(user)) return false;
    final stored = await _readCredentialSyncState();
    final state = stored.userId == user.id
        ? stored
        : _CredentialSyncState(userId: user.id);
    final local = <String, String>{};
    for (final key in _credentialKeys) {
      final value = await _secureStorage.read(key: key);
      if (value != null && value.isNotEmpty) local[key] = value;
    }

    final remote = Map<String, String>.from(await backend.loadCredentials())
      ..removeWhere((_, value) => value.isEmpty);
    if (!_cloudWritesAllowed(user)) return false;

    // Credentials this version does not know about stay in the cloud as is.
    final merged = <String, String>{
      for (final entry in remote.entries)
        if (!_credentialKeys.contains(entry.key)) entry.key: entry.value,
    };
    final restore = <String, String>{};
    for (final key in _credentialKeys) {
      final mine = local[key];
      final cloud = remote[key];
      final last = state.synced[key];
      if (mine == null) {
        if (state.removed.contains(key)) continue;
        if (cloud != null) merged[key] = restore[key] = cloud;
        continue;
      }
      final unchangedHere = last != null && _fingerprint(mine) == last;
      if (!unchangedHere || cloud == mine) {
        merged[key] = mine;
      } else if (cloud != null) {
        merged[key] = restore[key] = cloud;
      }
      // Otherwise another device removed it: keep it here, do not upload.
    }

    for (final entry in restore.entries) {
      await _secureStorage.write(key: entry.key, value: entry.value);
    }
    if (restore.isNotEmpty) _providerCredentialRevision.value++;

    if (!mapEquals(merged, remote)) {
      if (!_cloudWritesAllowed(user)) return false;
      await backend.saveCredentials(merged);
      // The payload sent is the complete credential set. When it drops keys
      // (a disconnect), make sure the account really lost them: a backend
      // that merged instead of replacing would bring the old credential back
      // on the next sync. The removal then stays pending and is retried.
      final dropped = remote.keys.where((key) => !merged.containsKey(key));
      if (dropped.isNotEmpty) {
        final after = await backend.loadCredentials();
        if (dropped.any((key) => after[key]?.isNotEmpty ?? false)) {
          throw StateError('The account kept removed provider credentials.');
        }
      }
    }

    final now = {...local, ...restore};
    await _writeCredentialSyncState(
      _CredentialSyncState(
        userId: user.id,
        synced: {
          for (final entry in now.entries) entry.key: _fingerprint(entry.value),
        },
      ),
      userId: user.id,
    );
    return true;
  }

  static String _fingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static Future<_CredentialSyncState> _readCredentialSyncState() async {
    try {
      final raw = await _secureStorage.read(key: _credentialSyncStateKey);
      if (raw == null || raw.isEmpty) return _CredentialSyncState();
      final json = jsonDecode(raw);
      if (json is! Map) return _CredentialSyncState();
      final synced = json['synced'];
      final removed = json['removed'];
      return _CredentialSyncState(
        userId: json['user']?.toString(),
        synced: synced is Map
            ? synced.map((k, v) => MapEntry(k.toString(), v.toString()))
            : null,
        removed:
            removed is List ? removed.map((e) => e.toString()).toSet() : null,
      );
    } catch (_) {
      return _CredentialSyncState();
    }
  }

  static Future<void> _writeCredentialSyncState(
    _CredentialSyncState state, {
    required String userId,
  }) {
    return _secureStorage.write(
      key: _credentialSyncStateKey,
      value: jsonEncode({
        'user': userId,
        'synced': state.synced,
        'removed': state.removed.toList()..sort(),
      }),
    );
  }

  /// Merges the account into this device and this device into the account.
  ///
  /// Provider credentials and account state (library, watchlist, progress,
  /// preferences) sync independently: a failure in one never stops or undoes
  /// the other, and each is reported in the result. Never throws for a sync
  /// failure; a failed part keeps this device's data as it is and the next
  /// sync retries it. No backend detail is kept in the result.
  static Future<OrvixSyncResult> mergeCloudIntoLocal() async {
    final user = currentUser;
    if (user == null || !_cloudWritesAllowed(user)) {
      return OrvixSyncResult.skipped;
    }

    OrvixSyncStatus credentials;
    try {
      credentials = await _serializeCredentials(() => _syncCredentials(user))
          ? OrvixSyncStatus.synced
          : OrvixSyncStatus.skipped;
    } catch (error) {
      _logSyncFailure('provider credentials', error);
      credentials = OrvixSyncStatus.failed;
    }

    OrvixSyncStatus state;
    try {
      state = await _mergeUserState(user)
          ? OrvixSyncStatus.synced
          : OrvixSyncStatus.skipped;
    } catch (error) {
      _logSyncFailure('account data', error);
      state = OrvixSyncStatus.failed;
    }
    return OrvixSyncResult(credentials: credentials, state: state);
  }

  /// Only the error type is logged: backend messages may echo request data.
  static void _logSyncFailure(String part, Object error) {
    debugPrint('Orvix account sync: $part did not sync (${error.runtimeType}).');
  }

  /// Returns false when nothing was synced because the account may no
  /// longer be written to.
  static Future<bool> _mergeUserState(OrvixAccountUser user) async {
    if (!_cloudWritesAllowed(user)) return false;
    final prefs = await SharedPreferences.getInstance();
    final stored = await backend.loadUserState(user.id);
    if (!_cloudWritesAllowed(user)) return false;

    if (stored == null) {
      await pushLocalStateIfSignedIn();
      return true;
    }

    final remote = Map<String, dynamic>.from(stored);
    final localWatchlist = _asList(
        _decodeJsonValue(prefs.getString(_watchlistKey), const <dynamic>[]));
    final localLibrary = _asList(
        _decodeJsonValue(prefs.getString(_libraryKey), const <dynamic>[]));
    final localProgress = _asMap(_decodeJsonValue(
        prefs.getString(_progressKey), const <String, dynamic>{}));

    final mergedWatchlist =
        _mergeMediaLists(_asList(remote['watchlist']), localWatchlist);
    final mergedLibrary =
        _mergeMediaLists(_asList(remote['library']), localLibrary);
    final mergedProgress =
        _mergeProgress(_asMap(remote['progress']), localProgress);

    await prefs.setString(_watchlistKey, jsonEncode(mergedWatchlist));
    await prefs.setString(_libraryKey, jsonEncode(mergedLibrary));
    await prefs.setString(_progressKey, jsonEncode(mergedProgress));

    final remotePreferences = _asMap(remote['preferences'])
      ..removeWhere((key, _) => _localOnlyPreferenceKeys.contains(key));
    await _restorePreferences(prefs, remotePreferences);

    // Local keys win only when they actually exist on this device. This keeps
    // intentional local changes while allowing a fresh install to inherit the cloud.
    final mergedPreferences = <String, dynamic>{
      ...remotePreferences,
      ..._collectAppPreferences(prefs),
    };

    if (!_cloudWritesAllowed(user)) return false;
    await backend.saveUserState(user.id, {
      'watchlist': mergedWatchlist,
      'library': mergedLibrary,
      'progress': mergedProgress,
      'home_sections':
          mergedPreferences['pikora_home_sections_v1'] ?? const <dynamic>[],
      'preferred_cloud':
          mergedPreferences['orvix_preferred_cloud_v1']?.toString() ?? 'pikpak',
      'preferences': mergedPreferences,
    });
    return true;
  }

  static dynamic _decodeJsonValue(String? raw, dynamic fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return fallback;
    }
  }

  static List<dynamic> _asList(dynamic value) =>
      value is List ? List<dynamic>.from(value) : <dynamic>[];

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  static List<dynamic> _mergeMediaLists(
      List<dynamic> remote, List<dynamic> local) {
    final merged = <String, dynamic>{};

    void addAll(List<dynamic> values) {
      for (final entry in values) {
        if (entry is! Map) continue;
        final map = entry.map((key, value) => MapEntry(key.toString(), value));
        final id = map['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final kind = map['kind']?.toString() ?? 'movie';
        merged['$kind:$id'] = map;
      }
    }

    addAll(remote);
    addAll(local);
    return merged.values.toList(growable: false);
  }

  static Map<String, dynamic> _mergeProgress(
    Map<String, dynamic> remote,
    Map<String, dynamic> local,
  ) {
    final merged = <String, dynamic>{...remote};
    for (final entry in local.entries) {
      final existing = merged[entry.key];
      if (existing is! Map || entry.value is! Map) {
        merged[entry.key] = entry.value;
        continue;
      }
      final existingMap =
          existing.map((key, value) => MapEntry(key.toString(), value));
      final localMap = (entry.value as Map)
          .map((key, value) => MapEntry(key.toString(), value));
      final remoteAt =
          DateTime.tryParse(existingMap['updatedAt']?.toString() ?? '');
      final localAt =
          DateTime.tryParse(localMap['updatedAt']?.toString() ?? '');
      if (remoteAt == null || (localAt != null && localAt.isAfter(remoteAt))) {
        merged[entry.key] = localMap;
      }
    }
    return merged;
  }

  static Map<String, dynamic> _collectAppPreferences(SharedPreferences prefs) {
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('orvix_') && !key.startsWith('pikora_')) continue;
      if (key == _watchlistKey || key == _libraryKey || key == _progressKey)
        continue;
      if (_localOnlyPreferenceKeys.contains(key)) continue;
      final value = prefs.get(key);
      if (value is String ||
          value is bool ||
          value is int ||
          value is double ||
          value is List<String>) {
        out[key] = value;
      }
    }
    return out;
  }

  static Future<void> _restorePreferences(
    SharedPreferences prefs,
    Map<String, dynamic> values,
  ) async {
    for (final entry in values.entries) {
      final key = entry.key;
      if (!key.startsWith('orvix_') && !key.startsWith('pikora_')) continue;
      if (_localOnlyPreferenceKeys.contains(key)) continue;
      if (prefs.containsKey(key)) continue;
      final value = entry.value;
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is double) {
        await prefs.setDouble(key, value);
      } else if (value is List) {
        await prefs.setStringList(
            key, value.map((e) => e.toString()).toList(growable: false));
      }
    }
  }
}

/// How one part of an account sync ended.
enum OrvixSyncStatus {
  synced,

  /// Could not sync; this device keeps its data and the next sync retries.
  failed,

  /// Not attempted: not signed in, or the account is being deleted.
  skipped,
}

/// The outcome of one account sync. Provider credentials and account state
/// (library, watchlist, progress and preferences) are reported separately
/// because one can sync while the other fails. Holds no backend detail, so
/// it is safe to show.
class OrvixSyncResult {
  const OrvixSyncResult({required this.credentials, required this.state});

  static const skipped = OrvixSyncResult(
    credentials: OrvixSyncStatus.skipped,
    state: OrvixSyncStatus.skipped,
  );

  final OrvixSyncStatus credentials;
  final OrvixSyncStatus state;

  bool get credentialsFailed => credentials == OrvixSyncStatus.failed;
  bool get stateFailed => state == OrvixSyncStatus.failed;
  bool get hasFailure => credentialsFailed || stateFailed;

  /// What did not sync, as one or two sentences for the user, or null when
  /// nothing failed. Callers add how to retry.
  String? get problem {
    if (credentialsFailed && stateFailed) {
      return 'Your cloud data did not sync.';
    }
    if (credentialsFailed) {
      return 'Your library, watchlist, progress and settings synced, but your '
          'cloud provider connections did not. Providers connected on this '
          'device stay connected.';
    }
    if (stateFailed) {
      return 'Your cloud provider connections synced, but your library, '
          'watchlist, progress and settings did not.';
    }
    return null;
  }
}

/// A successful sign-in, sign-up or email verification, with the sync that
/// followed it. A sync problem never means the sign-in failed.
class OrvixSignInResult extends OrvixAuthResult {
  OrvixSignInResult(OrvixAuthResult auth, {this.sync})
      : super(user: auth.user, hasSession: auth.hasSession);

  /// Null when no sync ran (no session yet).
  final OrvixSyncResult? sync;
}

/// What happened to the account copy of a provider credential change.
enum ProviderCredentialSyncResult {
  /// Not signed in: the change stays on this device.
  localOnly,

  /// The account copy matches this device.
  synced,

  /// The account could not be updated. This device keeps its credentials
  /// and the next sync retries.
  failed,
}

/// What this device last reconciled with one account's credential cloud
/// copy. Holds only SHA-256 fingerprints and key names, never values.
class _CredentialSyncState {
  _CredentialSyncState({
    this.userId,
    Map<String, String>? synced,
    Set<String>? removed,
  })  : synced = synced ?? <String, String>{},
        removed = removed ?? <String>{};

  final String? userId;

  /// Key -> fingerprint of this device's value after the last sync.
  final Map<String, String> synced;

  /// Keys of providers disconnected here whose removal has not reached the
  /// cloud yet.
  final Set<String> removed;
}
