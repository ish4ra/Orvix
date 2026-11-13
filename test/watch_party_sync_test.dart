// Watch Party playback synchronisation: event ordering, duplicate and
// delayed events, drift correction, buffering, reconnect, host-only control
// and the rules that stop seeking loops. Everything runs on a fake clock
// against an in-memory room, so the timings are exact.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/watch_party/watch_party_chat_policy.dart';
import 'package:orvix/services/watch_party/watch_party_models.dart';
import 'package:orvix/services/watch_party/watch_party_session.dart';

import 'support/watch_party_fakes.dart';

class _Room {
  _Room({bool host = false, WatchPartyMedia? media = inception}) {
    backend = FakeRoomBackend(time, selfIsHost: host)..media = media;
    session = WatchPartySession(
      backend: backend,
      snapshot: backend.snapshot(),
      displayName: 'Me',
      clock: clockFor(time),
      chatPolicy: WatchPartyChatPolicy(nowMs: () => time.nowMs),
      autoTimers: false,
    );
    backend.channel.setConnected(true);
  }

  final time = FakeTime();
  late final FakeRoomBackend backend;
  late final WatchPartySession session;

  /// Lets queued requests and their replies finish.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// One heartbeat, start to finish.
  Future<void> sync() async {
    await settle();
    await session.syncNow();
    await settle();
  }

  /// Lets [ms] of time pass, reading the player every half second as the
  /// app does.
  Future<void> run(int ms, {int step = 500}) async {
    for (var elapsed = 0; elapsed < ms; elapsed += step) {
      time.nowMs += step;
      session.tick();
      await settle();
    }
  }

  /// How far [player] is from where the room says playback should be.
  int drift(FakePlayer player) =>
      player.positionMs - backend.playback.positionAt(backend.serverNowMs);
}

