import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_service.dart';

class CloudSyncService extends ChangeNotifier {
  CloudSyncService(this.account);

  final AccountService account;

  static const _table = 'orvix_sync_state';
  static const _libraryKey = 'pikora_media_library_v1';
  static const _watchlistKey = 'pikora_watchlist_v1';
  static const _progressKey = 'pikora_continue_watching_v1';
  static const _lastUserKey = 'orvix_sync_last_user_v1';

  static const _settingsKeys = <String>{
    'orvix_preferred_cloud_v1',
    'pikora_home_sections_v1',
    'pikora_source_addons',
    'pikora_integrated_torrentio_url_v1',
    'pikora_source_sort_mode_v2',
    'orvix_source_priority_v6',
    'orvix_show_3d_sources_v1',
    'orvix_show_low_quality_sources_v1',
    'orvix_preferred_release_groups_v1',
    'orvix_source_result_limit_v1',
  };
  static const _settingsPrefixes = <String>['orvix_pinned_source_v1_'];

  Timer? _timer;
  bool _started = false;
  bool _syncing = false;
  String? _lastError;
  DateTime? _lastSyncedAt;

  bool get syncing => _syncing;
  String? get lastError => _lastError;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  void start() {
    if (_started) return;
    _started = true;
    account.addListener(_handleAccountChanged);
    _timer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (account.signedIn) unawaited(syncNow());
    });
    if (account.signedIn) unawaited(syncNow());
  }

  void _handleAccountChanged() {
    notifyListeners();
    if (account.signedIn) unawaited(syncNow());
  }

  Future<bool> syncNow() async {
    if (!account.backendConfigured || !account.signedIn || _syncing) {
      return false;
    }

    _syncing = true;
    _lastError = null;
    notifyListeners();

    try {
      final user = account.currentUser!;
      final prefs = await SharedPreferences.getInstance();
      final previousUser = prefs.getString(_lastUserKey);
      if (previousUser != null &&
          previousUser.isNotEmpty &&
          previousUser != user.id) {
        await _clearSyncedLocalData(prefs);
      }

      final response = await account.client
          .from(_table)
          .select()
          .eq('user_id', user.id)
          .maybeSingle();
      final remote = response == null
          ? null
          : Map<String, dynamic>.from(response as Map);
      final initializedKey = _metaKey(user.id, 'initialized');
      final initialized = prefs.getBool(initializedKey) ?? false;

      if (!initialized) {
        await _firstSync(prefs, user.id, remote);
      } else {
        await _regularSync(prefs, user.id, remote);
      }

      await prefs.setString(_lastUserKey, user.id);
      _lastSyncedAt = DateTime.now();
      _lastError = null;
      notifyListeners();
      return true;
    } catch (error) {
      _lastError = _friendlyError(error);
      notifyListeners();
      return false;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _firstSync(
    SharedPreferences prefs,
    String userId,
    Map<String, dynamic>? remote,
  ) async {
    var settings = _captureSettings(prefs);
    var library = _captureLibrary(prefs);
    var progress = _captureProgress(prefs);
    final now = DateTime.now().toUtc();

    DateTime settingsAt = now;
    DateTime libraryAt = now;
    DateTime progressAt = now;

    if (remote != null) {
      final remoteSettings = _map(remote['settings']);
      final remoteLibrary = _map(remote['library']);
      final remoteProgress = _map(remote['progress']);

      // Account settings win on first sign-in. Guest library/watch state is
      // merged so a user does not lose items collected before creating/login.
      await _applySettings(prefs, remoteSettings);
      settings = _captureSettings(prefs);

      library = _mergeLibrary(library, remoteLibrary);
      progress = _mergeProgress(progress, remoteProgress);
      await _applyLibrary(prefs, library);
      await _applyProgress(prefs, progress);

      settingsAt = _date(remote['settings_updated_at']) ?? now;
      libraryAt = now;
      progressAt = now;
    }

    await _upsert(
      userId: userId,
      settings: settings,
      library: library,
      progress: progress,
      settingsAt: settingsAt,
      libraryAt: libraryAt,
      progressAt: progressAt,
    );
    await _saveMetadata(
      prefs,
      userId,
      settings: settings,
      library: library,
      progress: progress,
      settingsAt: settingsAt,
      libraryAt: libraryAt,
      progressAt: progressAt,
    );
    await prefs.setBool(_metaKey(userId, 'initialized'), true);
  }

  Future<void> _regularSync(
    SharedPreferences prefs,
    String userId,
    Map<String, dynamic>? remote,
  ) async {
    var settings = _captureSettings(prefs);
    var library = _captureLibrary(prefs);
    var progress = _captureProgress(prefs);

    var settingsAt = await _localTimestamp(
      prefs,
      userId,
      'settings',
      settings,
    );
    var libraryAt = await _localTimestamp(
      prefs,
      userId,
      'library',
      library,
    );
    var progressAt = await _localTimestamp(
      prefs,
      userId,
      'progress',
      progress,
    );

    if (remote != null) {
      final remoteSettingsAt = _date(remote['settings_updated_at']);
      final remoteLibraryAt = _date(remote['library_updated_at']);
      final remoteProgressAt = _date(remote['progress_updated_at']);

      if (remoteSettingsAt != null && remoteSettingsAt.isAfter(settingsAt)) {
        await _applySettings(prefs, _map(remote['settings']));
        settings = _captureSettings(prefs);
        settingsAt = remoteSettingsAt;
      }
      if (remoteLibraryAt != null && remoteLibraryAt.isAfter(libraryAt)) {
        library = _map(remote['library']);
        await _applyLibrary(prefs, library);
        libraryAt = remoteLibraryAt;
      }
      if (remoteProgressAt != null && remoteProgressAt.isAfter(progressAt)) {
        progress = _map(remote['progress']);
        await _applyProgress(prefs, progress);
        progressAt = remoteProgressAt;
      }
    }

    await _upsert(
      userId: userId,
      settings: settings,
      library: library,
      progress: progress,
      settingsAt: settingsAt,
      libraryAt: libraryAt,
      progressAt: progressAt,
    );
    await _saveMetadata(
      prefs,
      userId,
      settings: settings,
      library: library,
      progress: progress,
      settingsAt: settingsAt,
      libraryAt: libraryAt,
      progressAt: progressAt,
    );
  }

  Future<DateTime> _localTimestamp(
    SharedPreferences prefs,
    String userId,
    String category,
    Map<String, dynamic> snapshot,
  ) async {
    final hashKey = _metaKey(userId, '${category}_hash');
    final timestampKey = _metaKey(userId, '${category}_at');
    final currentHash = _hash(snapshot);
    final previousHash = prefs.getString(hashKey);
    var timestamp =
        DateTime.tryParse(prefs.getString(timestampKey) ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    if (previousHash != currentHash) {
      timestamp = DateTime.now().toUtc();
      await prefs.setString(hashKey, currentHash);
      await prefs.setString(timestampKey, timestamp.toIso8601String());
    }
    return timestamp;
  }

  Future<void> _saveMetadata(
    SharedPreferences prefs,
    String userId, {
    required Map<String, dynamic> settings,
    required Map<String, dynamic> library,
    required Map<String, dynamic> progress,
    required DateTime settingsAt,
    required DateTime libraryAt,
    required DateTime progressAt,
  }) async {
    await prefs.setString(_metaKey(userId, 'settings_hash'), _hash(settings));
    await prefs.setString(
      _metaKey(userId, 'settings_at'),
      settingsAt.toUtc().toIso8601String(),
    );
    await prefs.setString(_metaKey(userId, 'library_hash'), _hash(library));
    await prefs.setString(
      _metaKey(userId, 'library_at'),
      libraryAt.toUtc().toIso8601String(),
    );
    await prefs.setString(_metaKey(userId, 'progress_hash'), _hash(progress));
    await prefs.setString(
      _metaKey(userId, 'progress_at'),
      progressAt.toUtc().toIso8601String(),
    );
  }

  Future<void> _upsert({
    required String userId,
    required Map<String, dynamic> settings,
    required Map<String, dynamic> library,
    required Map<String, dynamic> progress,
    required DateTime settingsAt,
    required DateTime libraryAt,
    required DateTime progressAt,
  }) async {
    await account.client.from(_table).upsert({
      'user_id': userId,
      'settings': settings,
      'library': library,
      'progress': progress,
      'settings_updated_at': settingsAt.toUtc().toIso8601String(),
      'library_updated_at': libraryAt.toUtc().toIso8601String(),
      'progress_updated_at': progressAt.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _captureSettings(SharedPreferences prefs) {
    final keys = prefs.getKeys().where(_isSyncableSettingKey).toList()..sort();
    final out = <String, dynamic>{};
    for (final key in keys) {
      final value = prefs.get(key);
      if (value is List<String>) {
        out[key] = [...value];
      } else if (value is String ||
          value is bool ||
          value is int ||
          value is double) {
        out[key] = value;
      }
    }
    return out;
  }

  Future<void> _applySettings(
    SharedPreferences prefs,
    Map<String, dynamic> settings,
  ) async {
    final localKeys = prefs.getKeys().where(_isSyncableSettingKey).toList();
    for (final key in localKeys) {
      if (!settings.containsKey(key)) await prefs.remove(key);
    }
    for (final entry in settings.entries) {
      if (!_isSyncableSettingKey(entry.key)) continue;
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is num) {
        await prefs.setDouble(entry.key, value.toDouble());
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(
          entry.key,
          value.map((item) => item.toString()).toList(growable: false),
        );
      }
    }
  }

  Map<String, dynamic> _captureLibrary(SharedPreferences prefs) => {
        'library': _json(prefs.getString(_libraryKey), const <dynamic>[]),
        'watchlist': _json(prefs.getString(_watchlistKey), const <dynamic>[]),
      };

  Future<void> _applyLibrary(
    SharedPreferences prefs,
    Map<String, dynamic> library,
  ) async {
    final items = library['library'];
    final watchlist = library['watchlist'];
    await prefs.setString(
      _libraryKey,
      jsonEncode(items is List ? items : const <dynamic>[]),
    );
    await prefs.setString(
      _watchlistKey,
      jsonEncode(watchlist is List ? watchlist : const <dynamic>[]),
    );
  }

  Map<String, dynamic> _captureProgress(SharedPreferences prefs) =>
      _map(_json(prefs.getString(_progressKey), const <String, dynamic>{}));

  Future<void> _applyProgress(
    SharedPreferences prefs,
    Map<String, dynamic> progress,
  ) async {
    await prefs.setString(_progressKey, jsonEncode(progress));
  }

  Map<String, dynamic> _mergeLibrary(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) => {
        'library': _mergeMediaList(local['library'], remote['library']),
        'watchlist': _mergeMediaList(local['watchlist'], remote['watchlist']),
      };

  List<dynamic> _mergeMediaList(dynamic local, dynamic remote) {
    final out = <dynamic>[];
    final seen = <String>{};
    for (final source in [local, remote]) {
      if (source is! List) continue;
      for (final raw in source) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = item['id']?.toString() ?? '';
        final kind = item['kind']?.toString() ?? '';
        final key = '$kind:$id';
        if (id.isNotEmpty && seen.add(key)) out.add(item);
      }
    }
    return out;
  }

  Map<String, dynamic> _mergeProgress(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final out = <String, dynamic>{...remote};
    for (final entry in local.entries) {
      final remoteEntry = out[entry.key];
      if (remoteEntry is! Map || entry.value is! Map) {
        out[entry.key] = entry.value;
        continue;
      }
      final localAt = _date((entry.value as Map)['updatedAt']);
      final remoteAt = _date(remoteEntry['updatedAt']);
      if (remoteAt == null || (localAt != null && localAt.isAfter(remoteAt))) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  Future<void> prepareForSignOut() async {
    if (!account.signedIn) return;
    final userId = account.currentUser!.id;
    await syncNow();
    final prefs = await SharedPreferences.getInstance();
    await _clearSyncedLocalData(prefs);
    await _clearSyncMetadata(prefs, userId);
    await prefs.remove(_lastUserKey);
    _lastSyncedAt = null;
    _lastError = null;
    notifyListeners();
  }

  Future<void> _clearSyncedLocalData(SharedPreferences prefs) async {
    final keys = prefs.getKeys().where(_isSyncableSettingKey).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
    await prefs.remove(_libraryKey);
    await prefs.remove(_watchlistKey);
    await prefs.remove(_progressKey);
  }

  Future<void> _clearSyncMetadata(
    SharedPreferences prefs,
    String userId,
  ) async {
    final prefix = 'orvix_sync_meta_${userId}_';
    final keys = prefs.getKeys().where((key) => key.startsWith(prefix)).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  bool _isSyncableSettingKey(String key) =>
      _settingsKeys.contains(key) ||
      _settingsPrefixes.any((prefix) => key.startsWith(prefix));

  String _metaKey(String userId, String suffix) =>
      'orvix_sync_meta_${userId}_$suffix';

  dynamic _json(String? raw, dynamic fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return fallback;
    }
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) return {...value};
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return <String, dynamic>{};
  }

  DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  String _hash(Map<String, dynamic> value) {
    final canonical = jsonEncode(_canonicalize(value));
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, dynamic>{
        for (final entry in entries)
          entry.key.toString(): _canonicalize(entry.value),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    return text.isEmpty ? 'Cloud sync failed.' : text;
  }

  @override
  void dispose() {
    _timer?.cancel();
    account.removeListener(_handleAccountChanged);
    super.dispose();
  }
}
