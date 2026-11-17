import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'watch_party_backend.dart';
import 'watch_party_chat_policy.dart';
import 'watch_party_clock.dart';
import 'watch_party_models.dart';
import 'watch_party_player_adapter.dart';

/// How the session is reaching the room.
enum WatchPartyConnection {
  /// Joined; waiting for the first Realtime subscription.
  connecting,

  /// Realtime events are arriving.
  live,

  /// Realtime is not subscribed; the room is polled every few seconds.
  polling,

  /// Requests are failing. Retrying with growing pauses.
  reconnecting,
}

/// How this device's player relates to the room.
enum WatchPartySyncStatus {
  /// No player is open.
  noPlayer,

  /// The room has no title yet.
  waitingForHost,

  /// The open player is showing something else than the room's title.
  wrongTitle,
  inSync,

  /// Closing a gap to the room's position.
  catchingUp,
  buffering,

  /// Paused on this device while the room keeps playing.
  pausedLocally,

  /// The room is paused.
  paused,
}

enum WatchPartyEndReason { left, closed, removed, expired, signedOut }

/// The numbers behind drift correction. Shared by every player engine.
class WatchPartyTuning {
  WatchPartyTuning._();

  /// How often an attached player is read.
  static const tickMs = 500;

  /// A gap this small is left alone: correcting it would be more noticeable
  /// than the gap.
  static const deadbandMs = 350;

  /// Once a correction is running it continues until the gap is this small,
  /// so the player does not hover around [deadbandMs] switching on and off.
  static const settleMs = 120;

  /// Larger gaps are closed by seeking; smaller ones by playing 5% faster or
  /// slower, which is not audible as a pitch change.
  static const hardSeekMs = 2500;
  static const nudge = 0.05;

  /// Seek threshold for an engine that cannot change speed.
  static const seekOnlyMs = 1200;

  /// Right after the host plays, pauses or seeks, a gap above this is closed
  /// with a seek at once instead of slowly.
  static const newStateSeekMs = 700;

  /// Allowed difference while the room is paused.
  static const pausedToleranceMs = 500;

  /// Shortest pause between two corrective seeks. It doubles after each
  /// seek that did not bring the player into sync (up to [maxSeekCooldownMs])
  /// so a source that seeks slowly is never sent into a seeking loop.
  static const seekCooldownMs = 4000;
  static const maxSeekCooldownMs = 30000;

  /// How long a player is given to reflect a command before its state is
  /// read as the person's own action again.
  static const commandGraceMs = 2500;

  /// Position jumps the player did not get from playing: a seek.
  static const forwardJumpMs = 1500;
  static const backwardJumpMs = 1000;

  /// Buffering shorter than this is not reported to the room.
  static const bufferingReportMs = 1500;

  /// A host this far from the room's position after a stall moves the room
  /// to the host instead of skipping ahead, at most this often.
  static const hostReanchorMs = 2500;
  static const hostReanchorCooldownMs = 5000;

  /// Heartbeat while Realtime is delivering, and polling while it is not.
  static const heartbeatMs = 15000;
  static const pollMs = 3000;
  static const maxRetryMs = 30000;

  static const maxMessages = 200;
}

/// Returned to a player screen so it can detach when it closes.
class WatchPartyPlayerBinding {
  WatchPartyPlayerBinding._(this._session, this._adapter);

  final WatchPartySession _session;
  final WatchPartyPlayerAdapter _adapter;

  void detach() => _session.detachPlayer(_adapter);
}

/// One membership of one room: keeps the room's state, orders its events,
/// keeps the attached player on the room's timeline and carries chat.
///
/// Playback authority: the room stores one playback state with a sequence
/// number. Only the host's device publishes new states (the room refuses
/// anyone else); every device, the host's included, applies states strictly
/// by sequence number, so events that arrive twice, late or out of order
/// are harmless.
///
/// The player is never hooked. It is read on a timer through a
/// [WatchPartyPlayerAdapter]; for the host, a pause, play or seek made with
/// the player's own controls shows up in those readings and is published.
/// For everyone else the readings are compared with the room's timeline and
/// corrected.
class WatchPartySession extends ChangeNotifier {
  WatchPartySession({
    required WatchPartyBackend backend,
    required WatchPartySnapshot snapshot,
    required this.displayName,
    WatchPartyClock? clock,
    WatchPartyChatPolicy? chatPolicy,
    this.autoTimers = true,
    int? snapshotSentAtLocalMs,
    math.Random? random,
  })  : _backend = backend,
        _clock = clock ?? WatchPartyClock(),
        _chatPolicy = chatPolicy ?? WatchPartyChatPolicy(),
        _random = random ?? math.Random.secure(),
        _room = snapshot.room,
        _roster = snapshot.roster,
        _selfId = snapshot.you {
    final now = _clock.localNowMs;
    _clock.addSample(
      sentAtLocalMs: snapshotSentAtLocalMs ?? now,
      receivedAtLocalMs: now,
      serverMs: snapshot.serverTimeMs,
    );
    _commandSeq = snapshot.commandSeq;
    _mergeMessages(snapshot.messages);
    // History that was already there when joining is not "new".
    _unread = 0;
    _openChannel();
    _scheduleHeartbeat();
  }

