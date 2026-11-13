import '../../models/media_item.dart';

/// What a room is watching: a catalog id, never a stream or a source.
class WatchPartyMedia {
  const WatchPartyMedia({
    required this.kind,
    required this.id,
    this.season,
    this.episode,
    this.title,
    this.year,
  });

  final MediaKind kind;
  final String id;
  final int? season;
  final int? episode;
  final String? title;
  final String? year;

  /// Catalog ids the backend accepts. Anything else (a URL, a local file
  /// path) is not a title two people can both look up.
  static final _validId = RegExp(r'^[A-Za-z0-9:_.-]{1,64}$');

  /// The room media for [item], or null when it has no shareable catalog id.
  static WatchPartyMedia? fromItem(MediaItem? item, EpisodeItem? episode) {
    if (item == null || !_validId.hasMatch(item.id)) return null;
    final series = item.kind == MediaKind.series;
    if (series && episode == null) return null;
    return WatchPartyMedia(
      kind: item.kind,
      id: item.id,
      season: series ? episode!.season : null,
      episode: series ? episode!.episode : null,
      title: item.title,
      year: item.year,
    );
  }

  static WatchPartyMedia? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    final kind = raw['kind']?.toString();
    if (id == null || id.isEmpty) return null;
    if (kind != 'movie' && kind != 'series') return null;
    return WatchPartyMedia(
      kind: kind == 'series' ? MediaKind.series : MediaKind.movie,
      id: id,
      season: _int(raw['season']),
      episode: _int(raw['episode']),
      title: _text(raw['title']),
      year: _text(raw['year']),
    );
  }

  String get kindName => kind == MediaKind.series ? 'series' : 'movie';

  /// Identifies one movie or one episode. Must match
  /// `orvix_watch_media_key` in the database.
  String get key => '$kindName:$id:${season ?? '-'}:${episode ?? '-'}';

  String? get episodeLabel {
    if (season == null || episode == null) return null;
    return 'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}';
  }

  /// "Inception (2010)" or "Breaking Bad · S01E02".
  String get label {
    final name = (title == null || title!.isEmpty) ? 'Untitled' : title!;
    final episodeLabel = this.episodeLabel;
    if (episodeLabel != null) return '$name · $episodeLabel';
    return (year == null || year!.isEmpty) ? name : '$name ($year)';
  }

  /// A catalog stub the app can open; the details screen loads the rest.
  MediaItem toItem() => MediaItem(
        id: id,
        kind: kind,
        title: (title == null || title!.isEmpty) ? 'Untitled' : title!,
        year: year,
      );
}

/// The room's authoritative playback state: at server time [atMs] the
/// position was [positionMs]. While [playing] it advances with the clock.
class WatchPartyPlayback {
  const WatchPartyPlayback({
    required this.seq,
    required this.playing,
    required this.positionMs,
    required this.atMs,
  });

  /// Assigned by the room; a larger number is always the newer state.
  final int seq;
  final bool playing;
  final int positionMs;
  final int atMs;

  static const initial =
      WatchPartyPlayback(seq: 0, playing: false, positionMs: 0, atMs: 0);

  static WatchPartyPlayback? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = _int(raw['seq']);
    final position = _int(raw['position_ms']);
    final at = _int(raw['at_ms']);
    final playing = raw['playing'];
    if (seq == null || position == null || at == null || playing is! bool) {
      return null;
    }
    return WatchPartyPlayback(
      seq: seq,
      playing: playing,
      positionMs: position < 0 ? 0 : position,
      atMs: at,
    );
  }

  /// Where playback should be at server time [serverNowMs].
  int positionAt(int serverNowMs) {
    if (!playing) return positionMs;
    final elapsed = serverNowMs - atMs;
    return positionMs + (elapsed < 0 ? 0 : elapsed);
  }

  /// True until the host has started this title: paused at the beginning.
  bool get isFresh => !playing && positionMs == 0;
}

class WatchPartyParticipant {
  const WatchPartyParticipant({
    required this.id,
    required this.name,
    this.ready = false,
    this.buffering = false,
    this.online = true,
    this.durationMs,
  });

  /// Opaque per-room id. Account ids and emails never reach other members.
  final String id;
  final String name;

  /// Playing the room's title in a player.
  final bool ready;
  final bool buffering;
  final bool online;

  /// Runtime of this participant's own source, for mismatch warnings.
  final int? durationMs;

  static WatchPartyParticipant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return WatchPartyParticipant(
      id: id,
      name: _text(raw['name']) ?? 'Guest',
      ready: raw['ready'] == true,
      buffering: raw['buffering'] == true,
      online: raw['online'] != false,
      durationMs: _int(raw['duration_ms']),
    );
  }
}

class WatchPartyRoster {
  const WatchPartyRoster({
    required this.seq,
    required this.hostId,
    required this.participants,
  });

  final int seq;
  final String? hostId;
  final List<WatchPartyParticipant> participants;

