import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/media_item.dart';
import 'supabase_watch_party_backend.dart';
import 'watch_party_backend.dart';
import 'watch_party_chat_policy.dart';
import 'watch_party_clock.dart';
import 'watch_party_feature.dart';
import 'watch_party_models.dart';
import 'watch_party_player_adapter.dart';
import 'watch_party_session.dart';

/// The app's single Watch Party entry point: at most one room at a time.
///
/// Player screens call [attachPlayer] when playback has started. With the
/// feature off, or with no room joined, that returns null and the player is
/// left completely alone.
class WatchPartyService {
  WatchPartyService._();

  static final WatchPartyService instance = WatchPartyService._();

  static const _nameKey = 'orvix_watch_party_name_v1';

  WatchPartyBackend _backend = SupabaseWatchPartyBackend();

  WatchPartyBackend get backend => _backend;

  /// Tests replace the backend.
  @visibleForTesting
  set backend(WatchPartyBackend value) => _backend = value;

  /// The room this device is in, or null.
  final ValueNotifier<WatchPartySession?> session = ValueNotifier(null);

  WatchPartySession? get current =>
      WatchPartyFeature.enabled ? session.value : null;

  bool get isSignedIn => _backend.isSignedIn;

  /// The name last used, to prefill the form.
  Future<String> savedName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_nameKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _saveName(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_nameKey, name);
    } catch (_) {}
  }

  String _requireName(String input) {
    final name = WatchPartyChatPolicy.cleanName(input);
    if (name == null) {
      throw const WatchPartyException(WatchPartyError.invalidName);
    }
    return name;
  }

  void _requireReady() {
    if (!WatchPartyFeature.enabled) {
      throw const WatchPartyException(WatchPartyError.unavailable);
    }
    if (!_backend.isSignedIn) {
      throw const WatchPartyException(WatchPartyError.authRequired);
    }
  }

  Future<WatchPartySession> _start(
    String name,
    Future<WatchPartySnapshot> Function(WatchPartyClock clock) open,
  ) async {
    await leave();
    final clock = WatchPartyClock();
    final sentAt = clock.localNowMs;
    final snapshot = await open(clock);
    final created = WatchPartySession(
      backend: _backend,
      snapshot: snapshot,
      displayName: name,
      clock: clock,
      snapshotSentAtLocalMs: sentAt,
    );
    created.addListener(() {
      // A room that ended (closed, removed, expired) is forgotten.
      if (created.isEnded && identical(session.value, created)) {
        session.value = null;
      }
    });
    session.value = created;
    await _saveName(name);
    return created;
  }

  /// Creates a private room. Throws a [WatchPartyException] on failure.
  Future<WatchPartySession> create(String displayName) {
    _requireReady();
    final name = _requireName(displayName);
    return _start(name, (_) => _backend.createRoom(name));
  }

  /// Joins a room by invite code. Throws a [WatchPartyException] on failure.
  Future<WatchPartySession> join(String inviteCode, String displayName) {
    _requireReady();
    final name = _requireName(displayName);
    final code = WatchPartyRoom.normalizeCode(inviteCode);
    if (code.length != 8) {
      throw const WatchPartyException(WatchPartyError.notFound);
    }
    return _start(name, (_) => _backend.joinRoom(code, name));
  }

  Future<void> leave() async {
    final active = session.value;
    if (active == null) return;
    session.value = null;
    await active.leave();
  }

  /// Called by a player screen once playback has started. Returns null,
  /// touching nothing, unless Watch Party is on and a room is joined.
  WatchPartyPlayerBinding? attachPlayer(
    WatchPartyPlayerAdapter adapter, {
    MediaItem? item,
    EpisodeItem? episode,
  }) {
    final active = current;
    if (active == null || active.isEnded) return null;
    return active.attachPlayer(
      adapter,
      WatchPartyMedia.fromItem(item, episode),
    );
  }
}
