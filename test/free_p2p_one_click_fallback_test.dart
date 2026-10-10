import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/free_p2p_auto_play.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/free_p2p_playback_trace.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1024 * 1024;

SourceResult _torrent(
  String name, {
  String? hash,
  int? fileIndex = 0,
  int seeders = 10,
  String quality = '1080P',
  String provider = 'Torrentio',
  int sizeBytes = 1200 * _mb,
}) {
  final infoHash = hash ??
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(40, '0');
  return SourceResult(
    provider: provider,
    title: name,
    resource: 'magnet:?xt=urn:btih:$infoHash',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: quality,
    releaseQuality: 'WEB-DL',
    seeders: seeders,
    sizeBytes: sizeBytes,
    torrentFileIndex: fileIndex,
  );
}

SourceResult _direct(String name) => SourceResult(
      provider: 'Direct',
      title: name,
      resource: 'https://cdn.example.test/$name.mkv',
      isMagnet: false,
      sortMode: SourceSortMode.quality,
      quality: '1080P',
    );

LocalTorrentProbeResult _readyNow({int firstByteMs = 400, int peers = 12}) =>
    LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: _mb,
      elapsed: const Duration(seconds: 1),
      firstByteLatency: Duration(milliseconds: firstByteMs),
      peers: peers,
      connections: 8,
      downloadSpeedBytesPerSecond: 2.5 * _mb,
      sampleWindowsPassed: 2,
      metadataElapsed: const Duration(milliseconds: 900),
    );

/// Live but below the speed a ready-now source needs.
const _slow = LocalTorrentProbeResult(
  playableNow: true,
  bytesReceived: _mb,
  elapsed: Duration(seconds: 4),
  firstByteLatency: Duration(milliseconds: 2600),
  peers: 2,
  connections: 1,
  downloadSpeedBytesPerSecond: 200 * 1024,
  sampleWindowsPassed: 2,
  metadataElapsed: Duration(milliseconds: 3000),
);

const _stalled = LocalTorrentProbeResult(
  playableNow: false,
  bytesReceived: 0,
  elapsed: Duration(milliseconds: 4800),
  firstByteLatency: null,
  peers: 7,
  connections: 4,
  downloadSpeedBytesPerSecond: 0,
  sampleWindowsPassed: 0,
);

LocalTorrentProbeResult _outcome(LocalTorrentProbeStatus status) =>
    LocalTorrentProbeResult(
      playableNow: false,
      bytesReceived: 0,
      elapsed: Duration.zero,
      firstByteLatency: null,
      peers: 0,
      connections: 0,
      downloadSpeedBytesPerSecond: 0,
      sampleWindowsPassed: 0,
      outcome: status,
    );

/// Deterministic torrent engine for the probe service.
class _Engine implements FreeP2pProbeEngine {
  _Engine(this.outcomes);

  final Map<String, LocalTorrentProbeResult> outcomes;
  final probed = <String>[];
  final handedOff = <String>[];
  final released = <String>[];

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) async {
    probed.add(source.title);
    await Future<void>.value();
    return outcomes[source.title] ?? _stalled;
  }

  @override
  Future<void> releaseRetained(SourceResult source) async =>
      released.add(source.title);

  @override
  Future<void> prepareForPlayback(SourceResult source) async =>
      handedOff.add(source.title);

  @override
  Future<void> releaseAll() async {}
}

/// Records each attempt and answers with the scripted end for its title.
class _Player {
  _Player(this.ends);

  /// Scripted end per title; any other source fails to start.
  final Map<String, FreeP2pAttemptEnd> ends;
  final played = <String>[];
  final fallbackOffered = <bool>[];

