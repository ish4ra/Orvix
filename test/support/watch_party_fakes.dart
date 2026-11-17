// Test doubles for Watch Party: a clock that only moves when told to, an
// in-memory room that follows the same rules as the database functions, and
// a player that plays, stalls and seeks on the fake clock.

import 'dart:async';

import 'package:orvix/models/media_item.dart';
import 'package:orvix/services/watch_party/watch_party_backend.dart';
import 'package:orvix/services/watch_party/watch_party_clock.dart';
import 'package:orvix/services/watch_party/watch_party_models.dart';
import 'package:orvix/services/watch_party/watch_party_player_adapter.dart';

class FakeTime {
  int nowMs = 1000;
}

const inception = WatchPartyMedia(
  kind: MediaKind.movie,
  id: 'tt1375666',
  title: 'Inception',
  year: '2010',
);

const pilot = WatchPartyMedia(
  kind: MediaKind.series,
  id: 'tt0903747',
  season: 1,
  episode: 1,
  title: 'Breaking Bad',
);

const secondEpisode = WatchPartyMedia(
  kind: MediaKind.series,
  id: 'tt0903747',
  season: 1,
  episode: 2,
  title: 'Breaking Bad',
);

class FakeChannel implements WatchPartyChannel {
  FakeChannel(this.topic);

  final String topic;
  final _events = StreamController<WatchPartyEvent>.broadcast(sync: true);
  final _connected = StreamController<bool>.broadcast(sync: true);
  bool closed = false;

  @override
  Stream<WatchPartyEvent> get events => _events.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  void emit(WatchPartyEvent event) {
    if (!closed) _events.add(event);
  }