  final WatchPartyBackend _backend;
  final WatchPartyClock _clock;
  final WatchPartyChatPolicy _chatPolicy;
  final math.Random _random;

  /// The name other members see for this device.
  final String displayName;

  /// False in tests that drive [tick] and [syncNow] themselves.
  final bool autoTimers;

  WatchPartyRoom _room;
  WatchPartyRoster _roster;
  String _selfId;
  final List<WatchPartyMessage> _messages = [];
  int _lastChatSeq = 0;
  int _unread = 0;

  WatchPartyConnection _connection = WatchPartyConnection.connecting;
  WatchPartySyncStatus _syncStatus = WatchPartySyncStatus.noPlayer;
  WatchPartyEndReason? _ended;
  String? _notice;
  int _noticeSerial = 0;

  WatchPartyChannel? _channel;
  StreamSubscription<WatchPartyEvent>? _eventSubscription;
  StreamSubscription<bool>? _connectedSubscription;
  bool _channelConnected = false;

  Timer? _heartbeatTimer;
  Timer? _tickTimer;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  int _failures = 0;
  bool _rejoining = false;

  // Attached player.
  WatchPartyPlayerAdapter? _adapter;
  WatchPartyMedia? _adapterMedia;
  bool _matching = false;
  bool _settingMedia = false;

  // The title this host started and the room has not accepted yet.
  WatchPartyMedia? _pendingHostMedia;
  // The most recent reading, and the one position jumps are measured from
  // (cleared whenever this session itself seeks).
  WatchPartyPlayerReading? _latest;
  WatchPartyPlayerReading? _baseline;
  int _baselineAtMs = 0;
  int? _knownDurationMs;
  bool? _expectPlaying;
  int _expectUntilMs = 0;
  int _seekSettlesAtMs = 0;
  int _lastSeekAtMs = -WatchPartyTuning.maxSeekCooldownMs;
  int _unsettledSeeks = 0;
  int _seekLeadMs = 0;
  bool _measureSeek = false;
  bool _nudging = false;
  bool _freshState = false;
  bool _followOnce = false;
  int? _bufferingSinceMs;
  bool _reportedBuffering = false;

  // Host publishing.
  int _commandSeq = 0;
  bool _publishing = false;
  WatchPartyPlayback? _optimistic;
  int _publishNotBeforeMs = 0;
  int _lastReanchorAtMs = -WatchPartyTuning.hostReanchorCooldownMs;

  // --- Public state --------------------------------------------------------

  WatchPartyRoom get room => _room;
  WatchPartyRoster get roster => _roster;
  String get selfId => _selfId;
  List<WatchPartyMessage> get messages => List.unmodifiable(_messages);
  WatchPartyConnection get connection => _connection;
  WatchPartySyncStatus get syncStatus => _syncStatus;
  WatchPartyEndReason? get ended => _ended;
  bool get isEnded => _ended != null;
  bool get isHost => _roster.hostId != null && _roster.hostId == _selfId;
  bool get hasPlayer => _adapter != null;
  int get unreadCount => _unread;

  /// A short message for the person watching (for example why a seek was
  /// undone). [noticeSerial] changes with every new notice.
  String? get notice => _notice;
  int get noticeSerial => _noticeSerial;

  /// The room's position right now, or null before the clock is known.
  int? get roomPositionMs {
    final now = _clock.serverNowMs;
    return now == null ? null : _playback.positionAt(now);
  }

  /// The state the player is held to: the room's, or the one this host has
  /// just sent and is waiting to see confirmed.
  WatchPartyPlayback get _playback => _optimistic ?? _room.playback;

  /// Set when this participant's source has a different runtime than the
  /// host's: a different cut or edition will not line up scene for scene.
  String? get sourceWarning {
    if (!_matching || isHost) return null;
    final mine = _knownDurationMs;
    final hosts = _roster.host?.durationMs;
    if (mine == null || mine <= 0 || hosts == null || hosts <= 0) return null;
    final difference = (mine - hosts).abs();
    if (difference <= math.max(3000, hosts ~/ 200)) return null;
    final seconds = (difference / 1000).round();
    final length =
        seconds >= 60 ? '${seconds ~/ 60} min ${seconds % 60} s' : '$seconds s';
    final direction = mine > hosts ? 'longer' : 'shorter';
    return "Your source is $length $direction than the host's. "
        'Scenes may not line up. Try another source.';
  }

  void markChatRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  // --- Realtime ------------------------------------------------------------