  static const empty = WatchPartyRoster(seq: 0, hostId: null, participants: []);

  static WatchPartyRoster? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = _int(raw['seq']);
    final list = raw['participants'];
    if (seq == null || list is! List) return null;
    return WatchPartyRoster(
      seq: seq,
      hostId: raw['host']?.toString(),
      participants: [
        for (final entry in list)
          if (WatchPartyParticipant.fromJson(entry) case final participant?)
            participant,
      ],
    );
  }

  WatchPartyParticipant? byId(String? id) {
    if (id == null) return null;
    for (final participant in participants) {
      if (participant.id == id) return participant;
    }
    return null;
  }

  WatchPartyParticipant? get host => byId(hostId);
}

class WatchPartyMessage {
  const WatchPartyMessage({
    required this.seq,
    required this.from,
    required this.name,
    required this.body,
    required this.atMs,
  });

  /// Position in the room's chat; messages are shown in this order.
  final int seq;
  final String from;
  final String name;
  final String body;
  final int atMs;

  static WatchPartyMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = _int(raw['seq']);
    final body = raw['body']?.toString();
    if (seq == null || body == null || body.isEmpty) return null;
    return WatchPartyMessage(
      seq: seq,
      from: raw['from']?.toString() ?? '',
      name: _text(raw['name']) ?? 'Guest',
      body: body,
      atMs: _int(raw['at_ms']) ?? 0,
    );
  }
}

class WatchPartyRoom {
  const WatchPartyRoom({
    required this.id,
    required this.code,
    required this.topic,
    required this.playback,
    this.media,
    this.expiresAtMs,
    this.maxParticipants = 10,
    this.chatSeq = 0,
  });

  final String id;
  final String code;

  /// The private Realtime topic. It changes when someone is removed.
  final String topic;
  final WatchPartyPlayback playback;
  final WatchPartyMedia? media;
  final int? expiresAtMs;
  final int maxParticipants;
  final int chatSeq;

  /// "ABCD-EFGH".
  String get formattedCode => formatCode(code);

  static String formatCode(String code) =>
      code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  /// Upper-case letters and digits only, as the backend compares them.
  static String normalizeCode(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static WatchPartyRoom? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    final topic = raw['topic']?.toString();
    final playback = WatchPartyPlayback.fromJson(raw['playback']);
    if (id == null || topic == null || playback == null) return null;
    return WatchPartyRoom(
      id: id,
      code: raw['code']?.toString() ?? '',
      topic: topic,
      playback: playback,
      media: WatchPartyMedia.fromJson(raw['media']),
      expiresAtMs: _int(raw['expires_at_ms']),
      maxParticipants: _int(raw['max_participants']) ?? 10,
      chatSeq: _int(raw['chat_seq']) ?? 0,
    );
  }

  WatchPartyRoom copyWith({
    WatchPartyPlayback? playback,
    WatchPartyMedia? media,
    bool clearMedia = false,
    String? topic,
    int? chatSeq,
  }) =>
      WatchPartyRoom(
        id: id,
        code: code,
        topic: topic ?? this.topic,
        playback: playback ?? this.playback,
        media: clearMedia ? null : (media ?? this.media),
        expiresAtMs: expiresAtMs,
        maxParticipants: maxParticipants,
        chatSeq: chatSeq ?? this.chatSeq,
      );
}

/// A full view of the room, as every room call returns it.
class WatchPartySnapshot {
  const WatchPartySnapshot({
    required this.serverTimeMs,
    required this.you,
    required this.room,
    required this.roster,
    this.messages = const [],
    this.commandSeq = 0,
    this.mediaMismatch = false,
    this.stale = false,
    this.unchanged = false,
  });

  final int serverTimeMs;

  /// The caller's own participant id.
  final String you;
  final WatchPartyRoom room;
  final WatchPartyRoster roster;
  final List<WatchPartyMessage> messages;

  /// The caller's highest playback command number the room has accepted.
  final int commandSeq;

  /// The caller reported being ready with a different title than the room's.
  final bool mediaMismatch;

  /// A playback command was ignored because a newer one was already applied.
  final bool stale;

  /// A playback command described the state the room was already in.
  final bool unchanged;

  static WatchPartySnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final room = WatchPartyRoom.fromJson(raw['room']);
    final roster = WatchPartyRoster.fromJson(raw['roster']);
    final you = raw['you']?.toString();
    final serverTime = _int(raw['server_time_ms']);
    if (room == null || roster == null || you == null || serverTime == null) {
      return null;
    }
    final messages = raw['messages'];
    return WatchPartySnapshot(
      serverTimeMs: serverTime,
      you: you,
      room: room,
      roster: roster,
      messages: [
        if (messages is List)
          for (final entry in messages)
            if (WatchPartyMessage.fromJson(entry) case final message?) message,
      ],
      commandSeq: _int(raw['command_seq']) ?? 0,
      mediaMismatch: raw['media_mismatch'] == true,
      stale: raw['stale'] == true,
      unchanged: raw['unchanged'] == true,
    );
  }
}