  void setConnected(bool value) {
    if (!closed) _connected.add(value);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

typedef PlaybackCall = ({bool playing, int positionMs, int clientSeq});
typedef SyncCall = ({
  bool? ready,
  bool? buffering,
  String? mediaKey,
  int? durationMs,
  int? afterChatSeq,
});

/// One room, seen from one member ("self"). Mirrors the database rules that
/// matter to the client: state numbers, host-only control, stale commands,
/// chat numbering.
class FakeRoomBackend implements WatchPartyBackend {
  FakeRoomBackend(this.time, {this.selfIsHost = false});

  final FakeTime time;

  /// The server clock runs this far ahead of the device's.
  int serverOffsetMs = 250000;
  bool signedIn = true;

  /// Every request fails as if the network were down.
  bool offline = false;

  /// The next request fails with this error.
  WatchPartyError? failNext;

  /// Requests named here fail with the given error until removed.
  final failing = <String, WatchPartyError>{};

  /// Holds replies back until [release] is called.
  Completer<void>? gate;

  String roomId = 'room-1';
  String code = 'ABCDEFGH';
  String topic = 'watch_party:key-1';
  bool selfIsHost;
  String selfId = 'p-self';
  String otherId = 'p-other';
  WatchPartyMedia? media;
  int stateSeq = 0;
  bool playing = false;
  int positionMs = 0;
  int atMs = 0;
  int rosterSeq = 1;
  int lastCommandSeq = 0;
  int? otherDurationMs;
  bool selfReady = false;
  bool selfBuffering = false;
  int? selfDurationMs;
  bool otherInRoom = true;

  /// More people in the room, after "self" and "other".
  final extras = <WatchPartyParticipant>[];
  final chat = <WatchPartyMessage>[];
  final clientIds = <String, WatchPartyMessage>{};

  final calls = <String>[];
  final playbackCalls = <PlaybackCall>[];
  final syncCalls = <SyncCall>[];
  final mediaCalls = <WatchPartyMedia>[];
  final channels = <FakeChannel>[];

  int get serverNowMs => time.nowMs + serverOffsetMs;
  FakeChannel get channel => channels.last;
  String get hostId => selfIsHost ? selfId : otherId;

  @override
  bool get isSignedIn => signedIn;

  WatchPartyPlayback get playback => WatchPartyPlayback(
        seq: stateSeq,
        playing: playing,
        positionMs: positionMs,
        atMs: atMs,
      );

  WatchPartyRoster get roster => WatchPartyRoster(
        seq: rosterSeq,
        hostId: hostId,
        participants: [
          WatchPartyParticipant(
            id: selfId,
            name: 'Me',
            ready: selfReady,
            buffering: selfBuffering,
            durationMs: selfDurationMs,
          ),
          if (otherInRoom)
            WatchPartyParticipant(
              id: otherId,
              name: 'Friend',
              ready: true,
              durationMs: otherDurationMs,
            ),
          ...extras,
        ],
      );

  WatchPartySnapshot snapshot({int? afterChatSeq, bool stale = false}) =>
      WatchPartySnapshot(
        serverTimeMs: serverNowMs,
        you: selfId,
        room: WatchPartyRoom(
          id: roomId,
          code: code,
          topic: topic,
          playback: playback,
          media: media,
          chatSeq: chat.length,
        ),
        roster: roster,
        messages: [
          for (final message in chat)
            if (message.seq > (afterChatSeq ?? chat.length)) message,
        ],
        commandSeq: lastCommandSeq,
        stale: stale,
      );

  // --- What the rest of the room does (test controls) ---------------------

  /// The room moves to a new playback state, as after a host command.
  WatchPartyPlayback remoteState({
    required bool playing,
    required int positionMs,
    bool announce = true,
  }) {
    this.playing = playing;
    this.positionMs = positionMs;
    atMs = serverNowMs;
    stateSeq++;
    final state = playback;
    if (announce) channel.emit(WatchPartyStateEvent(state, media));
    return state;
  }

  WatchPartyMessage remoteChat(String body, {bool announce = true}) {
    final message = WatchPartyMessage(
      seq: chat.length + 1,
      from: otherId,
      name: 'Friend',
      body: body,
      atMs: serverNowMs,
    );
    chat.add(message);
    if (announce) channel.emit(WatchPartyChatEvent(message));
    return message;
  }

  void makeSelfHost(bool value, {bool announce = true}) {
    selfIsHost = value;
    rosterSeq++;
    if (announce) channel.emit(WatchPartyRosterEvent(roster));
  }

  void release() {
    final pending = gate;
    gate = null;
    pending?.complete();
  }

  // --- Backend --------------------------------------------------------------

  Future<void> _enter(String name) async {
    calls.add(name);
    final pending = gate;
    if (pending != null) await pending.future;
    if (offline) throw const WatchPartyException(WatchPartyError.network);
    final once = failNext;
    if (once != null) {
      failNext = null;
      throw WatchPartyException(once);
    }
    final always = failing[name];
    if (always != null) throw WatchPartyException(always);
  }

  @override
  Future<WatchPartySnapshot> createRoom(String displayName) async {
    await _enter('create');
    selfIsHost = true;
    return snapshot();
  }

  @override
  Future<WatchPartySnapshot> joinRoom(
    String inviteCode,
    String displayName,
  ) async {
    await _enter('join');
    if (inviteCode != code) {
      throw const WatchPartyException(WatchPartyError.notFound);
    }
    // Joining returns the latest chat history.
    return snapshot(afterChatSeq: chat.length > 50 ? chat.length - 50 : 0);
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    await _enter('leave');
  }

  @override
  Future<WatchPartySnapshot> sync(
    String roomId, {
    int? afterChatSeq,
    bool? ready,
    bool? buffering,
    String? mediaKey,
    int? durationMs,
  }) async {
    await _enter('sync');
    syncCalls.add((
      ready: ready,
      buffering: buffering,
      mediaKey: mediaKey,
      durationMs: durationMs,
      afterChatSeq: afterChatSeq,
    ));
    final wasReady = selfReady;
    selfReady = ready == true && mediaKey != null && mediaKey == media?.key;
    selfBuffering = buffering ?? selfBuffering;
    selfDurationMs = durationMs ?? selfDurationMs;
    if (selfReady != wasReady) rosterSeq++;
    return snapshot(afterChatSeq: afterChatSeq);
  }

  @override
  Future<WatchPartySnapshot> setMedia(
    String roomId,
    WatchPartyMedia media,
  ) async {
    await _enter('setMedia');
    if (!selfIsHost) throw const WatchPartyException(WatchPartyError.hostOnly);
    mediaCalls.add(media);
    this.media = media;
    playing = false;
    positionMs = 0;
    atMs = serverNowMs;
    stateSeq++;
    return snapshot();
  }

  @override
  Future<WatchPartySnapshot> setPlayback(
    String roomId, {
    required bool playing,
    required int positionMs,
    required int clientSeq,
    int? observedAtMs,
  }) async {
    await _enter('setPlayback');
    if (!selfIsHost) throw const WatchPartyException(WatchPartyError.hostOnly);
    playbackCalls.add(
      (playing: playing, positionMs: positionMs, clientSeq: clientSeq),
    );
    if (clientSeq <= lastCommandSeq) return snapshot(stale: true);
    lastCommandSeq = clientSeq;
    this.playing = playing;
    this.positionMs = positionMs;
    atMs = observedAtMs ?? serverNowMs;
    stateSeq++;
    return snapshot();
  }

  @override
  Future<WatchPartyMessage> sendMessage(
    String roomId,
    String body,
    String clientId,
  ) async {
    await _enter('sendMessage');
    final existing = clientIds[clientId];
    if (existing != null) return existing;
    final message = WatchPartyMessage(
      seq: chat.length + 1,
      from: selfId,
      name: 'Me',
      body: body,
      atMs: serverNowMs,
    );
    chat.add(message);
    clientIds[clientId] = message;
    return message;
  }

  @override
  Future<WatchPartySnapshot> removeParticipant(
    String roomId,
    String participantId,
  ) async {
    await _enter('remove');
    if (!selfIsHost) throw const WatchPartyException(WatchPartyError.hostOnly);
    if (participantId != otherId || !otherInRoom) {
      throw const WatchPartyException(WatchPartyError.invalidParticipant);
    }
    otherInRoom = false;
    rosterSeq++;
    topic = 'watch_party:key-${channels.length + 1}';
    return snapshot();
  }

  @override
  Future<WatchPartySnapshot> transferHost(
    String roomId,
    String participantId,
  ) async {
    await _enter('transfer');
    if (!selfIsHost) throw const WatchPartyException(WatchPartyError.hostOnly);
    selfIsHost = false;
    rosterSeq++;
    return snapshot();
  }

  @override
  Future<void> closeRoom(String roomId) async {
    await _enter('close');
    if (!selfIsHost) throw const WatchPartyException(WatchPartyError.hostOnly);
  }

  @override
  WatchPartyChannel openChannel(String topic) {
    final created = FakeChannel(topic);
    channels.add(created);
    return created;
  }
}

/// A player on the fake clock. Commands from the session are recorded in
/// [commands]; the `user*` methods are the person using the player's own
/// controls.
class FakePlayer extends WatchPartyPlayerAdapter {
  FakePlayer(
    this.time, {
    int positionMs = 0,
    this.playing = true,
    this.durationMs = 7200000,
    this.canChangeRate = true,
  })  : _positionMs = positionMs.toDouble(),
        _advancedAtMs = time.nowMs;

  final FakeTime time;
  bool playing;
  int durationMs;
  bool canChangeRate;
  double rate = 1.0;

  /// Stalled by the test (network trouble).
  bool stalled = false;

  /// How long every seek stalls the player, like a slow source.
  int seekStallMs = 0;
  bool unreadable = false;

  double _positionMs;
  int _advancedAtMs;
  int _stalledUntilMs = 0;

  final commands = <String>[];

  int get seeks => commands.where((c) => c.startsWith('seek')).length;

  void _advance() {
    final now = time.nowMs;
    final from =
        _advancedAtMs > _stalledUntilMs ? _advancedAtMs : _stalledUntilMs;
    if (playing && !stalled && now > from) {
      _positionMs += (now - from) * rate;
    }
    _advancedAtMs = now;
  }

  int get positionMs {
    _advance();
    return _positionMs.round();
  }

  bool get buffering => stalled || time.nowMs < _stalledUntilMs;

  @override
  String get engineName => 'fake';

  @override
  bool get supportsRate => canChangeRate;

  @override
  WatchPartyPlayerReading? read() {
    if (unreadable) return null;
    return WatchPartyPlayerReading(
      playing: playing,
      buffering: playing && buffering,
      positionMs: positionMs,
      durationMs: durationMs,
      rate: rate,
    );
  }

  @override
  Future<void> play() async {
    _advance();
    commands.add('play');
    playing = true;
  }

  @override
  Future<void> pause() async {
    _advance();
    commands.add('pause');
    playing = false;
  }

  @override
  Future<void> seek(int positionMs) async {
    _advance();
    commands.add('seek:$positionMs');
    _positionMs = positionMs.toDouble();
    _stalledUntilMs = time.nowMs + seekStallMs;
  }

  @override
  Future<void> setRate(double rate) async {
    _advance();
    commands.add('rate:${rate.toStringAsFixed(2)}');
    this.rate = rate;
  }

  void userPause() {
    _advance();
    playing = false;
  }

  void userPlay() {
    _advance();
    playing = true;
  }

  void userSeek(int positionMs) {
    _advance();
    _positionMs = positionMs.toDouble();
  }

  void userSetRate(double value) {
    _advance();
    rate = value;
  }
}

WatchPartyClock clockFor(FakeTime time) =>
    WatchPartyClock(localNowMs: () => time.nowMs);