  void _openChannel() {
    _eventSubscription?.cancel();
    _connectedSubscription?.cancel();
    final previous = _channel;
    if (previous != null) unawaited(previous.close().catchError((_) {}));
    _channelConnected = false;
    final channel = _backend.openChannel(_room.topic);
    _channel = channel;
    _eventSubscription = channel.events.listen(handleEvent, onError: (_) {});
    _connectedSubscription = channel.connected.listen((connected) {
      if (isEnded || _channelConnected == connected) return;
      _channelConnected = connected;
      _refreshConnection();
      // Whatever was sent while not subscribed is fetched now.
      if (connected) unawaited(syncNow());
      _scheduleHeartbeat();
    }, onError: (_) {});
  }

  void _refreshConnection() {
    final next = _failures > 0
        ? WatchPartyConnection.reconnecting
        : _channelConnected
            ? WatchPartyConnection.live
            : (_connection == WatchPartyConnection.connecting
                ? WatchPartyConnection.connecting
                : WatchPartyConnection.polling);
    if (next != _connection) {
      _connection = next;
      notifyListeners();
    }
  }

  /// Applies one Realtime event. Events may arrive twice, late or out of
  /// order; sequence numbers decide what is applied.
  @visibleForTesting
  void handleEvent(WatchPartyEvent event) {
    if (isEnded) return;
    switch (event) {
      case WatchPartyStateEvent():
        if (event.playback.seq > _room.playback.seq) {
          _setPlayback(event.playback, event.media);
          notifyListeners();
        }
      case WatchPartyRosterEvent():
        if (event.roster.seq > _roster.seq) {
          _setRoster(event.roster);
          notifyListeners();
        }
      case WatchPartyChatEvent():
        final seq = event.message.seq;
        if (seq == _lastChatSeq + 1) {
          _mergeMessages([event.message]);
          notifyListeners();
        } else if (seq > _lastChatSeq + 1) {
          // Something in between was missed: fetch it so chat stays in order.
          unawaited(syncNow());
        }
      case WatchPartyClosedEvent():
        _end(WatchPartyEndReason.closed);
      case WatchPartyRekeyEvent():
        unawaited(syncNow());
    }
  }

  // --- Room state ----------------------------------------------------------

  void _applySnapshot(
    WatchPartySnapshot snapshot, {
    required int sentAtLocalMs,
  }) {
    if (isEnded) return;
    _clock.addSample(
      sentAtLocalMs: sentAtLocalMs,
      receivedAtLocalMs: _clock.localNowMs,
      serverMs: snapshot.serverTimeMs,
    );
    _selfId = snapshot.you;
    if (snapshot.commandSeq > _commandSeq) _commandSeq = snapshot.commandSeq;

    final topicChanged = snapshot.room.topic != _room.topic;
    final newerState = snapshot.room.playback.seq > _room.playback.seq;
    _room = WatchPartyRoom(
      id: snapshot.room.id,
      code: snapshot.room.code,
      topic: snapshot.room.topic,
      playback: _room.playback,
      media: _room.media,
      expiresAtMs: snapshot.room.expiresAtMs,
      maxParticipants: snapshot.room.maxParticipants,
      chatSeq: snapshot.room.chatSeq,
    );
    if (newerState) _setPlayback(snapshot.room.playback, snapshot.room.media);
    // The roster's online flags change without a new number.
    if (snapshot.roster.seq >= _roster.seq) _setRoster(snapshot.roster);
    _mergeMessages(snapshot.messages);
    if (topicChanged) _openChannel();
    notifyListeners();
  }

  void _setPlayback(WatchPartyPlayback playback, WatchPartyMedia? media) {
    final mediaChanged = media?.key != _room.media?.key;
    _room = _room.copyWith(
      playback: playback,
      media: media,
      clearMedia: media == null,
    );
    _optimistic = null;
    if (mediaChanged) _evaluateMatch();
    _freshState = true;
    if (_matching) tick();
  }

  void _setRoster(WatchPartyRoster roster) {
    final wasHost = isHost;
    _roster = roster;
    if (isHost != wasHost) {
      // A device that becomes host mid-film is already on the room's
      // timeline; it starts publishing from where it is.
      _baseline = null;
      _followOnce = false;
      _optimistic = null;
      if (isHost) _restoreRate();
    }
  }

  void _mergeMessages(List<WatchPartyMessage> incoming) {
    if (incoming.isEmpty) return;
    final sorted = [...incoming]..sort((a, b) => a.seq.compareTo(b.seq));
    for (final message in sorted) {
      if (message.seq <= _lastChatSeq) continue;
      _messages.add(message);
      _lastChatSeq = message.seq;
      if (message.from != _selfId) _unread++;
    }
    final overflow = _messages.length - WatchPartyTuning.maxMessages;
    if (overflow > 0) _messages.removeRange(0, overflow);
  }

  void _setNotice(String text) {
    _notice = text;
    _noticeSerial++;
    notifyListeners();
  }