  Future<FreeP2pAttemptEnd> call(
    SourceResult source, {
    required bool fallbackAvailable,
  }) async {
    played.add(source.title);
    fallbackOffered.add(fallbackAvailable);
    return ends[source.title] ?? FreeP2pAttemptEnd.sourceFailed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SourceProviderService sources;
  late FreeP2pPlaybackTrace trace;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sources = SourceProviderService();
    trace = FreeP2pPlaybackTrace();
  });

  ({FreeP2pAutoPlay auto, FreeP2pLiveProbeService probe, _Engine engine}) build(
    Map<String, LocalTorrentProbeResult> outcomes, {
    List<SourceSortCriterion>? priority,
    DateTime Function()? clock,
  }) {
    final engine = _Engine(outcomes);
    final probe = FreeP2pLiveProbeService(
      engine: engine,
      priority: priority,
      playbackTrace: trace,
    );
    final auto = FreeP2pAutoPlay(
      probe: probe,
      sources: sources,
      trace: trace,
      clock: clock,
    );
    return (auto: auto, probe: probe, engine: engine);
  }

  group('first choice', () {
    test('plays the best confirmed-live source with one press', () async {
      final best = _torrent('Trigger.S01E01.1080p', seeders: 40);
      final other = _torrent('Trigger.S01E01.720p', quality: '720P');
      final setup = build({best.title: _readyNow(), other.title: _readyNow()});
      final player = _Player({best.title: FreeP2pAttemptEnd.started});

      final result = await setup.auto.run([other, best], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.started);
      expect(result.started, same(best));
      expect(player.played, [best.title]);
      expect(setup.engine.handedOff, [best.title]);
      final attempt = trace.attempts.single;
      expect(attempt.selection, 'oneClick');
      expect(attempt.choice?['health'], 'readyNow');
      expect(attempt.choice?['confirmedLive'], 2);
      expect(trace.runs.single.result, 'started');
    });

    test('a misleading 500-seeder torrent that fails the check never wins',
        () async {
      final hyped = _torrent('Trigger.2160p.Hyped', seeders: 500);
      final modest = _torrent('Trigger.1080p.Modest', seeders: 12);
      final setup = build(
        {hyped.title: _stalled, modest.title: _readyNow()},
        priority: const [
          SourceSortCriterion.seeders,
          SourceSortCriterion.resolution,
          SourceSortCriterion.fileSize,
          SourceSortCriterion.releaseQuality,
          SourceSortCriterion.cache,
        ],
      );
      final player = _Player({modest.title: FreeP2pAttemptEnd.started});

      final result =
          await setup.auto.run([hyped, modest], attempt: player.call);

      expect(result.started, same(modest));
      expect(player.played, isNot(contains(hyped.title)));
    });

    test(
        'measured ready-now beats a live-but-slow 500-seeder torrent even '
        'with a seeders-first priority', () async {
      final hyped = _torrent('Trigger.1080p.Hyped', seeders: 500);
      final healthy = _torrent('Trigger.1080p.Healthy', seeders: 20);
      final setup = build(
        {hyped.title: _slow, healthy.title: _readyNow()},
        priority: const [
          SourceSortCriterion.seeders,
          SourceSortCriterion.resolution,
          SourceSortCriterion.fileSize,
          SourceSortCriterion.releaseQuality,
          SourceSortCriterion.cache,
        ],
      );
      final player = _Player({healthy.title: FreeP2pAttemptEnd.started});

      final result =
          await setup.auto.run([hyped, healthy], attempt: player.call);

      expect(result.started, same(healthy));
      expect(player.played, [healthy.title]);
    });

    test('nothing verified: no attempt, an honest no-verified-source stop',
        () async {
      final dead = _torrent('Trigger.Dead', seeders: 900);
      final stalled = _torrent('Trigger.Stalled', seeders: 300);
      final setup = build({
        dead.title: _outcome(LocalTorrentProbeStatus.noPeers),
        stalled.title: _stalled,
      });
      final player = _Player(const {});

      final result =
          await setup.auto.run([dead, stalled], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.noVerifiedSource);
      expect(player.played, isEmpty,
          reason: 'never auto-launch unchecked or confirmed-dead torrents');
      expect(trace.runs.single.result, 'noVerifiedSource');
    });

    test('an engine that never started is reported as an engine failure',
        () async {
      final a = _torrent('Trigger.A');
      final b = _torrent('Trigger.B');
      final setup = build({
        a.title: _outcome(LocalTorrentProbeStatus.engineUnavailable),
        b.title: _outcome(LocalTorrentProbeStatus.engineUnavailable),
      });
      final player = _Player(const {});

      final result = await setup.auto.run([a, b], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.engineFailure);
      expect(player.played, isEmpty);
    });

    test('a direct HTTP source keeps its route and needs no torrent check',
        () async {
      final direct = _direct('Trigger.Direct');
      final torrent = _torrent('Trigger.Torrent');
      final setup = build({torrent.title: _readyNow()});
      final player = _Player({direct.title: FreeP2pAttemptEnd.started});

      final result =
          await setup.auto.run([torrent, direct], attempt: player.call);

      expect(result.started, same(direct));
      expect(setup.engine.probed, isEmpty);
    });
  });

  group('source-to-source fallback', () {
    test('a source that does not start falls back to the next verified one',
        () async {
      final first = _torrent('Trigger.First', seeders: 90);
      final second = _torrent('Trigger.Second', seeders: 50);
      final dead = _torrent('Trigger.Dead', seeders: 999);
      final setup = build({
        first.title: _readyNow(),
        second.title: _readyNow(firstByteMs: 900),
        dead.title: _outcome(LocalTorrentProbeStatus.noPeers),
      });
      final player = _Player({
        first.title: FreeP2pAttemptEnd.sourceFailed,
        second.title: FreeP2pAttemptEnd.started,
      });

      final result =
          await setup.auto.run([dead, first, second], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.started);
      expect(result.started, same(second));
      expect(player.played, [first.title, second.title]);
      expect(player.fallbackOffered.first, isTrue,
          reason: 'a verified next source existed during the first attempt');
      expect(setup.probe.isStartFailed(first), isTrue);
      expect(setup.probe.healthFor(first)?.label, 'START FAILED');
      expect(setup.probe.quickPlayAllowed(first), isFalse);
      // The trace names both attempts and the fallback.
      final run = trace.runs.single;
      expect(run.result, 'started');
      expect(
        run.steps.map((s) => s['step']),
        containsAllInOrder(
            ['liveCheck', 'firstAttempt', 'attemptEnded', 'fallbackAttempt']),
      );
      expect(trace.attempts.map((a) => a.selection), ['fallback', 'oneClick']);
    });

    test(
        'a player startup failure falls back too; the player is told only '
        'when a verified next source exists', () async {
      final only = _torrent('Trigger.Only');
      final setup = build({only.title: _readyNow()});
      final player = _Player({only.title: FreeP2pAttemptEnd.playerFailed});

      final result = await setup.auto.run([only], attempt: player.call);

      expect(player.fallbackOffered, [false],
          reason: 'with nothing to fall back to, the player keeps trying');
      expect(result.stop, FreeP2pAutoPlayStop.exhausted);
    });

    test('failed candidates are never retried and attempts are bounded',
        () async {
      final results = [
        for (var i = 0; i < 8; i++)
          _torrent('Trigger.Live.$i', seeders: 100 - i),
      ];
      final setup = build({for (final s in results) s.title: _readyNow()});
      final player = _Player(const {}); // every attempt fails

      final result = await setup.auto.run(results, attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.exhausted);
      expect(player.played, hasLength(FreeP2pAutoPlay.defaultMaxAttempts));
      expect(player.played.toSet(), hasLength(player.played.length),
          reason: 'no source is attempted twice');
      expect(trace.runs.single.toDiagnostics()['detail'], 'attemptLimit');
    });

    test('no new fallback starts after the time budget', () async {
      var now = DateTime(2026, 10, 10, 20);
      final first = _torrent('Trigger.First');
      final second = _torrent('Trigger.Second');
      final setup = build(
        {first.title: _readyNow(), second.title: _readyNow()},
        clock: () => now,
      );

      final result = await setup.auto.run(
        [first, second],
        attempt: (source, {required fallbackAvailable}) async {
          now = now.add(const Duration(minutes: 3));
          return FreeP2pAttemptEnd.sourceFailed;
        },
      );

      expect(result.stop, FreeP2pAutoPlayStop.exhausted);
      expect(result.tried, 1);
      expect(trace.runs.single.toDiagnostics()['detail'], 'timeBudget');
    });

    test('started playback is final: later buffering never switches source',
        () async {
      final first = _torrent('Trigger.First');
      final second = _torrent('Trigger.Second');
      final setup =
          build({first.title: _readyNow(), second.title: _readyNow()});
      final player = _Player({first.title: FreeP2pAttemptEnd.started});

      await setup.auto.run([first, second], attempt: player.call);

      expect(player.played, [first.title]);
    });

    test('the user backing out stops the run without a fallback', () async {
      final first = _torrent('Trigger.First');
      final second = _torrent('Trigger.Second');
      final setup =
          build({first.title: _readyNow(), second.title: _readyNow()});
      final player = _Player({first.title: FreeP2pAttemptEnd.stoppedByUser});

      final result =
          await setup.auto.run([first, second], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.stoppedByUser);
      expect(player.played, [first.title]);
    });

    test('an engine failure stops instead of trying more torrents', () async {
      final first = _torrent('Trigger.First');
      final second = _torrent('Trigger.Second');
      final setup =
          build({first.title: _readyNow(), second.title: _readyNow()});
      final player = _Player({first.title: FreeP2pAttemptEnd.engineFailure});

      final result =
          await setup.auto.run([first, second], attempt: player.call);

      expect(result.stop, FreeP2pAutoPlayStop.engineFailure);
      expect(player.played, [first.title]);
    });

    test('with no verified source left, one more bounded check runs', () async {
      // The first check (6 + 3) confirms only the first torrent; the rest
      // stay unchecked until a fallback needs them.
      final results = [
        _torrent('Trigger.Top', seeders: 1000),
        for (var i = 0; i < 9; i++)
          _torrent('Trigger.Dead.$i', seeders: 900 - i),
        _torrent('Trigger.Deep', seeders: 1),
      ];
      final top = results.first;
      final deep = results.last;
      final setup = build({top.title: _readyNow(), deep.title: _readyNow()});
      final player = _Player({
        top.title: FreeP2pAttemptEnd.sourceFailed,
        deep.title: FreeP2pAttemptEnd.started,
      });

      final result = await setup.auto.run(results, attempt: player.call);

      expect(result.started, same(deep));
      expect(setup.engine.probed.toSet(), hasLength(results.length));
      expect(setup.engine.probed.length,
          lessThanOrEqualTo(FreeP2pLiveProbeService.pickerProbeLimit));
      expect(
        trace.runs.single.steps.where((s) => s['step'] == 'liveCheck'),
        hasLength(2),
      );
    });
  });

  group('torrent and file identity', () {
    test('a torrent that failed is not retried through a sibling provider row',
        () async {
      final hash = 'a' * 40;
      final torrentio =
          _torrent('Trigger.E01.Torrentio', hash: hash, seeders: 90);
      final sibling = _torrent(
        'Trigger.E01.MediaFusion',
        hash: hash,
        provider: 'MediaFusion',
        seeders: 80,
      );
      final other = _torrent('Trigger.E01.Other', seeders: 10);
      final setup = build({
        torrentio.title: _readyNow(),
        sibling.title: _readyNow(),
        other.title: _readyNow(),
      });
      final player = _Player({
        torrentio.title: FreeP2pAttemptEnd.sourceFailed,
        other.title: FreeP2pAttemptEnd.started,
      });

      final result = await setup.auto
          .run([torrentio, sibling, other], attempt: player.call);

      expect(player.played, [torrentio.title, other.title]);
      expect(result.started, same(other));
      expect(setup.probe.isStartFailed(sibling), isTrue);
    });

    test('a torrent-level failure excludes every file of that torrent',
        () async {
      final hash = 'd' * 40;
      final e01 = _torrent('Pack.E01', hash: hash, fileIndex: 0, seeders: 90);
      final e02 = _torrent('Pack.E02', hash: hash, fileIndex: 1, seeders: 80);
      final other = _torrent('Other.E01', seeders: 5);
      final setup = build({
        e01.title: _readyNow(),
        e02.title: _readyNow(),
        other.title: _readyNow(),
      });
      // Metadata never arrived: the torrent, not the file, failed.
      final player = _Player({
        e01.title: FreeP2pAttemptEnd.sourceFailed,
        other.title: FreeP2pAttemptEnd.started,
      });

      final result =
          await setup.auto.run([e01, e02, other], attempt: player.call);

      expect(player.played, [e01.title, other.title]);
      expect(result.started, same(other));
      expect(setup.probe.isStartFailed(e02), isTrue);
    });

    test(
        'a player failure excludes rows that may route to the same file, '
        'not a different file of a season pack', () async {
      final hash = 'b' * 40;
      final e01 = _torrent('Pack.E01', hash: hash, fileIndex: 0, seeders: 90);
      final guessed =
          _torrent('Pack.Auto', hash: hash, fileIndex: null, seeders: 80);
      final e02 = _torrent('Pack.E02', hash: hash, fileIndex: 1, seeders: 70);
      final setup = build({
        e01.title: _readyNow(),
        guessed.title: _readyNow(),
        e02.title: _readyNow(),
      });

      setup.probe.markStartFailed(e01, wholeTorrent: false);

      expect(setup.probe.isStartFailed(e01), isTrue);
      expect(setup.probe.isStartFailed(guessed), isTrue,
          reason: 'the engine would guess a file; it may be the same one');
      expect(setup.probe.isStartFailed(e02), isFalse);
      expect(setup.probe.sameStartTarget(e01, guessed), isTrue);
      expect(setup.probe.sameStartTarget(e01, e02), isFalse);
    });
  });

  group('display modes never change one-click safety', () {
    for (final mode in SourceDisplayMode.values) {
      test('${mode.name}: same verified choice, same fallback', () async {
        final unchecked = _torrent('Trigger.Unchecked', seeders: 999);
        final dead = _torrent('Trigger.Dead', seeders: 800);
        final first = _torrent('Trigger.First', seeders: 50);
        final second = _torrent('Trigger.Second', seeders: 40);
        final setup = build({
          dead.title: _outcome(LocalTorrentProbeStatus.noPeers),
          first.title: _readyNow(),
          second.title: _readyNow(firstByteMs: 1000),
        });
        setup.probe.setDisplayMode(mode);
        // Classify everything but the unchecked row first.
        await setup.probe.probeTopCandidates([dead, first, second], sources);
        final player = _Player({
          first.title: FreeP2pAttemptEnd.sourceFailed,
          second.title: FreeP2pAttemptEnd.started,
        });

        final result = await setup.auto.run(
          [unchecked, dead, first, second],
          attempt: player.call,
        );

        expect(player.played.take(2), [first.title, second.title]);
        expect(player.played, isNot(contains(unchecked.title)));
        expect(player.played, isNot(contains(dead.title)));
        expect(result.started, same(second));
      });
    }
  });

  test('the one-click report is bounded and redacted', () async {
    final hash = 'c0ffee12' * 5;
    final first = _torrent('Trigger.First', hash: hash);
    final setup = build({first.title: _readyNow()});
    await setup.auto.run(
      [first],
      attempt: (source, {required fallbackAvailable}) async =>
          FreeP2pAttemptEnd.sourceFailed,
    );
    final report = trace.report();
    expect(report, contains('one-click play (newest first):'));
    expect(report, contains('"result":"exhausted"'));
    expect(report, isNot(contains('c0ffee12')));
    expect(report, isNot(contains('magnet:')));
    expect(report, isNot(contains('Trigger.First')));
    for (final line in report.split('\n').where((l) => l.startsWith('{'))) {
      expect(() => jsonDecode(line), returnsNormally);
    }
  });
}
