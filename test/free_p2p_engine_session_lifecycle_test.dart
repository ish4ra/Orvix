import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';

/// Stand-in for the local stream-server on 127.0.0.1:11470 that models the
/// one property these tests depend on: the engine keeps one torrent session
/// per info hash, and `/{hash}/remove` destroys it for every request that is
/// still using it (a pending `/create` fails, further reads find nothing).
class _SessionEngine {
  _SessionEngine({
    this.createDelay = Duration.zero,
    this.readDelay = Duration.zero,
    this.deadFiles = const <int>{},
  });

  final Duration createDelay;
  final Duration readDelay;

  /// File indexes the engine cannot serve (404 at once).
  final Set<int> deadFiles;

  /// When false every request fails like a closed localhost port.
  bool alive = true;

  /// When set, the engine dies as soon as a stream read arrives.
  bool dieOnRead = false;

  /// When set, `/create` fails at the transport level while the engine
  /// itself keeps answering.
  bool createTransportError = false;

  /// Torrents whose `/create` the engine rejects (HTTP 500).
  final rejected = <String>{};

  final removed = <String>[];
  final _destroyed = <String>{};

  late final MockClient client = MockClient.streaming((request, body) async {
    if (!alive) throw http.ClientException('Connection refused', request.url);
    final path = request.url.path;
    final segments = request.url.pathSegments;
    if (path == '/heartbeat') return _json(<String, Object?>{});
    if (path == '/create') {
      if (createTransportError) {
        throw http.ClientException('Connection reset', request.url);
      }
      final payload =
          jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      final hash = RegExp(r'btih:([a-z0-9]+)')
          .firstMatch(payload['from'] as String)!
          .group(1)!;
      _destroyed.remove(hash);
      if (rejected.contains(hash)) {
        return _json(<String, Object?>{'error': 'rejected'}, status: 500);
      }
      await Future<void>.delayed(createDelay);
      if (!alive) throw http.ClientException('Connection reset', request.url);
      if (_destroyed.contains(hash)) {
        // The torrent was removed while its metadata was still resolving.
        return _json(<String, Object?>{'error': 'torrent destroyed'},
            status: 500);
      }
      return _json(<String, Object?>{'guessedFileIdx': 0});
    }
    if (segments.length == 2 && segments[1] == 'remove') {
      removed.add(segments[0]);
      _destroyed.add(segments[0]);
      return _json(<String, Object?>{});
    }
    if (segments.length == 2 && segments[1] == 'stats.json') {
      return _json(null, status: 404);
    }
    if (segments.length == 3 && segments[2] == 'stats.json') {
      return _json(<String, Object?>{'peers': 6, 'swarmConnections': 4});
    }
    if (segments.length == 2) {
      if (dieOnRead) {
        alive = false;
        throw http.ClientException('Connection reset', request.url);
      }
      final hash = segments[0];
      final file = int.tryParse(segments[1]) ?? -1;
      if (deadFiles.contains(file)) return _json(null, status: 404);
      await Future<void>.delayed(readDelay);
      if (_destroyed.contains(hash)) return _json(null, status: 404);
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers['Range'] ?? '');
      final length = range == null
          ? 512 * 1024
          : int.parse(range.group(2)!) - int.parse(range.group(1)!) + 1;
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(length)),
        206,
      );
    }
    return _json(null, status: 404);
  });

  http.StreamedResponse _json(Map<String, Object?>? body, {int status = 200}) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body ?? {}))),
      status,
    );
  }
}

SourceResult _torrent(String hashChar, {int? fileIndex = 0}) {
  return SourceResult(
    provider: 'Torrentio',
    title: 'Release $hashChar ${fileIndex ?? 'auto'}',
    resource: 'magnet:?xt=urn:btih:${hashChar * 40}',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    torrentFileIndex: fileIndex,
  );
}

Future<LocalTorrentProbeResult> _probe(
  SourceResult source, {
  bool retain = true,
}) {
  return LocalTorrentService.instance.probe(
    source,
    retainSession: retain,
    timeout: const Duration(milliseconds: 800),
    metadataFastDeadline: const Duration(milliseconds: 150),
    metadataExtendedDeadline: const Duration(milliseconds: 400),
  );
}