  void _setSyncStatus(WatchPartySyncStatus status) {
    if (status == _syncStatus) return;
    _syncStatus = status;
    notifyListeners();
  }

  // --- Heartbeat and reconnect --------------------------------------------

  void _scheduleHeartbeat() {
    _heartbeatTimer?.cancel();
    if (!autoTimers || isEnded) return;
    final delay = _failures > 0
        ? math.min(
            WatchPartyTuning.maxRetryMs,
            1000 * (1 << math.min(_failures, 5)),
          )
        : (_channelConnected
            ? WatchPartyTuning.heartbeatMs
            : WatchPartyTuning.pollMs);
    _heartbeatTimer = Timer(Duration(milliseconds: delay), () {
      unawaited(syncNow());
    });
  }

  bool get _ready => _adapter != null && _matching && _latest != null;

  /// Sends a heartbeat with this device's status and applies the room state
  /// that comes back. Also the catch-up path after a missed event, a lost
  /// connection or a replaced topic.
  Future<void> syncNow() async {
    if (isEnded) return;
    if (_syncInFlight) {
      _syncQueued = true;
      return;
    }
    _syncInFlight = true;
    final sentAt = _clock.localNowMs;
    try {
      final snapshot = await _backend.sync(
        _room.id,
        afterChatSeq: _lastChatSeq,
        ready: _ready,
        buffering: _ready && _reportedBuffering,
        mediaKey: _adapter == null ? null : _adapterMedia?.key,
        durationMs: _ready ? _knownDurationMs : null,
      );
      if (isEnded) return;
      _failures = 0;
      if (_connection == WatchPartyConnection.connecting &&
          !_channelConnected) {
        _connection = WatchPartyConnection.polling;
      }
      _applySnapshot(snapshot, sentAtLocalMs: sentAt);
      _refreshConnection();
      // A title this host started while offline is set once back online.
      final pending = _pendingHostMedia;
      if (pending != null && _adapter != null && isHost && !_matching) {
        unawaited(_hostSetMedia(pending));
      }
    } on WatchPartyException catch (failure) {
      if (isEnded) return;
      await _handleRoomFailure(failure.error);
    } finally {
      _syncInFlight = false;
      if (!isEnded) {
        if (_syncQueued) {
          _syncQueued = false;
          // The room refuses heartbeats closer together than about a second.
          if (autoTimers) {
            unawaited(Future<void>.delayed(
              const Duration(milliseconds: 900),
              syncNow,
            ));
          } else {
            scheduleMicrotask(syncNow);
          }
        }
        _scheduleHeartbeat();
      }
    }
  }

  /// Reacts to a refused or failed room request. Returns after any rejoin
  /// attempt has finished.
  Future<void> _handleRoomFailure(WatchPartyError error) async {
    switch (error) {
      case WatchPartyError.rateLimited:
        // Try again on the next heartbeat.
        return;
      case WatchPartyError.notMember:
        // A long disconnect gives up this device's place; take it back.
        await _rejoin();
      case WatchPartyError.removed:
        _end(WatchPartyEndReason.removed);
      case WatchPartyError.roomClosed || WatchPartyError.notFound:
        _end(WatchPartyEndReason.expired);
      case WatchPartyError.authRequired:
        _end(WatchPartyEndReason.signedOut);
      case WatchPartyError.hostOnly:
        // The host role moved; the next snapshot says to whom.
        _optimistic = null;
        unawaited(syncNow());
      default:
        _failures++;
        _refreshConnection();
    }
  }

  Future<void> _rejoin() async {
    if (_rejoining || isEnded) return;
    _rejoining = true;
    final sentAt = _clock.localNowMs;
    try {
      final snapshot = await _backend.joinRoom(_room.code, displayName);
      if (isEnded) return;
      _failures = 0;
      _applySnapshot(snapshot, sentAtLocalMs: sentAt);
      _refreshConnection();
    } on WatchPartyException catch (failure) {
      if (isEnded) return;
      switch (failure.error) {
        case WatchPartyError.network || WatchPartyError.rateLimited:
          _failures++;
          _refreshConnection();
        case WatchPartyError.removed:
          _end(WatchPartyEndReason.removed);
        default:
          _end(WatchPartyEndReason.expired);
      }
    } finally {
      _rejoining = false;
    }
  }

  // --- Player --------------------------------------------------------------

  /// Connects a player that has started playing [media] (null when what it
  /// plays has no catalog id, such as a file from a cloud drive).
  WatchPartyPlayerBinding attachPlayer(
    WatchPartyPlayerAdapter adapter,
    WatchPartyMedia? media,
  ) {
    if (_adapter != null && _adapter != adapter) detachPlayer(_adapter!);
    _adapter = adapter;
    _adapterMedia = media;
    _resetObservation();
    _evaluateMatch(hostMaySetMedia: true);
    if (autoTimers && !isEnded) {
      _tickTimer?.cancel();
      _tickTimer = Timer.periodic(
        const Duration(milliseconds: WatchPartyTuning.tickMs),
        (_) => tick(),
      );
    }
    tick();
    unawaited(syncNow());
    return WatchPartyPlayerBinding._(this, adapter);
  }

