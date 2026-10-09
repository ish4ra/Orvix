import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';

enum _StreamMode { bytes, hang, empty }

/// Deterministic stand-in for the local stream-server on 127.0.0.1:11470.
/// Requests are routed through [http.runWithClient], so no port is bound and
/// no real torrent network is touched.
class _FakeEngine {
  _FakeEngine({
    this.createDelay = Duration.zero,
    this.createNeverAnswers = false,
    this.createStatus = 200,
    this.swarmStats,
    this.fileStats = const {'peers': 6, 'swarmConnections': 4},
    this.streamMode = _StreamMode.bytes,
    this.heartbeatOk = true,
  });

  final Duration createDelay;
  final bool createNeverAnswers;
  final int createStatus;
  final Map<String, Object?>? swarmStats;
  final Map<String, Object?> fileStats;
  final _StreamMode streamMode;
  final bool heartbeatOk;

  final removed = <String>[];
  final created = <String>[];
  final _hangs = <StreamController<List<int>>>[];

  late final MockClient client = MockClient.streaming((request, body) async {
    final path = request.url.path;
    final segments = request.url.pathSegments;
    if (path == '/heartbeat') {
      return _json(heartbeatOk ? <String, Object?>{} : null,
          status: heartbeatOk ? 200 : 503);
    }
    if (path == '/create') {
      final payload =
          jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
      final hash = RegExp(r'btih:([a-z0-9]+)')
          .firstMatch(payload['from'] as String)!
          .group(1)!;
      created.add(hash);
      if (createNeverAnswers) {
        await Completer<void>().future;
      }
      await Future<void>.delayed(createDelay);
      return _json(<String, Object?>{'guessedFileIdx': 0},
          status: createStatus);
    }
    if (segments.length == 2 && segments[1] == 'remove') {
      removed.add(segments[0]);
      return _json(<String, Object?>{});
    }
    if (segments.length == 2 && segments[1] == 'stats.json') {
      final stats = swarmStats;
      return stats == null ? _json(null, status: 404) : _json(stats);
    }
    if (segments.length == 3 && segments[2] == 'stats.json') {
      return _json(fileStats);
    }
    if (segments.length == 2) {
      switch (streamMode) {
        case _StreamMode.bytes:
          final range = RegExp(r'bytes=(\d+)-(\d+)')
              .firstMatch(request.headers['Range'] ?? '');
          final length = range == null
              ? 512 * 1024
              : int.parse(range.group(2)!) - int.parse(range.group(1)!) + 1;
          return http.StreamedResponse(
            Stream<List<int>>.value(Uint8List(length)),
            206,
          );
        case _StreamMode.hang:
          final controller = StreamController<List<int>>();
          _hangs.add(controller);
          return http.StreamedResponse(controller.stream, 206);
        case _StreamMode.empty:
          return http.StreamedResponse(const Stream<List<int>>.empty(), 206);
      }
    }
    return _json(null, status: 404);
  });

  http.StreamedResponse _json(Map<String, Object?>? body, {int status = 200}) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body ?? {}))),
      status,
    );
  }

  void dispose() {
    for (final controller in _hangs) {
      unawaited(controller.close());
    }
  }
}

SourceResult _torrent(String hashChar, {int? seeders, int? sizeBytes}) {
  return SourceResult(
    provider: 'Torrentio',
    title: 'Release $hashChar',
    resource: 'magnet:?xt=urn:btih:${hashChar * 40}',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    seeders: seeders,
    sizeBytes: sizeBytes,
    torrentFileIndex: 0,
  );
}

const _fast = Duration(milliseconds: 200);
const _extended = Duration(milliseconds: 600);
const _sample = Duration(milliseconds: 500);

/// Earliest a wait that runs to the extended deadline can end, measured on a
/// microsecond [Stopwatch]. The probe waits `extended - elapsed` on the same
/// in-flight request, and Dart VM timers are scheduled in whole milliseconds
/// (`Duration.inMilliseconds` truncates), so up to one millisecond of that
/// remainder is dropped. Production timing is unchanged; this is the exact
/// bound the timer guarantees, not a tolerance.
final _extendedTimerFloor = _extended - const Duration(milliseconds: 1);

