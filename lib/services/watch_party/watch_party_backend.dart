import 'watch_party_models.dart';

/// Backend boundary for Watch Party. The session, the screens and the tests
/// only use this interface; the Supabase implementation lives in
/// supabase_watch_party_backend.dart.
///
/// Every method that fails throws a [WatchPartyException].
abstract interface class WatchPartyBackend {
  /// Whether an Orvix account is signed in. Rooms need one.
  bool get isSignedIn;

  Future<WatchPartySnapshot> createRoom(String displayName);

  Future<WatchPartySnapshot> joinRoom(String inviteCode, String displayName);

  Future<void> leaveRoom(String roomId);

  /// Heartbeat, status report and catch-up in one request.
  Future<WatchPartySnapshot> sync(
    String roomId, {
    int? afterChatSeq,
    bool? ready,
    bool? buffering,
    String? mediaKey,
    int? durationMs,
  });

  Future<WatchPartySnapshot> setMedia(String roomId, WatchPartyMedia media);

  Future<WatchPartySnapshot> setPlayback(
    String roomId, {
    required bool playing,
    required int positionMs,
    required int clientSeq,
    int? observedAtMs,
  });

  Future<WatchPartyMessage> sendMessage(
    String roomId,
    String body,
    String clientId,
  );

  Future<WatchPartySnapshot> removeParticipant(
    String roomId,
    String participantId,
  );

  Future<WatchPartySnapshot> transferHost(String roomId, String participantId);

  Future<void> closeRoom(String roomId);

  /// Starts listening to a room's private Realtime topic.
  WatchPartyChannel openChannel(String topic);
}

/// A subscription to one room topic.
abstract interface class WatchPartyChannel {
  /// Room events, in the order they arrive (not necessarily the order they
  /// happened; the session orders them by their sequence numbers).
  Stream<WatchPartyEvent> get events;

  /// True while the topic is subscribed. While false the session polls.
  Stream<bool> get connected;

  Future<void> close();
}