void main() {
  final service = LocalTorrentService.instance;

  Future<T> withEngine<T>(
    _SessionEngine engine,
    Future<T> Function() body,
  ) {
    return http.runWithClient(() async {
      try {
        return await body();
      } finally {
        engine.alive = true;
        engine.dieOnRead = false;
        await service.releaseRetainedProbeSessions();
        await service.releaseCurrentStream();
      }
    }, () => engine.client);
  }

  group('probe and playback share one engine session per torrent', () {
    test(
        'a probe that gives up on metadata never removes the torrent playback '
        'is resolving', () async {
      // Metadata takes longer than the probe's deadline but well inside the
      // playback resolve timeout: the user picked a row that was still
      // CHECKING.
      final engine = _SessionEngine(
        createDelay: const Duration(milliseconds: 700),
      );
      final source = _torrent('a');
      await withEngine(engine, () async {
        final probe = _probe(source, retain: false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final playback = service.resolve(source);

        final probeResult = await probe;
        expect(probeResult.status, LocalTorrentProbeStatus.metadataTimeout);
        expect(engine.removed, isNot(contains('a' * 40)),
            reason: 'playback still needs this torrent session');

        final url = await playback;
        expect(url, contains('a' * 40));
        expect(engine.removed, isEmpty);
      });
    });

    test(
        'a failed probe of another file in the same torrent does not cut a '
        'live probe short', () async {
      // Two providers return the same torrent with different file routing.
      final engine = _SessionEngine(
        readDelay: const Duration(milliseconds: 120),
        deadFiles: const <int>{1},
      );
      final good = _torrent('b', fileIndex: 0);
      final bad = _torrent('b', fileIndex: 1);
      await withEngine(engine, () async {
        final results = await Future.wait([_probe(good), _probe(bad)]);

        expect(results[1].confirmedLive, isFalse);
        expect(results[0].confirmedLive, isTrue,
            reason: 'the session was not destroyed under the live probe');
        expect(engine.removed, isEmpty,
            reason: 'the live probe keeps the shared session warm');

        // Leaving the picker detaches the shared session exactly once.
        await service.releaseRetainedProbeSessions();
        expect(engine.removed, ['b' * 40]);
      });
    });

    test('a later failed probe of the same torrent keeps the warm session',
        () async {
      final engine = _SessionEngine(deadFiles: const <int>{1});
      final good = _torrent('c', fileIndex: 0);
      final bad = _torrent('c', fileIndex: 1);
      await withEngine(engine, () async {
        expect((await _probe(good)).confirmedLive, isTrue);
        expect((await _probe(bad)).confirmedLive, isFalse);
        expect(engine.removed, isEmpty);

        await service.prepareRetainedProbeForPlayback(good);
        final url = await service.resolve(good);
        expect(url, contains('c' * 40));
        expect(engine.removed, isEmpty);
      });
    });

    test('an unrelated failed probe is still detached at once', () async {
      final engine = _SessionEngine(deadFiles: const <int>{0});
      await withEngine(engine, () async {
        expect((await _probe(_torrent('d'))).confirmedLive, isFalse);
        expect(engine.removed, ['d' * 40]);
      });
    });
  });

  group('every detach path respects torrent-level ownership', () {
    tearDown(() => service.probeHandoffWindow = const Duration(seconds: 25));

    test(
        'a cancelled preparation never detaches a torrent a probe is still '
        'sampling', () async {
      // Back cancelled the preparation of A; its resolve finishes late while
      // the reopened source list (or a new Play) is already probing A.
      final engine =
          _SessionEngine(readDelay: const Duration(milliseconds: 200));
      final source = _torrent('a');
      await withEngine(engine, () async {
        await service.resolve(source);
        final probe = _probe(_torrent('a', fileIndex: 2), retain: false);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        await service.releaseAbandonedStream(source);
        expect(engine.removed, isEmpty,
            reason: 'the probe still uses this torrent session');

        final result = await probe;
        expect(result.confirmedLive, isTrue,
            reason: 'the session was not destroyed under the probe');
        // The probe was the last user: detached exactly once.
        expect(engine.removed, ['a' * 40]);
      });
    });

    test('a cancelled preparation keeps a torrent a live probe kept warm',
        () async {
      final engine = _SessionEngine();
      final source = _torrent('b');
      await withEngine(engine, () async {
        await service.resolve(source);
        expect(
            (await _probe(_torrent('b', fileIndex: 2))).confirmedLive, isTrue);

        await service.releaseAbandonedStream(source);
        expect(engine.removed, isEmpty);

        await service.releaseRetainedProbeSessions();
        expect(engine.removed, ['b' * 40]);
      });
    });

    test('a cancelled preparation still detaches its own unused torrent',
        () async {
      final engine = _SessionEngine();
      final source = _torrent('c');
      await withEngine(engine, () async {
        await service.resolve(source);
        await service.releaseAbandonedStream(source);
        expect(engine.removed, ['c' * 40]);
      });
    });

    test(
        'the handoff timeout never detaches a torrent a probe is still '
        'sampling', () async {
      service.probeHandoffWindow = const Duration(milliseconds: 150);
      final engine =
          _SessionEngine(readDelay: const Duration(milliseconds: 500));
      final handedOff = _torrent('d');
      await withEngine(engine, () async {
        expect((await _probe(handedOff)).confirmedLive, isTrue);
        await service.prepareRetainedProbeForPlayback(handedOff);
        // Playback never resolved it (for example its attempt failed), and
        // the reopened list probes another file of the same torrent across
        // the handoff timeout.
        final sibling = _probe(_torrent('d', fileIndex: 3), retain: false);
        // After the timeout fired, while the probe is still reading.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(engine.removed, isEmpty,
            reason: 'the timeout fired while the probe used the session');

        expect((await sibling).confirmedLive, isTrue);
        expect(engine.removed, ['d' * 40],
            reason: 'detached once, by its last user');
      });
    });

    test('the handoff timeout still detaches an unused warm session', () async {
      service.probeHandoffWindow = const Duration(milliseconds: 100);
      final engine = _SessionEngine();
      final handedOff = _torrent('e');
      await withEngine(engine, () async {
        expect((await _probe(handedOff)).confirmedLive, isTrue);
        await service.prepareRetainedProbeForPlayback(handedOff);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(engine.removed, ['e' * 40]);
      });
    });

    test(
        'starting another stream never detaches the previous torrent while '
        'a probe still samples it', () async {
      // The previous stream stayed current (its player never opened), and
      // the source list is probing another file of it when the user picks a
      // different torrent.
      final engine =
          _SessionEngine(readDelay: const Duration(milliseconds: 200));
      await withEngine(engine, () async {
        await service.resolve(_torrent('f'));
        final probe = _probe(_torrent('f', fileIndex: 4), retain: false);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        await service.resolve(_torrent('9'));
        expect(engine.removed, isNot(contains('f' * 40)));

        expect((await probe).confirmedLive, isTrue);
        expect(engine.removed, ['f' * 40]);
      });
    });

    test('starting another stream still detaches the unused previous one',
        () async {
      final engine = _SessionEngine();
      await withEngine(engine, () async {
        await service.resolve(_torrent('7'));
        await service.resolve(_torrent('8'));
        expect(engine.removed, ['7' * 40]);
      });
    });
  });

  group('playback attempts never leave torrents behind', () {
    test('a failed playback resolve detaches its torrent', () async {
      final engine = _SessionEngine()..rejected.add('a' * 40);
      await withEngine(engine, () async {
        await expectLater(
          service.resolve(_torrent('a')),
          throwsA(isA<LocalTorrentException>()),
        );
        expect(engine.removed, ['a' * 40],
            reason: 'an abandoned attempt must not keep connecting to peers');
      });
    });

    test('a failed resolve keeps a torrent a live probe kept warm', () async {
      final engine = _SessionEngine();
      final source = _torrent('b');
      await withEngine(engine, () async {
        expect((await _probe(source)).confirmedLive, isTrue);
        engine.rejected.add('b' * 40);
        await expectLater(
          service.resolve(source),
          throwsA(isA<LocalTorrentException>()),
        );
        expect(engine.removed, isEmpty);
      });
    });

    test('a failed resolve keeps a torrent another probe is still sampling',
        () async {
      final engine =
          _SessionEngine(readDelay: const Duration(milliseconds: 200));
      final source = _torrent('c');
      await withEngine(engine, () async {
        final probe = _probe(source, retain: false);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        engine.rejected.add('c' * 40);
        await expectLater(
          service.resolve(source),
          throwsA(isA<LocalTorrentException>()),
        );
        expect(engine.removed, isEmpty,
            reason: 'the probe still needs the session');
        await probe;
        // The probe was the last user: now it is detached once.
        expect(engine.removed, ['c' * 40]);
      });
    });

    test(
        'a player exit never detaches the torrent a newer resolve is '
        'creating', () async {
      final engine =
          _SessionEngine(createDelay: const Duration(milliseconds: 200));
      final old = _torrent('d');
      await withEngine(engine, () async {
        await service.resolve(old);
        engine.removed.clear();
        // The next fallback source is the same torrent (another file): its
        // resolve starts while the previous player's exit cleanup runs.
        final next = service.resolve(_torrent('d', fileIndex: 3));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await service.releaseCurrentStream();
        expect(engine.removed, isEmpty);
        expect(await next, contains('d' * 40));
      });
    });

    test('a player exit detaches the torrent it played', () async {
      final engine = _SessionEngine();
      await withEngine(engine, () async {
        await service.resolve(_torrent('e'));
        await service.releaseCurrentStream();
        expect(engine.removed, ['e' * 40]);
      });
    });
  });

  group('engine failures are not blamed on the torrent', () {
    test('an engine that dies while sampling is ENGINE ERROR, not NO PEERS',
        () async {
      final engine = _SessionEngine()..dieOnRead = true;
      final result =
          await withEngine(engine, () => _probe(_torrent('e'), retain: false));

      expect(result.status, LocalTorrentProbeStatus.engineUnavailable);
      expect(result.label, 'ENGINE ERROR');
      expect(result.status, isNot(LocalTorrentProbeStatus.noPeers));
    });

    test('an engine that dies during create is ENGINE ERROR, not SOURCE ERROR',
        () async {
      final engine = _SessionEngine(
        createDelay: const Duration(milliseconds: 50),
      );
      final result = await withEngine(engine, () async {
        final probe = _probe(_torrent('f'), retain: false);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        engine.alive = false;
        return probe;
      });

      expect(result.status, LocalTorrentProbeStatus.engineUnavailable);
      expect(result.label, 'ENGINE ERROR');
    });

    test('a create transport error with a live engine stays a source error',
        () async {
      final engine = _SessionEngine()..createTransportError = true;
      final result =
          await withEngine(engine, () => _probe(_torrent('9'), retain: false));
      expect(result.status, LocalTorrentProbeStatus.createError);
      expect(result.label, 'SOURCE ERROR');
    });
  });
}