  void detachPlayer(WatchPartyPlayerAdapter adapter) {
    if (_adapter != adapter) return;
    _tickTimer?.cancel();
    _tickTimer = null;
    final last = _latest;
    final wasMatching = _matching;
    _restoreRate();
    _adapter = null;
    _adapterMedia = null;
    _pendingHostMedia = null;
    _matching = false;
    _resetObservation();
    if (isEnded) return;
    // A host who closes the player leaves the room paused where they were,
    // instead of a timeline that runs on with nobody steering.
    final serverNow = _clock.serverNowMs;
    if (isHost &&
        wasMatching &&
        last != null &&
        serverNow != null &&
        _playback.playing) {
      unawaited(_publish(false, last.positionMs, serverNow));
    }
    // A player screen may detach while it is being disposed, when widgets
    // must not be rebuilt: listeners hear about it a moment later.
    _syncStatus = WatchPartySyncStatus.noPlayer;
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
    unawaited(syncNow());
  }

  void _resetObservation() {
    _latest = null;
    _baseline = null;
    _knownDurationMs = null;
    _expectPlaying = null;
    _seekSettlesAtMs = 0;
    _lastSeekAtMs = -WatchPartyTuning.maxSeekCooldownMs;
    _unsettledSeeks = 0;
    _seekLeadMs = 0;
    _measureSeek = false;
    _nudging = false;
    _freshState = true;
    _bufferingSinceMs = null;
    _reportedBuffering = false;
    _optimistic = null;
    _followOnce = false;
  }

  /// Decides whether the attached player is showing the room's title.
  ///
  /// With [hostMaySetMedia] (only when the host opens a player) a host who
  /// starts a different title makes it the room's title. A device that is
  /// handed the host role while watching something else does not move the
  /// room.
  void _evaluateMatch({bool hostMaySetMedia = false}) {
    final adapter = _adapter;
    if (adapter == null) {
      _matching = false;
      return;
    }
    final mine = _adapterMedia;
    final rooms = _room.media;
    final matches = mine != null && rooms != null && mine.key == rooms.key;
    if (matches) {
      if (!_matching) {
        _matching = true;
        _latest = null;
        _baseline = null;
        // A host who opens a player while the room is already playing joins
        // the room's timeline once, instead of pulling everyone to their
        // own spot.
        _followOnce = isHost && _room.playback.playing;
      }
      return;
    }
    if (_matching) {
      // No longer the room's title: tell the room this device is not ready.
      _matching = false;
      _latest = null;
      unawaited(syncNow());
    }
    _restoreRate();
    if (isHost && mine != null && hostMaySetMedia) {
      _pendingHostMedia = mine;
      unawaited(_hostSetMedia(mine));
    } else {
      _setSyncStatus(rooms == null
          ? WatchPartySyncStatus.waitingForHost
          : WatchPartySyncStatus.wrongTitle);
    }
  }

  Future<void> _hostSetMedia(WatchPartyMedia media) async {
    if (_settingMedia || isEnded) return;
    _settingMedia = true;
    final sentAt = _clock.localNowMs;
    try {
      final snapshot = await _backend.setMedia(_room.id, media);
      _pendingHostMedia = null;
      _applySnapshot(snapshot, sentAtLocalMs: sentAt);
    } on WatchPartyException catch (failure) {
      if (isEnded) return;
      // Anything but a lost connection or a rate limit will not get better
      // by trying again.
      if (failure.error != WatchPartyError.network &&
          failure.error != WatchPartyError.rateLimited) {
        _pendingHostMedia = null;
      }
      if (failure.error == WatchPartyError.invalidMedia) {
        _setSyncStatus(WatchPartySyncStatus.wrongTitle);
        _setNotice(failure.error.message);
      } else {
        await _handleRoomFailure(failure.error);
      }
    } finally {
      _settingMedia = false;
    }
  }

  void _run(Future<void> command) {
    unawaited(command.catchError((_) {}));
  }

  void _commandPlaying(bool playing, int localNow) {
    final adapter = _adapter;
    if (adapter == null) return;
    _expectPlaying = playing;
    _expectUntilMs = localNow + WatchPartyTuning.commandGraceMs;
    _run(playing ? adapter.play() : adapter.pause());
  }

  void _commandSeek(int positionMs, int localNow, {bool measure = false}) {
    final adapter = _adapter;
    if (adapter == null) return;
    _seekSettlesAtMs = localNow + WatchPartyTuning.commandGraceMs;
    _lastSeekAtMs = localNow;
    _unsettledSeeks++;
    _measureSeek = measure;
    _baseline = null;
    _run(adapter.seek(positionMs < 0 ? 0 : positionMs));
  }

