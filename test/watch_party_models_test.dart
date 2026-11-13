// Watch Party building blocks: the wire format, the server clock estimate,
// chat validation and the catalog identity two people must share.

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/services/watch_party/watch_party_chat_policy.dart';
import 'package:orvix/services/watch_party/watch_party_clock.dart';
import 'package:orvix/services/watch_party/watch_party_models.dart';

void main() {
  group('server clock', () {
    test('is unknown before the first sample', () {
      final clock = WatchPartyClock(localNowMs: () => 5000);
      expect(clock.isSynced, isFalse);
      expect(clock.serverNowMs, isNull);
    });

    test('uses the midpoint of the round trip', () {
      var now = 1000;
      final clock = WatchPartyClock(localNowMs: () => now);
      // Sent at 1000, answered at 1200; the server stamped 50100 in between.
      clock.addSample(
          sentAtLocalMs: 1000, receivedAtLocalMs: 1200, serverMs: 50100);
      now = 1200;
      expect(clock.serverNowMs, 50200);
      expect(clock.uncertaintyMs, 100);
      now = 4200;
      expect(clock.serverNowMs, 53200, reason: 'advances with local time');
    });

    test('trusts the fastest round trip, not the latest', () {
      var now = 0;
      final clock = WatchPartyClock(localNowMs: () => now);
      clock.addSample(sentAtLocalMs: 0, receivedAtLocalMs: 40, serverMs: 9020);
      // A slow, lopsided request suggests a different offset.
      clock.addSample(
          sentAtLocalMs: 100, receivedAtLocalMs: 1900, serverMs: 9300);
      now = 2000;
      expect(clock.serverNowMs, 11000);
      expect(clock.uncertaintyMs, 20);
    });

    test('ignores round trips too slow to say anything', () {
      final clock = WatchPartyClock(localNowMs: () => 0);
      clock.addSample(
          sentAtLocalMs: 0, receivedAtLocalMs: 9000, serverMs: 123456);
      clock.addSample(sentAtLocalMs: 50, receivedAtLocalMs: 10, serverMs: 1);
      expect(clock.isSynced, isFalse);
    });

    test('forgets old samples so slow clock drift is followed', () {
      var now = 0;
      final clock = WatchPartyClock(localNowMs: () => now);
      clock.addSample(sentAtLocalMs: 0, receivedAtLocalMs: 2, serverMs: 1001);
      for (var i = 1; i <= WatchPartyClock.maxSamples; i++) {
        clock.addSample(
          sentAtLocalMs: i * 1000,
          receivedAtLocalMs: i * 1000 + 100,
          serverMs: i * 1000 + 1500 + 50,
        );
      }
      now = 20000;
      // The early 2 ms sample (offset 1000) has been dropped.
      expect(clock.serverNowMs, 21500);
    });
  });

  group('playback state', () {
    test('a playing state advances with the server clock', () {
      const state = WatchPartyPlayback(
          seq: 4, playing: true, positionMs: 60000, atMs: 1000000);
      expect(state.positionAt(1000000), 60000);
      expect(state.positionAt(1012500), 72500);
      // A device whose clock estimate is slightly behind never runs backwards.
      expect(state.positionAt(999000), 60000);
    });

    test('a paused state stays put', () {
      const state = WatchPartyPlayback(
          seq: 4, playing: false, positionMs: 60000, atMs: 1000000);
      expect(state.positionAt(1999999), 60000);
      expect(state.isFresh, isFalse);
      expect(WatchPartyPlayback.initial.isFresh, isTrue);
    });

    test('malformed states are rejected, not guessed', () {
      expect(WatchPartyPlayback.fromJson(null), isNull);
      expect(WatchPartyPlayback.fromJson({'seq': 1}), isNull);
      expect(
        WatchPartyPlayback.fromJson(
            {'seq': 1, 'playing': 'yes', 'position_ms': 0, 'at_ms': 0}),
        isNull,
      );
      final state = WatchPartyPlayback.fromJson(
          {'seq': 7, 'playing': true, 'position_ms': -40, 'at_ms': 12});
      expect(state!.positionMs, 0);
      expect(state.seq, 7);
    });
  });

  group('room title', () {
    const movie = MediaItem(
        id: 'tt1375666',
        kind: MediaKind.movie,
        title: 'Inception',
        year: '2010');
    const show = MediaItem(
        id: 'tt0903747', kind: MediaKind.series, title: 'Breaking Bad');
    const episode =
        EpisodeItem(id: 'tt0903747:1:2', season: 1, episode: 2, title: 'Cat');

    test('the key matches the database format', () {
      expect(WatchPartyMedia.fromItem(movie, null)!.key, 'movie:tt1375666:-:-');
      expect(
          WatchPartyMedia.fromItem(show, episode)!.key, 'series:tt0903747:1:2');
    });

    test('two episodes of one show are different titles', () {
      const other =
          EpisodeItem(id: 'tt0903747:1:3', season: 1, episode: 3, title: 'Bag');
      expect(
        WatchPartyMedia.fromItem(show, episode)!.key,
        isNot(WatchPartyMedia.fromItem(show, other)!.key),
      );
    });

    test('only catalog ids can be shared', () {
      expect(WatchPartyMedia.fromItem(null, null), isNull);
      expect(WatchPartyMedia.fromItem(show, null), isNull,
          reason: 'a series needs an episode');
      for (final id in [
        'https://example.test/stream.mkv?token=abc',
        r'C:\Videos\film.mkv',
        '/storage/emulated/0/film.mkv',
        'magnet:?xt=urn:btih:abc',
        '',
        'x' * 65,
      ]) {
        expect(
          WatchPartyMedia.fromItem(
              MediaItem(id: id, kind: MediaKind.movie, title: 'x'), null),
          isNull,
          reason: id,
        );
      }
    });

    test('labels', () {
      expect(WatchPartyMedia.fromItem(movie, null)!.label, 'Inception (2010)');
      expect(WatchPartyMedia.fromItem(show, episode)!.label,
          'Breaking Bad · S01E02');
    });

    test('round-trips the wire format and opens as a catalog item', () {
      final media = WatchPartyMedia.fromJson({
        'kind': 'series',
        'id': 'tt0903747',
        'season': 1,
        'episode': 2,
        'title': 'Breaking Bad',
        'year': '2008',
        'key': 'series:tt0903747:1:2',
      })!;
      expect(media.key, 'series:tt0903747:1:2');
      final item = media.toItem();
      expect(item.id, 'tt0903747');
      expect(item.kind, MediaKind.series);
      expect(WatchPartyMedia.fromJson({'kind': 'show', 'id': 'x'}), isNull);
      expect(WatchPartyMedia.fromJson({'kind': 'movie'}), isNull);
    });
  });

  group('invite codes', () {
    test('are shown in two groups and compared without separators', () {
      expect(WatchPartyRoom.formatCode('ABCDEFGH'), 'ABCD-EFGH');
      expect(WatchPartyRoom.normalizeCode(' abcd-efgh '), 'ABCDEFGH');
      expect(WatchPartyRoom.normalizeCode('ab cd ef gh'), 'ABCDEFGH');
      expect(WatchPartyRoom.normalizeCode('abcd_efgh!'), 'ABCDEFGH');
    });
  });

  group('snapshots and events', () {
    Map<String, Object?> snapshotJson() => {
          'ok': true,
          'server_time_ms': 1794525165800,
          'you': 'p-1',
          'command_seq': 12,
          'room': {
            'id': 'room-1',
            'code': 'PGR3RU8Q',
            'topic': 'watch_party:key',
            'chat_seq': 2,
            'max_participants': 10,
            'expires_at_ms': 1794568365694,
            'media': {'kind': 'movie', 'id': 'tt1375666', 'title': 'Inception'},
            'playback': {
              'seq': 3,
              'playing': true,
              'position_ms': 905000,
              'at_ms': 1794525165799,
            },
          },
          'roster': {
            'seq': 6,
            'host': 'p-1',
            'participants': [
              {'id': 'p-1', 'name': 'Ali', 'ready': true, 'online': true},
              {
                'id': 'p-2',
                'name': 'Bob',
                'ready': false,
                'buffering': true,
                'online': false,
                'duration_ms': 3480000,
              },
              {'name': 'no id'},
            ],
          },
          'messages': [
            {'seq': 1, 'from': 'p-2', 'name': 'Bob', 'body': 'hi', 'at_ms': 1},
            {'seq': 2, 'from': 'p-1', 'name': 'Ali', 'body': '', 'at_ms': 2},
          ],
        };

    test('a snapshot is read in full', () {
      final snapshot = WatchPartySnapshot.fromJson(snapshotJson())!;
      expect(snapshot.you, 'p-1');
      expect(snapshot.commandSeq, 12);
      expect(snapshot.room.formattedCode, 'PGR3-RU8Q');
      expect(snapshot.room.playback.seq, 3);
      expect(snapshot.room.media!.key, 'movie:tt1375666:-:-');
      expect(snapshot.roster.participants.length, 2,
          reason: 'an entry without an id is dropped');
      expect(snapshot.roster.host!.name, 'Ali');
      expect(snapshot.roster.byId('p-2')!.durationMs, 3480000);
      expect(snapshot.roster.byId('p-2')!.online, isFalse);
      expect(snapshot.messages.single.body, 'hi',
          reason: 'an empty message is dropped');
      expect(snapshot.stale, isFalse);
    });

    test('an incomplete snapshot is refused', () {
      for (final key in ['room', 'roster', 'you', 'server_time_ms']) {
        final json = snapshotJson()..remove(key);
        expect(WatchPartySnapshot.fromJson(json), isNull, reason: key);
      }
      expect(WatchPartySnapshot.fromJson('nope'), isNull);
    });

    test('broadcasts are read with or without the Realtime envelope', () {
      final payload = {
        'playback': {
          'seq': 9,
          'playing': false,
          'position_ms': 10,
          'at_ms': 20,
        },
        'media': null,
      };
      final bare = WatchPartyEvent.parse('state', payload);
      final wrapped = WatchPartyEvent.parse(
          'state', {'event': 'state', 'type': 'broadcast', 'payload': payload});
      expect((bare as WatchPartyStateEvent).playback.seq, 9);
      expect((wrapped as WatchPartyStateEvent).playback.seq, 9);
      expect(wrapped.media, isNull);
    });

    test('every room event has a type and unknown ones are dropped', () {
      expect(
        WatchPartyEvent.parse('roster', {
          'seq': 2,
          'host': 'p-1',
          'participants': [
            {'id': 'p-1', 'name': 'Ali'},
          ],
        }),
        isA<WatchPartyRosterEvent>(),
      );
      expect(
        WatchPartyEvent.parse(
            'chat', {'seq': 3, 'from': 'p-1', 'name': 'Ali', 'body': 'yo'}),
        isA<WatchPartyChatEvent>(),
      );
      expect(WatchPartyEvent.parse('closed', {'reason': 'host'}),
          isA<WatchPartyClosedEvent>());
      expect(WatchPartyEvent.parse('rekey', <String, Object?>{}),
          isA<WatchPartyRekeyEvent>());
      expect(WatchPartyEvent.parse('state', {'playback': 'broken'}), isNull);
      expect(WatchPartyEvent.parse('chat', {'seq': 3}), isNull);
      expect(WatchPartyEvent.parse('presence', {'x': 1}), isNull);
      expect(WatchPartyEvent.parse('state', 'text'), isNull);
    });

    test('every backend error code has a message for the person', () {
      for (final code in [
        'auth_required',
        'rate_limited',
        'invalid_name',
        'not_found',
        'room_full',
        'removed',
        'not_member',
        'room_closed',
        'host_only',
        'invalid_media',
        'invalid_state',
        'no_media',
        'invalid_message',
        'invalid_participant',
        'unavailable',
      ]) {
        final error = WatchPartyError.fromCode(code);
        expect(error, isNot(WatchPartyError.unknown), reason: code);
        expect(error.message, isNotEmpty);
      }
      expect(
          WatchPartyError.fromCode('something_new'), WatchPartyError.unknown);
      expect(WatchPartyError.fromCode(null), WatchPartyError.unknown);
    });
  });

  group('chat rules', () {
    test('text is cleaned to one safe line', () {
      expect(WatchPartyChatPolicy.clean('  hello\n\tthere  '), 'hello there');
      expect(WatchPartyChatPolicy.clean('a\u0000b\u0007c'), 'a b c');
      // Direction overrides can make text read as something else.
      expect(WatchPartyChatPolicy.clean('safe\u202Eexe.txt'), 'safeexe.txt');
      expect(WatchPartyChatPolicy.clean('\u2066x\u2069'), 'x');
      // Sinhala conjuncts need the zero-width joiner.
      expect(WatchPartyChatPolicy.clean('\u0DC1\u0DCA\u200D\u0DBB\u0DD3'),
          '\u0DC1\u0DCA\u200D\u0DBB\u0DD3');
    });

    test('names are trimmed to 24 characters and may not be blank', () {
      expect(WatchPartyChatPolicy.cleanName('   '), isNull);
      expect(WatchPartyChatPolicy.cleanName('\n\t'), isNull);
      expect(WatchPartyChatPolicy.cleanName('  Sam  '), 'Sam');
      expect(WatchPartyChatPolicy.cleanName('x' * 40)!.length, 24);
    });

    test('blank and oversized messages are refused', () {
      final policy = WatchPartyChatPolicy(nowMs: () => 0);
      expect(policy.rejection('   '), isNotNull);
      expect(policy.rejection('\n'), isNotNull);
      expect(policy.rejection('x' * 501), contains('500'));
      expect(policy.rejection('x' * 500), isNull);
      expect(policy.rejection('hi'), isNull);
    });

    test('eight messages in ten seconds, then a short wait', () {
      var now = 0;
      final policy = WatchPartyChatPolicy(nowMs: () => now);
      for (var i = 0; i < 8; i++) {
        expect(policy.rejection('message $i'), isNull);
        policy.recordSent();
        now += 500;
      }
      expect(policy.rejection('one more'), contains('too fast'));
      now = 10000;
      expect(policy.rejection('one more'), isNull,
          reason: 'the first message has left the window');
    });
  });
}