Future<LocalTorrentProbeResult> _probe(
  SourceResult source, {
  bool retain = true,
}) {
  return LocalTorrentService.instance.probe(
    source,
    retainSession: retain,
    timeout: _sample,
    metadataFastDeadline: _fast,
    metadataExtendedDeadline: _extended,
  );
}

Future<void> _resetEngineState() async {
  await LocalTorrentService.instance.releaseRetainedProbeSessions();
  await LocalTorrentService.instance.releaseCurrentStream();
}

void main() {
  final service = LocalTorrentService.instance;
  tearDown(() => service.debugStartEngineOverride = null);

  Future<T> withEngine<T>(_FakeEngine engine, Future<T> Function() body) {
    return http.runWithClient(() async {
      try {
        return await body();
      } finally {
        await _resetEngineState();
        engine.dispose();
      }
    }, () => engine.client);
  }

  test('metadata timeout with discovered peers is unresolved, not dead',
      () async {
    final engine = _FakeEngine(
      createNeverAnswers: true,
      swarmStats: const {'peers': 0, 'unique': 12, 'swarmConnections': 0},
    );
    final source = _torrent('a', seeders: 140);
    final watch = Stopwatch()..start();
    final result = await withEngine(engine, () => _probe(source));
    watch.stop();

    expect(result.status, LocalTorrentProbeStatus.metadataTimeout);
    expect(result.label, 'METADATA SLOW');
    expect(result.metadataResolved, isFalse);
    expect(result.confirmedLive, isFalse);
    expect(result.discoveredPeers, 12);
    // Promising candidates keep the same request up to the extended deadline,
    // well past the fast deadline where an empty swarm stops.
    expect(result.metadataElapsed, greaterThan(_extendedTimerFloor));
    expect(watch.elapsed, greaterThan(_extendedTimerFloor));
    expect(watch.elapsed, greaterThanOrEqualTo(result.metadataElapsed!));
    // A metadata timeout is never reported as a confirmed empty swarm.
    expect(result.status, isNot(LocalTorrentProbeStatus.noPeers));
    // The abandoned probe session is detached.
    expect(engine.removed, contains('a' * 40));
  });

  test('metadata timeout stops at the fast deadline on an explicit empty swarm',
      () async {
    final engine = _FakeEngine(
      createNeverAnswers: true,
      swarmStats: const {'peers': 0, 'unique': 0, 'swarmConnections': 0},
    );
    final watch = Stopwatch()..start();
    final result = await withEngine(engine, () => _probe(_torrent('b')));
    watch.stop();

    expect(result.status, LocalTorrentProbeStatus.metadataTimeout);
    expect(result.discoveredPeers, 0);
    expect(watch.elapsed, lessThan(_extended));
  });

  test('slow metadata inside the extended deadline is sampled, not rejected',
      () async {
    final engine = _FakeEngine(
      createDelay: const Duration(milliseconds: 350),
      swarmStats: const {'peers': 2, 'unique': 9},
    );
    final result = await withEngine(engine, () => _probe(_torrent('c')));

    expect(result.metadataResolved, isTrue);
    expect(result.confirmedLive, isTrue);
    expect(result.metadataElapsed!.inMilliseconds, greaterThanOrEqualTo(300));
  });

  test('engine startup failure is classified apart from swarm failures',
      () async {
    final engine = _FakeEngine(heartbeatOk: false);
    service.debugStartEngineOverride =
        () async => throw const LocalTorrentException('engine failed');
    final result = await withEngine(engine, () => _probe(_torrent('d')));

    expect(result.status, LocalTorrentProbeStatus.engineUnavailable);
    expect(result.label, 'ENGINE ERROR');
    expect(engine.created, isEmpty, reason: 'no torrent was ever created');
  });

  test('create HTTP error is a source error, not a metadata timeout',
      () async {
    final engine = _FakeEngine(createStatus: 500);
    final result = await withEngine(engine, () => _probe(_torrent('e')));

    expect(result.status, LocalTorrentProbeStatus.createError);
    expect(result.label, 'SOURCE ERROR');
    expect(engine.removed, contains('e' * 40));
  });

  test('peers without media bytes is stalled', () async {
    final engine = _FakeEngine(
      streamMode: _StreamMode.hang,
      fileStats: const {'peers': 5, 'swarmConnections': 3, 'downloadSpeed': 0},
    );
    final result = await withEngine(engine, () => _probe(_torrent('f')));

    expect(result.metadataResolved, isTrue);
    expect(result.bytesReceived, 0);
    expect(result.peers, 5);
    expect(result.status, LocalTorrentProbeStatus.stalled);
    expect(result.label, 'STALLED');
    // A failed probe is detached immediately, never retained.
    expect(engine.removed, contains('f' * 40));
  });

  test('resolved metadata with no peers and no bytes is no peers', () async {
    final engine = _FakeEngine(
      streamMode: _StreamMode.empty,
      fileStats: const {'peers': 0, 'swarmConnections': 0},
    );
    final result = await withEngine(engine, () => _probe(_torrent('g')));

    expect(result.metadataResolved, isTrue);
    expect(result.status, LocalTorrentProbeStatus.noPeers);
    expect(result.label, 'NO PEERS');
  });

  test('a live probe is retained and hands off to playback resolve', () async {
    final engine = _FakeEngine();
    final source = _torrent('h');
    await withEngine(engine, () async {
      final result = await _probe(source);
      expect(result.confirmedLive, isTrue);
      expect(result.sampleWindowsPassed, 2);
      expect(engine.removed, isNot(contains('h' * 40)),
          reason: 'live probe stays warm');

      await service.prepareRetainedProbeForPlayback(source);
      final url = await service.resolve(source);
      expect(url, contains('h' * 40));
      expect(engine.removed, isNot(contains('h' * 40)),
          reason: 'handoff keeps the warm torrent attached');
    });
  });

  test('cleanup detaches unused retained probe sessions', () async {
    final engine = _FakeEngine();
    final a = _torrent('1');
    final b = _torrent('2');
    await withEngine(engine, () async {
      expect((await _probe(a)).confirmedLive, isTrue);
      expect((await _probe(b)).confirmedLive, isTrue);
      expect(engine.removed, isEmpty);

      // Choosing A detaches B; A stays for the handoff window.
      await service.prepareRetainedProbeForPlayback(a);
      expect(engine.removed, ['2' * 40]);

      // Leaving the picker without playing detaches A too.
      await service.releaseRetainedProbeSessions();
      expect(engine.removed, ['2' * 40, '1' * 40]);
    });
  });

  test('a late warm probe session can be detached on its own', () async {
    final engine = _FakeEngine();
    final kept = _torrent('5');
    final late = _torrent('6');
    await withEngine(engine, () async {
      expect((await _probe(kept)).confirmedLive, isTrue);
      expect((await _probe(late)).confirmedLive, isTrue);

      await service.releaseRetainedProbe(late);
      expect(engine.removed, ['6' * 40]);
      // Only once, and never a session that is not retained.
      await service.releaseRetainedProbe(late);
      await service.releaseRetainedProbe(_torrent('7'));
      expect(engine.removed, ['6' * 40]);

      await service.releaseRetainedProbeSessions();
      expect(engine.removed, ['6' * 40, '5' * 40]);
    });
  });

  test('playback metadata timeout message states what the engine saw', () {
    final noStats = LocalTorrentService.metadataTimeoutMessageFor(
      statsAvailable: false,
    );
    final empty = LocalTorrentService.metadataTimeoutMessageFor(
      statsAvailable: true,
      discoveredPeers: 0,
    );
    final peers = LocalTorrentService.metadataTimeoutMessageFor(
      statsAvailable: true,
      connectedPeers: 2,
      discoveredPeers: 14,
    );

    for (final message in [noStats, empty, peers]) {
      // Playback history classifies "timed out" failures as stalled.
      expect(message, contains('timed out while resolving magnet metadata'));
      expect(message, isNot(contains('magnet:?')));
    }
    expect(empty, contains('no peers were found'));
    expect(peers, contains('14 found'));
    expect(peers, contains('2 connected'));
    expect(noStats, contains('no swarm statistics'));
  });
}