  void _setRate(double rate) {
    final adapter = _adapter;
    if (adapter == null) return;
    _run(adapter.setRate(rate));
  }

  void _restoreRate() {
    if (!_nudging) return;
    _nudging = false;
    _setRate(1.0);
  }

  int get _seekCooldownMs => math.min(
        WatchPartyTuning.maxSeekCooldownMs,
        WatchPartyTuning.seekCooldownMs *
            (1 << math.min(math.max(_unsettledSeeks - 1, 0), 4)),
      );

  /// Reads the attached player and keeps it on the room's timeline. Runs
  /// every [WatchPartyTuning.tickMs] and right after a new room state.
  @visibleForTesting
  void tick() {
    final adapter = _adapter;
    if (isEnded || adapter == null || !_matching) return;
    final serverNow = _clock.serverNowMs;
    final reading = adapter.read();
    if (serverNow == null || reading == null) return;
    final localNow = _clock.localNowMs;

    final previous = _baseline;
    final previousAt = _baselineAtMs;
    final firstReading = _latest == null;
    _latest = reading;
    _baseline = reading;
    _baselineAtMs = localNow;
    _trackStatusReports(reading, localNow, announce: firstReading);

    if (_expectPlaying != null &&
        (reading.playing == _expectPlaying || localNow >= _expectUntilMs)) {
      _expectPlaying = null;
    }
    final settling = _expectPlaying != null;
    final seekSettling = localNow < _seekSettlesAtMs;

    var jumped = false;
    if (previous != null && !seekSettling) {
      final moved = reading.positionMs - previous.positionMs;
      final played = previous.playing && reading.playing
          ? ((localNow - previousAt) * reading.rate).round()
          : 0;
      jumped = moved < -WatchPartyTuning.backwardJumpMs ||
          moved - played > WatchPartyTuning.forwardJumpMs;
    }

    // Playback speed belongs to the room: everyone plays at 1x, apart from
    // the small corrections made here.
    if (!_nudging && (reading.rate - 1.0).abs() > 0.001) {
      _setRate(1.0);
      _setNotice('Playback speed stays at 1× during a Watch Party.');
    }

    if (isHost && !_followOnce) {
      _tickHost(reading, localNow, serverNow,
          jumped: jumped, settling: settling, seekSettling: seekSettling);
    } else {
      _follow(reading, localNow, serverNow,
          jumped: jumped, settling: settling, seekSettling: seekSettling);
      _followOnce = false;
    }
    _freshState = false;
  }

  void _trackStatusReports(
    WatchPartyPlayerReading reading,
    int localNow, {
    required bool announce,
  }) {
    var changed = announce;
    if (reading.durationMs > 0 && reading.durationMs != _knownDurationMs) {
      // Reported once it is known; later refinements of a few ms are noise.
      final known = _knownDurationMs;
      if (known == null || (known - reading.durationMs).abs() > 1000) {
        changed = true;
      }
      _knownDurationMs = reading.durationMs;
    }
    if (reading.buffering && reading.playing) {
      _bufferingSinceMs ??= localNow;
      if (!_reportedBuffering &&
          localNow - _bufferingSinceMs! >= WatchPartyTuning.bufferingReportMs) {
        _reportedBuffering = true;
        changed = true;
      }
    } else {
      _bufferingSinceMs = null;
      if (_reportedBuffering) {
        _reportedBuffering = false;
        changed = true;
      }
    }
    if (changed) unawaited(syncNow());
  }

  /// The host's player is the source of the room's state: what the host
  /// does with their own controls is published.
  void _tickHost(
    WatchPartyPlayerReading reading,
    int localNow,
    int serverNow, {
    required bool jumped,
    required bool settling,
    required bool seekSettling,
  }) {
    final playback = _playback;
    final expected = playback.positionAt(serverNow);
    final drift = reading.positionMs - expected;

    if (reading.playing && reading.buffering) {
      _setSyncStatus(WatchPartySyncStatus.buffering);
    } else {
      _setSyncStatus(reading.playing
          ? WatchPartySyncStatus.inSync
          : WatchPartySyncStatus.paused);
    }
    if (_publishing || settling || localNow < _publishNotBeforeMs) return;

    var publish = false;
    if (reading.playing != playback.playing) {
      // Play or pause.
      publish = true;
    } else if (jumped) {
      // Seek.
      publish = true;
    } else if (!reading.playing) {
      // Scrubbed while paused.
      publish = (reading.positionMs - playback.positionMs).abs() >
          WatchPartyTuning.pausedToleranceMs;
    } else if (!reading.buffering && !seekSettling) {
      if (drift.abs() > WatchPartyTuning.hostReanchorMs) {
        // The host stalled and is now behind the room. The room moves back
        // to the host: skipping the host ahead would lose them the scene
        // and usually stalls again.
        if (localNow - _lastReanchorAtMs >=
            WatchPartyTuning.hostReanchorCooldownMs) {
          _lastReanchorAtMs = localNow;
          publish = true;
        }
      } else {
        _nudgeTowards(drift);
      }
    }
    if (publish) {
      _restoreRate();
      unawaited(_publish(reading.playing, reading.positionMs, serverNow));
    }
  }

