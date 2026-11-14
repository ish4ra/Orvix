import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'watch_party_backend.dart';
import 'watch_party_models.dart';

/// Watch Party on Supabase: room calls are RPCs
/// (`supabase/migrations/20261112120000_create_watch_party.sql`) and room
/// events arrive on a private Realtime Broadcast topic.
///
/// Only the public app key and the signed-in user's session are used. The
/// app never sends on the topic: the database does, after it has accepted a
/// change. Nothing about a stream, a source or a provider account is sent.
class SupabaseWatchPartyBackend implements WatchPartyBackend {
  SupabaseWatchPartyBackend({SupabaseClient? client}) : _override = client;

  final SupabaseClient? _override;

  SupabaseClient get _client => _override ?? Supabase.instance.client;

  static const _timeout = Duration(seconds: 12);

  @override
  bool get isSignedIn => _client.auth.currentSession != null;

  Future<Map<Object?, Object?>> _call(
    String function,
    Map<String, dynamic> params,
  ) async {
    final Object? raw;
    try {
      raw = await _client.rpc(function, params: params).timeout(_timeout);
    } on PostgrestException catch (error) {
      throw WatchPartyException(_fromPostgrest(error));
    } on TimeoutException {
      throw const WatchPartyException(WatchPartyError.network);
    } catch (_) {
      // Socket, TLS and HTTP client failures.
      throw const WatchPartyException(WatchPartyError.network);
    }
    if (raw is! Map) {
      throw const WatchPartyException(WatchPartyError.unknown);
    }
    if (raw['ok'] != true) {
      throw WatchPartyException(
        WatchPartyError.fromCode(raw['error']?.toString()),
      );
    }
    return raw;
  }

  static WatchPartyError _fromPostgrest(PostgrestException error) {
    switch (error.code) {
      // The function is not there: the migration is not deployed.
      case 'PGRST202' || '42883':
        return WatchPartyError.unavailable;
      // Not allowed to execute it: no signed-in session.
      case '42501' || 'PGRST301' || 'PGRST302' || 'PGRST303':
        return WatchPartyError.authRequired;
    }
    return WatchPartyError.unknown;
  }

  WatchPartySnapshot _snapshot(Map<Object?, Object?> raw) {
    final snapshot = WatchPartySnapshot.fromJson(raw);
    if (snapshot == null) {
      throw const WatchPartyException(WatchPartyError.unknown);
    }
    return snapshot;
  }

  @override
  Future<WatchPartySnapshot> createRoom(String displayName) async =>
      _snapshot(await _call('watch_party_create', {
        'p_display_name': displayName,
      }));

  @override
  Future<WatchPartySnapshot> joinRoom(
    String inviteCode,
    String displayName,
  ) async =>
      _snapshot(await _call('watch_party_join', {
        'p_invite_code': inviteCode,
        'p_display_name': displayName,
      }));

  @override
  Future<void> leaveRoom(String roomId) async {
    await _call('watch_party_leave', {'p_room_id': roomId});
  }

  @override
  Future<WatchPartySnapshot> sync(
    String roomId, {
    int? afterChatSeq,
    bool? ready,
    bool? buffering,
    String? mediaKey,
    int? durationMs,
  }) async =>
      _snapshot(await _call('watch_party_sync', {
        'p_room_id': roomId,
        'p_after_chat_seq': afterChatSeq,
        'p_ready': ready,
        'p_buffering': buffering,
        'p_media_key': mediaKey,
        'p_duration_ms': durationMs,
      }));

  @override
  Future<WatchPartySnapshot> setMedia(
    String roomId,
    WatchPartyMedia media,
  ) async =>
      _snapshot(await _call('watch_party_set_media', {
        'p_room_id': roomId,
        'p_kind': media.kindName,
        'p_media_id': media.id,
        'p_season': media.season,
        'p_episode': media.episode,
        'p_title': media.title,
        'p_year': media.year,
      }));

  @override
  Future<WatchPartySnapshot> setPlayback(
    String roomId, {
    required bool playing,
    required int positionMs,
    required int clientSeq,
    int? observedAtMs,
  }) async =>
      _snapshot(await _call('watch_party_set_playback', {
        'p_room_id': roomId,
        'p_playing': playing,
        'p_position_ms': positionMs,
        'p_client_seq': clientSeq,
        'p_observed_at_ms': observedAtMs,
      }));

  @override
  Future<WatchPartyMessage> sendMessage(
    String roomId,
    String body,
    String clientId,
  ) async {
    final raw = await _call('watch_party_send_message', {
      'p_room_id': roomId,
      'p_body': body,
      'p_client_id': clientId,
    });
    final message = WatchPartyMessage.fromJson(raw['message']);
    if (message == null) {
      throw const WatchPartyException(WatchPartyError.unknown);
    }
    return message;
  }

  @override
  Future<WatchPartySnapshot> removeParticipant(
    String roomId,
    String participantId,
  ) async =>
      _snapshot(await _call('watch_party_remove_participant', {
        'p_room_id': roomId,
        'p_participant_id': participantId,
      }));

  @override
  Future<WatchPartySnapshot> transferHost(
    String roomId,
    String participantId,
  ) async =>
      _snapshot(await _call('watch_party_transfer_host', {
        'p_room_id': roomId,
        'p_participant_id': participantId,
      }));

  @override
  Future<void> closeRoom(String roomId) async {
    await _call('watch_party_close', {'p_room_id': roomId});
  }

  @override
  WatchPartyChannel openChannel(String topic) =>
      _SupabaseWatchPartyChannel(_client, topic);
}

class _SupabaseWatchPartyChannel implements WatchPartyChannel {
  _SupabaseWatchPartyChannel(this._client, String topic) {
    // Private: Realtime checks the listener against the row level security
    // policy on realtime.messages before letting them join.
    final channel = _client.channel(
      topic,
      opts: const RealtimeChannelConfig(private: true),
    );
    _channel = channel;
    for (final event in _events) {
      channel.onBroadcast(
        event: event,
        callback: (payload) {
          final parsed = WatchPartyEvent.parse(event, payload);
          if (parsed != null && !_eventController.isClosed) {
            _eventController.add(parsed);
          }
        },
      );
    }
    try {
      channel.subscribe((status, _) {
        if (_connectedController.isClosed) return;
        _connectedController.add(status == RealtimeSubscribeStatus.subscribed);
      });
    } catch (_) {
      // The session keeps working by polling.
    }
  }

  static const _events = ['state', 'roster', 'chat', 'closed', 'rekey'];

  final SupabaseClient _client;
  late final RealtimeChannel _channel;
  final _eventController = StreamController<WatchPartyEvent>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();

  @override
  Stream<WatchPartyEvent> get events => _eventController.stream;

  @override
  Stream<bool> get connected => _connectedController.stream;

  @override
  Future<void> close() async {
    await _eventController.close();
    await _connectedController.close();
    try {
      await _client.removeChannel(_channel);
    } catch (_) {}
  }
}