void main() {
  group('following the room', () {
    test('a participant who opens the title joins the room position', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 600000);
      final player = FakePlayer(room.time, positionMs: 15000);

      room.session.attachPlayer(player, inception);
      await room.settle();

      expect(player.commands, ['seek:600000']);
      await room.run(10000);
      expect(player.seeks, 1, reason: 'one seek is enough');
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.session.syncStatus, WatchPartySyncStatus.inSync);
    });

    test('play, pause and seek from the host are applied in order', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.commands.clear();

      room.backend.remoteState(playing: false, positionMs: 90000);
      await room.settle();
      expect(player.playing, isFalse);
      expect(player.commands, ['pause', 'seek:90000']);
      expect(room.session.syncStatus, WatchPartySyncStatus.paused);

      await room.run(4000);
      player.commands.clear();
      room.backend.remoteState(playing: true, positionMs: 1800000);
      await room.settle();
      expect(player.playing, isTrue);
      expect(player.commands, ['play', 'seek:1800000']);

      await room.run(6000);
      expect(room.drift(player).abs(), lessThan(350));
      expect(player.seeks, 1);
    });

    test('host actions in quick succession are each applied at once', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 0);
      room.session.attachPlayer(player, inception);
      await room.settle();
      expect(player.commands, ['seek:60000']);

      // The host scrubs again half a second later, then pauses.
      await room.run(500);
      room.backend.remoteState(playing: true, positionMs: 900000);
      await room.settle();
      expect(player.commands.last, 'seek:900000');

      await room.run(500);
      room.backend.remoteState(playing: false, positionMs: 1200000);
      await room.settle();
      expect(player.commands.sublist(2), ['pause', 'seek:1200000']);
      expect(player.seeks, 3);
    });

    test('duplicate and delayed events change nothing', () async {
      final room = _Room();
      final first = room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);

      final second =
          room.backend.remoteState(playing: true, positionMs: 900000);
      await room.run(5000);
      expect(room.session.room.playback.seq, second.seq);
      final commandsAfterSeek = [...player.commands];

      // The same event again, then an older one that was held up.
      room.backend.channel.emit(WatchPartyStateEvent(second, inception));
      room.backend.channel.emit(WatchPartyStateEvent(first, inception));
      room.backend.channel.emit(WatchPartyStateEvent(second, inception));
      await room.run(5000);

      expect(room.session.room.playback.seq, second.seq);
      expect(player.commands, commandsAfterSeek,
          reason: 'a stale event must not move the player');
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('events that arrive out of order end on the newest state', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      // Pause, then play: delivered as play first, pause second.
      final paused = room.backend
          .remoteState(playing: false, positionMs: 70000, announce: false);
      final resumed = room.backend
          .remoteState(playing: true, positionMs: 70000, announce: false);
      room.backend.channel.emit(WatchPartyStateEvent(resumed, inception));
      room.backend.channel.emit(WatchPartyStateEvent(paused, inception));
      await room.run(3000);

      expect(player.playing, isTrue,
          reason: 'the late pause is older than the play');
      expect(player.commands.contains('pause'), isFalse);
      expect(room.session.room.playback.seq, resumed.seq);
    });

    test('a snapshot older than a received event does not roll back', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.settle();

      // A heartbeat reply is held up while a newer state arrives.
      room.backend.gate = null;
      final newer = room.backend
          .remoteState(playing: true, positionMs: 500000, announce: false);
      room.backend.channel.emit(WatchPartyStateEvent(newer, inception));
      await room.settle();
      final seq = room.session.room.playback.seq;

      // An old view of the room (lower state number) is then applied.
      room.backend.stateSeq = seq - 1;
      room.backend.positionMs = 1;
      await room.sync();
      expect(room.session.room.playback.seq, seq);
      expect(room.session.room.playback.positionMs, 500000);
    });
  });

  group('drift correction', () {
    test('a small gap is closed by speed, not by seeking', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      // One second ahead of the room.
      player.userSeek(player.positionMs + 1000);
      await room.run(1000);
      expect(player.rate, closeTo(0.95, 0.001));
      expect(room.session.syncStatus, isNot(WatchPartySyncStatus.paused));

      await room.run(30000);
      expect(player.seeks, 0);
      expect(player.rate, 1.0, reason: 'normal speed once caught up');
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.session.syncStatus, WatchPartySyncStatus.inSync);
    });

    test('a player that is behind speeds up', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      player.userSeek(player.positionMs - 800);
      await room.run(1000);
      expect(player.rate, closeTo(1.05, 0.001));
      await room.run(30000);
      expect(player.seeks, 0);
      expect(player.rate, 1.0);
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('a gap inside the dead band is left alone', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      player.userSeek(player.positionMs + 250);
      await room.run(10000);
      expect(player.commands, isEmpty);
    });

    test('a large gap is closed with exactly one seek', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      // The participant scrubs a minute ahead with their own controls.
      player.userSeek(player.positionMs + 60000);
      await room.run(8000);

      expect(player.seeks, 1);
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.session.notice, contains('Only the host can seek'));
      expect(room.backend.playbackCalls, isEmpty,
          reason: 'a participant never changes the room');
    });

    test('an engine without speed control seeks at a lower threshold',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player =
          FakePlayer(room.time, positionMs: 60000, canChangeRate: false);
      room.session.attachPlayer(player, inception);
      await room.run(2000);
      player.commands.clear();

      player.userSeek(player.positionMs - 1400);
      await room.run(6000);
      expect(player.seeks, 1);
      expect(player.commands.any((c) => c.startsWith('rate')), isFalse);
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('a slow-seeking source converges instead of seeking again and again',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      // Every seek stalls for 3.5 seconds, longer than the seek threshold.
      final player = FakePlayer(room.time, positionMs: 0)..seekStallMs = 3500;
      room.session.attachPlayer(player, inception);
      await room.run(60000);

      expect(player.seeks, lessThanOrEqualTo(3),
          reason: 'the session learns how long this source takes to seek');
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.session.syncStatus, WatchPartySyncStatus.inSync);
    });

    test('seeks that never settle are spaced further and further apart',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      // Hopeless source: nine seconds of stall per seek.
      final player = FakePlayer(room.time, positionMs: 0)..seekStallMs = 9000;
      room.session.attachPlayer(player, inception);
      await room.run(120000);

      // Seeking every time the stall ends would be 13 seeks.
      expect(player.seeks, lessThanOrEqualTo(7));
    });

    test('playback speed is held at 1x', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);

      player.userSetRate(1.5);
      await room.run(1000);
      expect(player.rate, isNot(1.5));
      expect(room.session.notice, contains('1×'));
      await room.run(20000);
      expect(player.rate, 1.0);
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('nothing is corrected past the end of this device\'s source',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 7190000);
      final player =
          FakePlayer(room.time, positionMs: 7000000, durationMs: 7000000)
            ..playing = false;
      room.session.attachPlayer(player, inception);
      await room.run(20000);
      expect(player.seeks, 0);
    });
  });

  group('buffering', () {
    test('a stalled participant is not seeked, reports it, then catches up',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.commands.clear();
      room.backend.syncCalls.clear();

      player.stalled = true;
      await room.run(1000);
      expect(room.backend.syncCalls.where((c) => c.buffering == true), isEmpty,
          reason: 'a hiccup is not announced');
      await room.run(6000);
      expect(player.commands, isEmpty,
          reason: 'a stalled player is left to recover');
      expect(room.session.syncStatus, WatchPartySyncStatus.buffering);
      expect(room.backend.syncCalls.last.buffering, isTrue);
      expect(room.backend.playbackCalls, isEmpty,
          reason: 'one person buffering never pauses the room');

      player.stalled = false;
      await room.run(8000);
      expect(player.seeks, 1, reason: 'seven seconds behind: one seek');
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.backend.syncCalls.last.buffering, isFalse);
      expect(room.session.syncStatus, WatchPartySyncStatus.inSync);
    });

    test('a host seek reaches a participant who is stalled', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.stalled = true;
      await room.run(2000);
      player.commands.clear();

      room.backend.remoteState(playing: true, positionMs: 2400000);
      await room.settle();
      expect(player.commands, ['seek:2400000']);
    });

    test('a stalled host moves the room back to where the host is', () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      final before = room.backend.playbackCalls.length;

      player.stalled = true;
      await room.run(6000);
      expect(room.backend.playbackCalls.length, before,
          reason: 'nothing is published while the host is stalled');

      player.stalled = false;
      await room.run(8000);
      expect(room.backend.playbackCalls.length, before + 1);
      expect(room.backend.playbackCalls.last.playing, isTrue);
      expect(player.seeks, 0, reason: 'the host is never skipped ahead');
      expect(room.drift(player).abs(), lessThan(350));
    });
  });

  group('this device\'s own controls', () {
    test('a participant\'s pause is respected and ends on play', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.commands.clear();

      player.userPause();
      await room.run(6000);
      expect(player.commands, isEmpty,
          reason: 'the player is not forced back into playing');
      expect(room.session.syncStatus, WatchPartySyncStatus.pausedLocally);

      player.userPlay();
      await room.run(6000);
      expect(player.seeks, 1);
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.backend.playbackCalls, isEmpty);
    });

    test('a host action ends a participant\'s own pause', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.userPause();
      await room.run(3000);
      player.commands.clear();

      room.backend.remoteState(playing: true, positionMs: 300000);
      await room.settle();
      expect(player.commands, ['play', 'seek:300000']);
    });

    test('playing while the room is paused is undone', () async {
      final room = _Room();
      room.backend.remoteState(playing: false, positionMs: 300000);
      final player = FakePlayer(room.time, positionMs: 300000)..playing = false;
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      player.commands.clear();

      player.userPlay();
      await room.run(1000);
      expect(player.playing, isFalse);
      expect(player.commands.first, 'pause');
      expect(room.session.notice, 'The host paused playback.');
      expect(room.backend.playbackCalls, isEmpty);

      await room.run(5000);
      expect((player.positionMs - 300000).abs(), lessThanOrEqualTo(500));
    });

    test('a participant waits at the start until the host begins', () async {
      final room = _Room();
      final player = FakePlayer(room.time, positionMs: 2400000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);

      expect(player.playing, isFalse);
      expect(player.positionMs, 0);
      expect(room.session.syncStatus, WatchPartySyncStatus.waitingForHost);
    });
  });

  group('the host', () {
    test('starting a title sets the room\'s title and starts playback',
        () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);

      expect(room.backend.mediaCalls.single.key, inception.key);
      expect(room.backend.playbackCalls.single.playing, isTrue);
      expect(room.backend.playbackCalls.single.positionMs,
          inInclusiveRange(120000, 121000));
      expect(player.commands, isEmpty,
          reason: 'the host\'s own player is never moved');
    });

    test('a title started while offline is set once the connection returns',
        () async {
      final room = _Room(host: true, media: null);
      await room.settle();
      room.backend.offline = true;
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      expect(room.backend.media, isNull);
      expect(room.backend.mediaCalls, isEmpty);

      room.backend.offline = false;
      await room.sync();
      await room.run(3000);
      expect(room.backend.media!.key, inception.key);
      expect(room.backend.playing, isTrue);
      expect(room.backend.positionMs, greaterThan(120000));
      expect(player.commands, isEmpty);
    });

    test('pause, scrub while paused, play and seek are each published once',
        () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      room.backend.playbackCalls.clear();

      player.userPause();
      await room.run(3000);
      expect(room.backend.playbackCalls.length, 1);
      expect(room.backend.playbackCalls.last.playing, isFalse);

      player.userSeek(900000);
      await room.run(3000);
      expect(room.backend.playbackCalls.length, 2);
      expect(room.backend.playbackCalls.last.positionMs, 900000);
      expect(room.backend.playbackCalls.last.playing, isFalse);

      player.userPlay();
      await room.run(3000);
      expect(room.backend.playbackCalls.length, 3);
      expect(room.backend.playbackCalls.last.playing, isTrue);

      player.userSeek(player.positionMs - 30000);
      await room.run(3000);
      expect(room.backend.playbackCalls.length, 4);

      await room.run(30000);
      expect(room.backend.playbackCalls.length, 4,
          reason: 'steady playback publishes nothing');
      final numbers = [for (final c in room.backend.playbackCalls) c.clientSeq];
      expect(numbers, [...numbers]..sort(),
          reason: 'command numbers only grow');
      expect(numbers.toSet().length, numbers.length);
      expect(player.commands, isEmpty);
    });

    test('a change is not published twice while the first is on its way',
        () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      room.backend.calls.clear();

      room.backend.gate = Completer<void>();
      player.userPause();
      await room.run(4000);
      expect(room.backend.calls.where((c) => c == 'setPlayback').length, 1);

      room.backend.release();
      await room.run(3000);
      expect(room.backend.calls.where((c) => c == 'setPlayback').length, 1);
      expect(room.backend.playing, isFalse);
    });

    test('the room\'s own announcement of a host action moves nothing',
        () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      final published = room.backend.playbackCalls.length;

      room.backend.channel
          .emit(WatchPartyStateEvent(room.backend.playback, inception));
      await room.run(5000);
      expect(player.commands, isEmpty);
      expect(room.backend.playbackCalls.length, published);
    });

    test('a refused command is retried, not dropped', () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);

      room.backend.failNext = WatchPartyError.rateLimited;
      player.userPause();
      await room.run(1000);
      expect(room.backend.playing, isTrue, reason: 'the first try was refused');
      await room.run(5000);
      expect(room.backend.playing, isFalse);
    });

    test('command numbers continue above what the room already accepted',
        () async {
      final room = _Room(host: true, media: inception);
      room.backend.lastCommandSeq = 4000;
      final session = WatchPartySession(
        backend: room.backend,
        snapshot: room.backend.snapshot(),
        displayName: 'Me',
        clock: clockFor(room.time),
        autoTimers: false,
      );
      final player = FakePlayer(room.time, positionMs: 120000);
      session.attachPlayer(player, inception);
      for (var i = 0; i < 6; i++) {
        room.time.nowMs += 500;
        session.tick();
        await room.settle();
      }
      expect(room.backend.playbackCalls.single.clientSeq, 4001);
      expect(room.backend.playing, isTrue);
    });

    test('closing the player pauses the room where the host was', () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      final binding = room.session.attachPlayer(player, inception);
      await room.run(10000);

      binding.detach();
      await room.settle();
      expect(room.backend.playing, isFalse);
      expect(room.backend.positionMs, inInclusiveRange(129000, 131000));
      expect(room.session.syncStatus, WatchPartySyncStatus.noPlayer);
    });

    test('opening a player while the room plays joins the room\'s position',
        () async {
      final room = _Room(host: true, media: inception);
      room.backend.remoteState(playing: true, positionMs: 600000);
      final player = FakePlayer(room.time, positionMs: 5000);
      room.session.attachPlayer(player, inception);
      await room.run(6000);

      expect(player.commands, ['seek:600000']);
      expect(room.backend.playbackCalls, isEmpty,
          reason: 'the room is not pulled back to the host\'s resume point');
      expect(room.drift(player).abs(), lessThan(350));

      player.userPause();
      await room.run(2000);
      expect(room.backend.playbackCalls.single.playing, isFalse);
    });
  });

  group('host-only control', () {
    test('nothing a participant does is ever published', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);

      player.userPause();
      await room.run(2000);
      player.userPlay();
      await room.run(2000);
      player.userSeek(3000000);
      await room.run(6000);
      player.stalled = true;
      await room.run(6000);
      player.stalled = false;
      await room.run(6000);

      expect(room.backend.playbackCalls, isEmpty);
      expect(room.backend.mediaCalls, isEmpty);
      expect(room.backend.calls.contains('setPlayback'), isFalse);
      expect(room.session.isHost, isFalse);
    });

    test('a device handed the host role mid-film starts publishing', () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      player.commands.clear();

      room.backend.makeSelfHost(true);
      await room.run(5000);
      expect(room.session.isHost, isTrue);
      expect(player.commands, isEmpty, reason: 'the hand-over moves nothing');
      expect(room.backend.playbackCalls, isEmpty);

      player.userPause();
      await room.run(2000);
      expect(room.backend.playbackCalls.single.playing, isFalse);
    });

    test('a device that loses the host role stops publishing', () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);
      room.backend.playbackCalls.clear();

      room.backend.makeSelfHost(false);
      await room.run(1000);
      player.userPause();
      await room.run(3000);
      expect(room.backend.playbackCalls, isEmpty);
      expect(room.session.syncStatus, WatchPartySyncStatus.pausedLocally);
    });

    test('a refusal because the role moved makes the device follow again',
        () async {
      final room = _Room(host: true, media: null);
      final player = FakePlayer(room.time, positionMs: 120000);
      room.session.attachPlayer(player, inception);
      await room.run(5000);

      // The role moves on the server; this device has not heard yet.
      room.backend.makeSelfHost(false, announce: false);
      player.userSeek(3000000);
      await room.run(8000);

      expect(room.session.isHost, isFalse);
      expect(room.drift(player).abs(), lessThan(350),
          reason: 'back on the room\'s timeline');
    });
  });

  group('same title', () {
    test('a participant on another episode is told and never moved', () async {
      final room = _Room(media: pilot);
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 5000);
      room.session.attachPlayer(player, secondEpisode);
      await room.run(8000);

      expect(room.session.syncStatus, WatchPartySyncStatus.wrongTitle);
      expect(player.commands, isEmpty);
      expect(room.backend.syncCalls.last.ready, isFalse);
      expect(room.backend.syncCalls.last.mediaKey, secondEpisode.key);
      expect(room.backend.selfReady, isFalse);
    });

    test('when the room moves to this device\'s title it starts following',
        () async {
      final room = _Room(media: pilot);
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 5000);
      room.session.attachPlayer(player, secondEpisode);
      await room.run(3000);

      room.backend.media = secondEpisode;
      room.backend.remoteState(playing: true, positionMs: 200000);
      await room.run(6000);
      expect(room.session.syncStatus, WatchPartySyncStatus.inSync);
      expect(room.drift(player).abs(), lessThan(350));
      expect(room.backend.selfReady, isTrue);
    });

    test('when the host changes title this device stops following', () async {
      final room = _Room(media: pilot);
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, pilot);
      await room.run(3000);
      player.commands.clear();

      room.backend.media = secondEpisode;
      room.backend.remoteState(playing: false, positionMs: 0);
      await room.run(5000);
      expect(room.session.syncStatus, WatchPartySyncStatus.wrongTitle);
      expect(player.commands, isEmpty,
          reason: 'the old episode is not paused or rewound');
      expect(room.backend.syncCalls.last.ready, isFalse);
    });

    test('a video without a catalog id is never synchronised', () async {
      final room = _Room(media: pilot);
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 5000);
      room.session.attachPlayer(player, null);
      await room.run(5000);
      expect(player.commands, isEmpty);
      expect(room.session.syncStatus, WatchPartySyncStatus.wrongTitle);
    });

    test('a device made host while watching something else keeps the room',
        () async {
      final room = _Room(media: pilot);
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 5000);
      room.session.attachPlayer(player, inception);
      await room.run(2000);

      room.backend.makeSelfHost(true);
      await room.run(5000);
      expect(room.backend.mediaCalls, isEmpty);
      expect(room.backend.playbackCalls, isEmpty);
      expect(room.backend.media!.key, pilot.key);
    });

    test('a different runtime than the host\'s is flagged', () async {
      final room = _Room();
      room.backend.otherDurationMs = 7200000;
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player =
          FakePlayer(room.time, positionMs: 60000, durationMs: 7273000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      await room.sync();

      expect(room.session.sourceWarning, contains('1 min 13 s longer'));
      expect(room.backend.selfDurationMs, 7273000);

      player.durationMs = 7201500;
      await room.run(1000);
      expect(room.session.sourceWarning, isNull,
          reason: 'a second or two is normal between encodes');
    });
  });

  group('connection', () {
    test('state and chat missed while offline are recovered in order',
        () async {
      final room = _Room();
      room.backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(room.time, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(3000);
      room.backend.remoteChat('before');
      await room.settle();
      player.commands.clear();

      room.backend.offline = true;
      await room.sync();
      await room.sync();
      expect(room.session.connection, WatchPartyConnection.reconnecting);
      expect(room.session.isEnded, isFalse);

      // The room carries on; none of it reaches this device.
      room.backend
          .remoteState(playing: true, positionMs: 1500000, announce: false);
      room.backend.remoteChat('one', announce: false);
      room.backend.remoteChat('two', announce: false);
      await room.run(4000);
      expect(player.seeks, 0);

      room.backend.offline = false;
      await room.sync();
      expect(room.session.connection, WatchPartyConnection.live);
      expect([for (final m in room.session.messages) m.body],
          ['before', 'one', 'two']);
      await room.run(5000);
      expect(player.seeks, 1);
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('without Realtime the room is polled and still followed', () async {
      final room = _Room();
      room.backend.channel.setConnected(false);
      await room.sync();
      expect(room.session.connection, WatchPartyConnection.polling);

      final player = FakePlayer(room.time, positionMs: 0);
      room.session.attachPlayer(player, inception);
      await room.settle();
      room.backend
          .remoteState(playing: true, positionMs: 420000, announce: false);
      await room.sync();
      await room.run(5000);
      expect(room.drift(player).abs(), lessThan(350));
    });

    test('a resubscribed topic triggers a catch-up', () async {
      final room = _Room();
      room.backend.channel.setConnected(false);
      room.backend.remoteChat('missed', announce: false);
      room.backend.calls.clear();

      room.backend.channel.setConnected(true);
      await room.settle();
      expect(room.backend.calls, contains('sync'));
      expect(room.session.messages.single.body, 'missed');
      expect(room.session.connection, WatchPartyConnection.live);
    });

    test('a replaced topic is followed and the old one is closed', () async {
      final room = _Room();
      final old = room.backend.channel;
      room.backend.topic = 'watch_party:key-2';
      old.emit(const WatchPartyRekeyEvent());
      await room.settle();

      expect(room.backend.channels.length, 2);
      expect(old.closed, isTrue);
      expect(room.backend.channel.topic, 'watch_party:key-2');
      expect(room.session.room.topic, 'watch_party:key-2');
    });

    test('a place lost during a long disconnect is taken back', () async {
      final room = _Room();
      room.backend.failNext = WatchPartyError.notMember;
      await room.sync();
      expect(room.backend.calls, containsAllInOrder(['sync', 'join']));
      expect(room.session.isEnded, isFalse);
    });

    test('a room that is gone ends the session', () async {
      final room = _Room();
      await room.settle();
      room.backend.failNext = WatchPartyError.notMember;
      room.backend.code = 'GONEGONE';
      await room.sync();
      expect(room.session.ended, WatchPartyEndReason.expired);
      expect(room.backend.channel.closed, isTrue);
    });

    test('being removed, a closed room and a signed-out account end it',
        () async {
      var room = _Room();
      room.backend.failNext = WatchPartyError.removed;
      await room.sync();
      expect(room.session.ended, WatchPartyEndReason.removed);

      room = _Room();
      room.backend.channel.emit(const WatchPartyClosedEvent('host'));
      expect(room.session.ended, WatchPartyEndReason.closed);
      // Nothing more is sent after the end.
      room.backend.calls.clear();
      await room.sync();
      expect(room.backend.calls, isEmpty);

      room = _Room();
      room.backend.failNext = WatchPartyError.authRequired;
      await room.sync();
      expect(room.session.ended, WatchPartyEndReason.signedOut);
    });

    test('leaving ends the session even when the request fails', () async {
      final room = _Room();
      final player = FakePlayer(room.time);
      room.backend.remoteState(playing: true, positionMs: 60000);
      room.session.attachPlayer(player, inception);
      await room.run(1000);
      player.commands.clear();

      room.backend.offline = true;
      await room.session.leave();
      expect(room.session.ended, WatchPartyEndReason.left);

      // The player is left alone from here on.
      player.userSeek(999000);
      await room.run(5000);
      expect(player.commands, isEmpty);
    });
  });

  group('timers', () {
    testWidgets('heartbeats are slow while live and fast while polling',
        (tester) async {
      final time = FakeTime();
      final backend = FakeRoomBackend(time)..media = inception;
      final session = WatchPartySession(
        backend: backend,
        snapshot: backend.snapshot(),
        displayName: 'Me',
        clock: clockFor(time),
      );
      Future<void> pass(int ms) async {
        for (var elapsed = 0; elapsed < ms; elapsed += 500) {
          time.nowMs += 500;
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      backend.channel.setConnected(true);
      await pass(1000);
      backend.calls.clear();
      await pass(60000);
      expect(backend.calls.where((c) => c == 'sync').length,
          inInclusiveRange(3, 5),
          reason: 'about one heartbeat every 15 seconds');

      backend.channel.setConnected(false);
      await pass(1000);
      backend.calls.clear();
      await pass(30000);
      expect(backend.calls.where((c) => c == 'sync').length,
          inInclusiveRange(8, 11),
          reason: 'about one poll every 3 seconds');

      // Failing requests back off instead of hammering the backend.
      backend.offline = true;
      await pass(5000);
      backend.calls.clear();
      await pass(120000);
      expect(
          backend.calls.where((c) => c == 'sync').length, lessThanOrEqualTo(6));

      await session.leave();
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('an attached player is read on a timer until it detaches',
        (tester) async {
      final time = FakeTime();
      final backend = FakeRoomBackend(time)..media = inception;
      final session = WatchPartySession(
        backend: backend,
        snapshot: backend.snapshot(),
        displayName: 'Me',
        clock: clockFor(time),
      );
      backend.channel.setConnected(true);
      backend.remoteState(playing: true, positionMs: 60000);
      final player = FakePlayer(time, positionMs: 0);
      final binding = session.attachPlayer(player, inception);
      for (var i = 0; i < 12; i++) {
        time.nowMs += 500;
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(player.seeks, 1);

      binding.detach();
      player.commands.clear();
      player.userSeek(5);
      for (var i = 0; i < 12; i++) {
        time.nowMs += 500;
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(player.commands, isEmpty);

      await session.leave();
      await tester.pump(const Duration(seconds: 40));
    });
  });
}
