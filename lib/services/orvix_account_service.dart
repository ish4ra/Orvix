import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static OrvixAccountBackend backend = SupabaseOrvixAccountBackend();

  static const _watchlistKey = 'pikora_watchlist_v1';
  static const _libraryKey = 'pikora_media_library_v1';
  static const _progressKey = 'pikora_continue_watching_v1';
  static const _localOnlyPreferenceKeys = <String>{
    'pikora_source_addons',
    'pikora_integrated_torrentio_url_v1',
  };

  static const _credentialKeys = <String>[
    'orvix_torbox_api_token_v1',
    'pikpak_access_token',
    'pikpak_refresh_token',
    'pikpak_username',
    'pikpak_user_id',
  ];
  static final FlutterSecureStorage _secureStorage = createOrvixSecureStorage();

  static OrvixAccountUser? get currentUser => backend.currentUser;
  static bool get isSignedIn => currentUser != null;

  static Future<OrvixAuthResult> signIn({
    required String email,
    required String password,
  }) async {
    final response = await backend.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await mergeCloudIntoLocal();
    return response;
  }

  static Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  }) async {
    final response = await backend.signUp(
      email: email.trim(),
      password: password,
    );
    if (response.hasSession) {
      await mergeCloudIntoLocal();
    }
    return response;
  }

  static Future<OrvixAuthResult> verifySignupOtp({
    required String email,
    required String token,
  }) async {
    final response = await backend.verifySignupCode(
      email: email.trim(),
      token: token.trim(),
    );
    if (response.hasSession) {
      await mergeCloudIntoLocal();
    }
    return response;
  }

  static Future<void> resendSignupConfirmation({
    required String email,
  }) {
    return backend.resendSignupConfirmation(email: email.trim());
  }

  static Future<void> signOut() => backend.signOut();

  static Future<void> restoreSignedInState() async {
    if (!isSignedIn) return;
    try {
      await mergeCloudIntoLocal();
    } catch (_) {
      // Keep Orvix fully usable offline/local-first when cloud sync is unavailable.
    }
  }

  static Future<void> pushLocalStateIfSignedIn() async {
    final user = currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final watchlist =
        _decodeJsonValue(prefs.getString(_watchlistKey), const <dynamic>[]);
    final library =
        _decodeJsonValue(prefs.getString(_libraryKey), const <dynamic>[]);
    final progress = _decodeJsonValue(
        prefs.getString(_progressKey), const <String, dynamic>{});
    final preferences = _collectAppPreferences(prefs);

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

  static Future<void> syncCredentialsIfSignedIn() async {
    if (!isSignedIn) return;
    final local = <String, String>{};
    for (final key in _credentialKeys) {
      final value = await _secureStorage.read(key: key);
      if (value != null && value.isNotEmpty) local[key] = value;
    }

    final remote = await backend.loadCredentials();

    final merged = <String, String>{...remote, ...local}
      ..removeWhere((_, value) => value.isEmpty);
    for (final entry in merged.entries) {
      if ((await _secureStorage.read(key: entry.key))?.isNotEmpty != true) {
        await _secureStorage.write(key: entry.key, value: entry.value);
      }
    }
    if (merged.isNotEmpty) {
      await backend.saveCredentials(merged);
    }
  }

  static Future<void> mergeCloudIntoLocal() async {
    final user = currentUser;
    if (user == null) return;

    await syncCredentialsIfSignedIn();

    final prefs = await SharedPreferences.getInstance();
    final stored = await backend.loadUserState(user.id);

    if (stored == null) {
      await pushLocalStateIfSignedIn();
      return;
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