/// Why a room request was refused. Mirrors the backend's error codes.
enum WatchPartyError {
  /// Not signed in to an Orvix account.
  authRequired,
  rateLimited,
  invalidName,

  /// No live room has this invite code.
  notFound,
  roomFull,

  /// The host removed this account from the room.
  removed,
  notMember,
  roomClosed,
  hostOnly,
  invalidMedia,
  invalidState,
  noMedia,
  invalidMessage,
  invalidParticipant,

  /// The backend could not be reached.
  network,

  /// Watch Party is not deployed on the backend yet.
  unavailable,
  unknown;

  static const _codes = <String, WatchPartyError>{
    'auth_required': authRequired,
    'rate_limited': rateLimited,
    'invalid_name': invalidName,
    'not_found': notFound,
    'room_full': roomFull,
    'removed': removed,
    'not_member': notMember,
    'room_closed': roomClosed,
    'host_only': hostOnly,
    'invalid_media': invalidMedia,
    'invalid_state': invalidState,
    'no_media': noMedia,
    'invalid_message': invalidMessage,
    'invalid_participant': invalidParticipant,
    'unavailable': unavailable,
  };

  static WatchPartyError fromCode(String? code) => _codes[code] ?? unknown;

  /// Text for the person using the app.
  String get message => switch (this) {
        authRequired => 'Sign in to your Orvix account to use Watch Party.',
        rateLimited => 'Too many attempts. Wait a moment and try again.',
        invalidName => 'Enter a name others will see (up to 24 characters).',
        notFound => 'No room found for that code. Check it and try again.',
        roomFull => 'This room is full (10 people).',
        removed => 'The host removed you from this room.',
        notMember => 'You are no longer in this room.',
        roomClosed => 'This room has ended.',
        hostOnly => 'Only the host can do that.',
        invalidMedia => 'This title cannot be shared in a Watch Party.',
        invalidState || noMedia => 'The host has not started a title yet.',
        invalidMessage => 'Messages must be 1 to 500 characters.',
        invalidParticipant => 'That person is no longer in the room.',
        network => 'Could not reach Orvix. Check your connection.',
        unavailable => 'Watch Party is not available yet.',
        unknown => 'Something went wrong. Try again.',
      };
}

class WatchPartyException implements Exception {
  const WatchPartyException(this.error);

  final WatchPartyError error;

  @override
  String toString() => 'WatchPartyException(${error.name})';
}

/// One event from the room's Realtime topic.
sealed class WatchPartyEvent {
  const WatchPartyEvent();

  /// Decodes a broadcast. Returns null for anything unexpected, so a
  /// malformed message is dropped instead of acted on.
  static WatchPartyEvent? parse(String event, Object? payload) {
    // The realtime client hands over the whole broadcast envelope.
    var body = payload;
    if (body is Map && body['payload'] is Map && body.containsKey('event')) {
      body = body['payload'];
    }
    if (body is! Map) return null;
    switch (event) {
      case 'state':
        final playback = WatchPartyPlayback.fromJson(body['playback']);
        if (playback == null) return null;
        return WatchPartyStateEvent(
          playback,
          WatchPartyMedia.fromJson(body['media']),
        );
      case 'roster':
        final roster = WatchPartyRoster.fromJson(body);
        return roster == null ? null : WatchPartyRosterEvent(roster);
      case 'chat':
        final message = WatchPartyMessage.fromJson(body);
        return message == null ? null : WatchPartyChatEvent(message);
      case 'closed':
        return WatchPartyClosedEvent(body['reason']?.toString());
      case 'rekey':
        return const WatchPartyRekeyEvent();
    }
    return null;
  }
}

class WatchPartyStateEvent extends WatchPartyEvent {
  const WatchPartyStateEvent(this.playback, this.media);
  final WatchPartyPlayback playback;
  final WatchPartyMedia? media;
}

class WatchPartyRosterEvent extends WatchPartyEvent {
  const WatchPartyRosterEvent(this.roster);
  final WatchPartyRoster roster;
}

class WatchPartyChatEvent extends WatchPartyEvent {
  const WatchPartyChatEvent(this.message);
  final WatchPartyMessage message;
}

class WatchPartyClosedEvent extends WatchPartyEvent {
  const WatchPartyClosedEvent(this.reason);
  final String? reason;
}

/// The topic was replaced; fetch the room again to learn the new one.
class WatchPartyRekeyEvent extends WatchPartyEvent {
  const WatchPartyRekeyEvent();
}

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  if (raw is String) return int.tryParse(raw);
  return null;
}

String? _text(Object? raw) {
  final value = raw?.toString().trim();
  return (value == null || value.isEmpty) ? null : value;
}
