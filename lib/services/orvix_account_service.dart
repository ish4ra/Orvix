import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OrvixAccountService {
  OrvixAccountService._();

  static const table = 'orvix_user_state';
  static const _watchlistKey = 'pikora_watchlist_v1';
  static const _libraryKey = 'pikora_media_library_v1';
  static const _progressKey = 'pikora_continue_watching_v1';
  static const _localOnlyPreferenceKeys = <String>{
    'pikora_source_addons',
    'pikora_integrated_torrentio_url_v1',
  };

  static SupabaseClient get _client => Supabase.instance.client;
  static User? get currentUser => _client.auth.currentUser;
  static bool get isSignedIn => currentUser != null;

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await mergeCloudIntoLocal();
    return response;
  }

  static Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signUp(
      email: email.trim(),
      password: password,
    );
    if (response.session != null) {
      await mergeCloudIntoLocal();
    }
    return response;
  }

  static Future<AuthResponse> verifySignupOtp({
    required String email,
    required String token,
  }) async {
    // Supabase's six-digit email OTP flow is verified as an email OTP.
    // `signup` is still required by resend(), but using it here can make a
    // freshly generated email code fail with the generic otp_expired error.
    final response = await _client.auth.verifyOTP(
      type: OtpType.email,
      email: email.trim(),
      token: token.trim(),
    );
    if (response.session != null) {
      await mergeCloudIntoLocal();
    }
    return response;
  }

  static Future<ResendResponse> resendSignupConfirmation({
    required String email,
  }) {
    // Supabase resend only accepts the signup type for signup confirmations.
    return _client.auth.resend(
      type: OtpType.signup,
      email: email.trim(),
    );
  }

  static Future<void> signOut() => _client.auth.signOut();

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

    await _client.from(table).upsert({
      'user_id': user.id,
      'watchlist': watchlist,
      'library': library,
      'progress': progress,
      'home_sections':
          preferences['pikora_home_sections_v1'] ?? const <dynamic>[],
      'preferred_cloud':
          preferences['orvix_preferred_cloud_v1']?.toString() ?? 'pikpak',
      'preferences': preferences,
    }, onConflict: 'user_id');
  }

  static Future<void> mergeCloudIntoLocal() async {
    final user = currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final rows =
        await _client.from(table).select().eq('user_id', user.id).limit(1);

    if (rows.isEmpty) {
      await pushLocalStateIfSignedIn();
      return;
    }

    final remote = Map<String, dynamic>.from(rows.first);
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

    await _client.from(table).upsert({
      'user_id': user.id,
      'watchlist': mergedWatchlist,
      'library': mergedLibrary,
      'progress': mergedProgress,
      'home_sections':
          mergedPreferences['pikora_home_sections_v1'] ?? const <dynamic>[],
      'preferred_cloud':
          mergedPreferences['orvix_preferred_cloud_v1']?.toString() ?? 'pikpak',
      'preferences': mergedPreferences,
    }, onConflict: 'user_id');
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