  /// Everyone but the host: follow the room.
  void _follow(
    WatchPartyPlayerReading reading,
    int localNow,
    int serverNow, {
    required bool jumped,
    required bool settling,
    required bool seekSettling,
  }) {
    final playback = _room.playback;

    if (!playback.playing) {
      _restoreRate();
      if (reading.playing && !settling) {
        _commandPlaying(false, localNow);
        if (!_freshState && !isHost) {
          _setNotice(playback.isFresh
              ? 'Waiting for the host to start.'
              : 'The host paused playback.');
        }
      }
      final off = reading.positionMs - playback.positionMs;
      // A new room state is applied at once, even right after another seek.
      if (off.abs() > WatchPartyTuning.pausedToleranceMs &&
          (_freshState ||
              (!seekSettling && localNow - _lastSeekAtMs >= _seekCooldownMs))) {
        _commandSeek(playback.positionMs, localNow);
      }
      _setSyncStatus(playback.isFresh
          ? WatchPartySyncStatus.waitingForHost
          : WatchPartySyncStatus.paused);
      return;
    }

    if (!reading.playing) {
      if (_freshState) {
        // The host pressed play (or seeked): everyone resumes.
        _commandPlaying(true, localNow);
      } else if (!settling) {
        // Paused here with this device's own controls. That is respected
        // until this device plays again or the host does something.
        _restoreRate();
        _setSyncStatus(WatchPartySyncStatus.pausedLocally);
        return;
      } else {
        return;
      }
    }

    final expected = playback.positionAt(serverNow);
    final duration = reading.durationMs;
    if (duration > 0 && expected > duration - 1000) {
      // The room is past the end of this device's source.
      _restoreRate();
      _setSyncStatus(WatchPartySyncStatus.inSync);
      return;
    }
    if (reading.buffering) {
      _restoreRate();
      _setSyncStatus(WatchPartySyncStatus.buffering);
      // A seek the room asked for is still issued while stalled; a stalled
      // player is otherwise left to recover on its own.
      if (!_freshState) return;
    }

    final drift = reading.positionMs - expected;
    final gap = drift.abs();

    // A new room state makes the last seek's outcome meaningless.
    if (_freshState) _measureSeek = false;
    if (_measureSeek && !seekSettling && !reading.buffering) {
      // Learn how long this source takes to seek, and aim ahead by that much
      // next time, so a slow source converges instead of seeking again.
      _measureSeek = false;
      if (gap < 15000) {
        _seekLeadMs = (_seekLeadMs - (drift * 0.7).round()).clamp(0, 5000);
      }
    }

    final seekThreshold = _freshState
        ? WatchPartyTuning.newStateSeekMs
        : (_adapter!.supportsRate
            ? WatchPartyTuning.hardSeekMs
            : WatchPartyTuning.seekOnlyMs);
    if (gap >= seekThreshold) {
      final cooledDown = localNow - _lastSeekAtMs >= _seekCooldownMs;
      // A new room state is applied at once, even right after another seek.
      if (_freshState || (cooledDown && !seekSettling)) {
        _restoreRate();
        _commandSeek(expected + _seekLeadMs, localNow, measure: true);
        if (jumped && !_freshState && !isHost) {
          _setNotice('Only the host can seek. Back with the party.');
        }
      } else if (!reading.buffering) {
        _nudgeTowards(drift);
      }
      _setSyncStatus(reading.buffering
          ? WatchPartySyncStatus.buffering
          : WatchPartySyncStatus.catchingUp);
      return;
    }

    if (reading.buffering) return;
    _nudgeTowards(drift);
    if (gap <= WatchPartyTuning.deadbandMs) _unsettledSeeks = 0;
    _setSyncStatus(gap <= 1000
        ? WatchPartySyncStatus.inSync
        : WatchPartySyncStatus.catchingUp);
  }

  /// Closes a small gap by playing slightly faster or slower.
  void _nudgeTowards(int driftMs) {
    final adapter = _adapter;
    if (adapter == null || !adapter.supportsRate) return;
    final gap = driftMs.abs();
    final limit =
        _nudging ? WatchPartyTuning.settleMs : WatchPartyTuning.deadbandMs;
    if (gap <= limit) {
      _restoreRate();
      return;
    }
    _nudging = true;
    _setRate(driftMs > 0
        ? 1.0 - WatchPartyTuning.nudge
        : 1.0 + WatchPartyTuning.nudge);
  }

  Future<void> _publish(bool playing, int positionMs, int serverNow) async {
    if (isEnded) return;
    _publishing = true;
    final clientSeq = ++_commandSeq;
    // Hold the player to what was just sent until the room confirms it, so
    // the same change is not published again on the next reading.
    _optimistic = WatchPartyPlayback(
      seq: _room.playback.seq,
      playing: playing,
      positionMs: positionMs,
      atMs: serverNow,
    );
    final sentAt = _clock.localNowMs;
    try {
      final snapshot = await _backend.setPlayback(
        _room.id,
        playing: playing,
        positionMs: positionMs,
        clientSeq: clientSeq,
        observedAtMs: serverNow,
      );
      if (isEnded) return;
      _failures = 0;
      final mine = _optimistic;
      _applySnapshot(snapshot, sentAtLocalMs: sentAt);
      // Refused as a duplicate or as already true: fall back to the room.
      if (identical(_optimistic, mine)) _optimistic = null;
      _refreshConnection();
    } on WatchPartyException catch (failure) {
      if (isEnded) return;
      _optimistic = null;
      _publishNotBeforeMs = _clock.localNowMs +
          (failure.error == WatchPartyError.rateLimited ? 3000 : 1500);
      await _handleRoomFailure(failure.error);
    } finally {
      _publishing = false;
    }
  }

  // --- Chat ----------------------------------------------------------------

  String _newClientId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Sends a chat message. Returns null when it was sent, otherwise the
  /// reason to show next to the message box (the text is kept there).
  Future<String?> sendChat(String text) async {
    if (isEnded) return WatchPartyError.roomClosed.message;
    final rejection = _chatPolicy.rejection(text);
    if (rejection != null) return rejection;
    final body = WatchPartyChatPolicy.clean(text);
    _chatPolicy.recordSent();
    // One id for the message, so a retry after a lost reply is not a
    // second message.
    final clientId = _newClientId();
    try {
      WatchPartyMessage message;
      try {
        message = await _backend.sendMessage(_room.id, body, clientId);
      } on WatchPartyException catch (failure) {
        if (failure.error != WatchPartyError.network) rethrow;
        message = await _backend.sendMessage(_room.id, body, clientId);
      }
      if (isEnded) return null;
      if (message.seq == _lastChatSeq + 1) {
        _mergeMessages([message]);
        notifyListeners();
      } else if (message.seq > _lastChatSeq) {
        unawaited(syncNow());
      }
      return null;
    } on WatchPartyException catch (failure) {
      if (failure.error != WatchPartyError.rateLimited &&
          failure.error != WatchPartyError.invalidMessage &&
          failure.error != WatchPartyError.network) {
        await _handleRoomFailure(failure.error);
      }
      return failure.error.message;
    }
  }

  // --- Host actions and leaving --------------------------------------------

  Future<String?> _hostAction(
    Future<WatchPartySnapshot> Function() action,
  ) async {
    if (isEnded) return WatchPartyError.roomClosed.message;
    final sentAt = _clock.localNowMs;
    try {
      _applySnapshot(await action(), sentAtLocalMs: sentAt);
      return null;
    } on WatchPartyException catch (failure) {
      if (failure.error != WatchPartyError.invalidParticipant &&
          failure.error != WatchPartyError.network) {
        await _handleRoomFailure(failure.error);
      }
      return failure.error.message;
    }
  }

  /// Host only. Returns null on success, otherwise the reason.
  Future<String?> removeParticipant(String participantId) =>
      _hostAction(() => _backend.removeParticipant(_room.id, participantId));

  /// Host only. Returns null on success, otherwise the reason.
  Future<String?> transferHost(String participantId) =>
      _hostAction(() => _backend.transferHost(_room.id, participantId));

  /// Host only: ends the room for everyone.
  Future<String?> closeRoom() async {
    if (isEnded) return null;
    try {
      await _backend.closeRoom(_room.id);
      _end(WatchPartyEndReason.closed);
      return null;
    } on WatchPartyException catch (failure) {
      return failure.error.message;
    }
  }

  /// Leaves the room. Always ends the session locally, even offline; the
  /// room then releases this device's place after two minutes.
  Future<void> leave() async {
    if (isEnded) return;
    final roomId = _room.id;
    _end(WatchPartyEndReason.left);
    try {
      await _backend.leaveRoom(roomId);
    } on WatchPartyException {
      // Nothing to do: the room notices the missing heartbeats.
    }
  }

  void _end(WatchPartyEndReason reason) {
    if (isEnded) return;
    _restoreRate();
    _ended = reason;
    _heartbeatTimer?.cancel();
    _tickTimer?.cancel();
    _eventSubscription?.cancel();
    _connectedSubscription?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.close().catchError((_) {}));
    _adapter = null;
    _matching = false;
    _syncStatus = WatchPartySyncStatus.noPlayer;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _end(WatchPartyEndReason.left);
    _disposed = true;
    super.dispose();
  }
}
