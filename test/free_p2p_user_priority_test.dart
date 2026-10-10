import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/tv_source_browser_screen.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

const _seedersFirst = <SourceSortCriterion>[
  SourceSortCriterion.seeders,
  SourceSortCriterion.resolution,
  SourceSortCriterion.fileSize,
  SourceSortCriterion.releaseQuality,
  SourceSortCriterion.cache,
];

const _resolutionFirst = <SourceSortCriterion>[
  SourceSortCriterion.resolution,
  SourceSortCriterion.seeders,
  SourceSortCriterion.fileSize,
  SourceSortCriterion.releaseQuality,
  SourceSortCriterion.cache,
];

SourceResult _torrent(
  String name, {
  String quality = '1080P',
  String releaseQuality = 'WEB-DL',
  int? seeders,
  int? peers,
  int sizeBytes = 1200 * _mb,
  bool cached = false,
  String provider = 'Torrentio',
}) {
  return SourceResult(
    provider: provider,
    title: name,
    resource:
        'magnet:?xt=urn:btih:${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(40, '0')}',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: quality,
    releaseQuality: releaseQuality,
    seeders: seeders,
    peers: peers,
    sizeBytes: sizeBytes,
    cached: cached,
    torrentFileIndex: 0,
  );
}

const _direct = SourceResult(
  provider: 'Direct',
  title: 'Direct.720p',
  resource: 'https://example.test/movie.mkv',
  isMagnet: false,
  sortMode: SourceSortMode.quality,
  quality: '720P',
);

/// Ready-now evidence; every live source in these tests shares it, so only
/// the user's Source Priority can separate them.
LocalTorrentProbeResult _live() => const LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: _mb,
      elapsed: Duration(seconds: 1),
      firstByteLatency: Duration(milliseconds: 400),
      peers: 12,
      connections: 8,
      downloadSpeedBytesPerSecond: 2.5 * _mb,
      sampleWindowsPassed: 2,
      metadataElapsed: Duration(milliseconds: 900),
    );

/// Ready-now evidence with a given first-byte latency.
LocalTorrentProbeResult _liveAfter(Duration firstByte) => LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: _mb,
      elapsed: const Duration(seconds: 1),
      firstByteLatency: firstByte,
      peers: 12,
      connections: 8,
      downloadSpeedBytesPerSecond: 2.5 * _mb,
      sampleWindowsPassed: 2,
      metadataElapsed: const Duration(milliseconds: 900),
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

/// Metadata resolved, peers connected, no media bytes.
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

/// Metadata resolved, nobody connected, no bytes.
const _noPeers = LocalTorrentProbeResult(
  playableNow: false,
  bytesReceived: 0,
  elapsed: Duration(milliseconds: 4800),
  firstByteLatency: null,
  peers: 0,
  connections: 0,
  downloadSpeedBytesPerSecond: 0,
  sampleWindowsPassed: 0,
);

/// Deterministic stand-in for the local torrent engine. It records every
/// probe, the warm sessions it would keep and how many probes overlap.
class _Engine implements FreeP2pProbeEngine {
  _Engine(this.outcomes, {this.hold = false, this.holdOnly = const {}});

  final Map<String, LocalTorrentProbeResult> outcomes;

  /// When true each probe waits until the test completes it.
  final bool hold;

  /// Probes of these titles wait until the test completes them.
  final Set<String> holdOnly;

  final probed = <String>[];
  final retainRequested = <String, bool>{};
  final retained = <String>{};
  final held = <String, Completer<void>>{};
  final _running = <String>{};
  var inFlight = 0;
  var maxInFlight = 0;
  var overlappingSameTorrent = false;

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) async {
    probed.add(source.title);
    retainRequested[source.title] = retainSession;
    if (!_running.add(source.title)) overlappingSameTorrent = true;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (hold || holdOnly.contains(source.title)) {
        await (held[source.title] = Completer<void>()).future;
      } else {
        // A microtask, not a timer, so widget tests need no clock advance.
        await Future<void>.value();
      }
      final result = outcomes[source.title] ?? _noPeers;
      if (retainSession && result.confirmedLive) retained.add(source.title);
      return result;
    } finally {
      inFlight--;
      _running.remove(source.title);
    }
  }

  void complete(Iterable<String> titles) {
    for (final title in titles) {
      final completer = held[title];
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  void completeAll() => complete(held.keys.toList());

  @override
  Future<void> releaseRetained(SourceResult source) async {
    retained.remove(source.title);
  }

  @override
  Future<void> prepareForPlayback(SourceResult source) async {
    retained.removeWhere((title) => title != source.title);
  }

  @override
  Future<void> releaseAll() async => retained.clear();
}

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<String> _titles(Iterable<SourceResult> sources) =>
    sources.map((source) => source.title).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Source Priority inside Free P2P health groups', () {
    test('Seeders first: higher reported seeders lead the live group',
        () async {
      final sources = SourceProviderService();
      final five = _torrent('Five.1080p', seeders: 5);
      final hundred = _torrent('Hundred.1080p', seeders: 100);
      final twenty = _torrent('Twenty.1080p', seeders: 20);
      final results = [five, hundred, twenty];
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({for (final s in results) s.title: _live()}),
      );

      await probe.probeTopCandidates(results, sources);

      expect(probe.summary(results).live, 3);
      expect(_titles(probe.rank(results, sources)),
          ['Hundred.1080p', 'Twenty.1080p', 'Five.1080p']);
    });

    test('Seeders first: higher reported seeders lead the unchecked group',
        () {
      final sources = SourceProviderService();
      final results = [
        _torrent('Five.2160p', quality: '2160P', seeders: 5, sizeBytes: 9 * _gb),
        _torrent('Hundred.720p', quality: '720P', seeders: 100),
        _torrent('Twenty.1080p', seeders: 20),
        _direct,
      ];
      final probe = FreeP2pLiveProbeService(priority: _seedersFirst);

      expect(_titles(probe.rank(results, sources)), [
        'Direct.720p',
        'Hundred.720p',
        'Twenty.1080p',
        'Five.2160p',
      ]);
    });

    test('live > unchecked > unresolved > failed, whatever the reported seeders',
        () async {
      final sources = SourceProviderService();
      final dead = _torrent('Dead.1080p', seeders: 900);
      final noPeers = _torrent('NoPeers.1080p', seeders: 800);
      final metadata = _torrent('Metadata.1080p', seeders: 700);
      final engineError = _torrent('Engine.1080p', seeders: 400);
      final unchecked = _torrent('Unchecked.1080p', seeders: 300);
      final live = _torrent('Live.1080p', seeders: 1);
      final results = [
        dead,
        noPeers,
        metadata,
        engineError,
        unchecked,
        live,
        _direct,
      ];
      final engine = _Engine({
        dead.title: _stalled,
        noPeers.title: _noPeers,
        metadata.title: _outcome(LocalTorrentProbeStatus.metadataTimeout),
        engineError.title:
            _outcome(LocalTorrentProbeStatus.engineUnavailable),
        live.title: _live(),
      });
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: engine,
      );
      // Probe everything except the unchecked row.
      await probe.probeTopCandidates(
        results.where((source) => source != unchecked),
        sources,
      );

      expect(_titles(probe.rank(results, sources)), [
        'Direct.720p',
        'Live.1080p',
        // An engine failure says nothing about the torrent: same group as
        // unchecked, ordered by the user's priority.
        'Engine.1080p',
        'Unchecked.1080p',
        'Metadata.1080p',
        // Failures: closest to working first.
        'Dead.1080p',
        'NoPeers.1080p',
      ]);
      expect(probe.healthFor(dead)!.label, 'STALLED');
      expect(probe.healthFor(noPeers)!.label, 'NO PEERS');
      expect(probe.healthFor(metadata)!.label, 'METADATA SLOW');
      expect(probe.healthFor(unchecked), isNull);
    });

    test('Resolution first orders a health group by resolution', () async {
      final sources = SourceProviderService();
      final hd = _torrent('Popular.720p', quality: '720P', seeders: 500);
      final uhd = _torrent('Quiet.2160p',
          quality: '2160P', seeders: 2, sizeBytes: 8 * _gb);
      final fhd = _torrent('Middle.1080p', seeders: 50);
      final results = [hd, uhd, fhd];
      final probe = FreeP2pLiveProbeService(
        priority: _resolutionFirst,
        // No runtime: the throughput need is unknown, so all three stay in
        // the same READY NOW band.
        engine: _Engine({for (final s in results) s.title: _live()}),
      );

      expect(_titles(probe.rank(results, sources)),
          ['Quiet.2160p', 'Middle.1080p', 'Popular.720p'],
          reason: 'unchecked group');

      await probe.probeTopCandidates(results, sources);
      expect(_titles(probe.rank(results, sources)),
          ['Quiet.2160p', 'Middle.1080p', 'Popular.720p'],
          reason: 'live group');

      probe.setPriority(_seedersFirst);
      expect(_titles(probe.rank(results, sources)),
          ['Popular.720p', 'Middle.1080p', 'Quiet.2160p']);
    });

    test('file size, release quality and cache priorities apply in a group',
        () {
      final sources = SourceProviderService();
      final small = _torrent('Small.WEB', sizeBytes: 1 * _gb);
      final large = _torrent('Large.REMUX',
          releaseQuality: 'REMUX', sizeBytes: 8 * _gb);
      final medium = _torrent('Medium.HDTV',
          releaseQuality: 'HDTV', sizeBytes: 3 * _gb, cached: true);
      final results = [small, large, medium];
      final probe = FreeP2pLiveProbeService();

      List<String> orderFor(SourceSortCriterion first) {
        probe.setPriority([
          first,
          ...SourceProviderService.defaultPriority.where((c) => c != first),
        ]);
        return _titles(probe.rank(results, sources));
      }

      expect(orderFor(SourceSortCriterion.fileSize),
          ['Large.REMUX', 'Medium.HDTV', 'Small.WEB']);
      expect(orderFor(SourceSortCriterion.releaseQuality),
          ['Large.REMUX', 'Small.WEB', 'Medium.HDTV']);
      expect(orderFor(SourceSortCriterion.cache).first, 'Medium.HDTV');
    });

    test('a priority change reorders at once, even a frozen order', () async {
      final sources = SourceProviderService();
      final uhd = _torrent('Few.2160p',
          quality: '2160P', seeders: 3, sizeBytes: 8 * _gb);
      final hd = _torrent('Many.720p', quality: '720P', seeders: 300);
      final results = [uhd, hd];
      final probe = FreeP2pLiveProbeService(
        priority: _resolutionFirst,
        engine: _Engine({for (final s in results) s.title: _live()}),
      );
      await probe.probeTopCandidates(results, sources);
      // The user picked a row: the order is kept for the reopened picker.
      probe.freezeRanking(results, sources);
      expect(_titles(probe.rank(results, sources)), ['Few.2160p', 'Many.720p']);

      expect(probe.setPriority(_resolutionFirst), isFalse);
      expect(probe.isFrozen, isTrue, reason: 'same priority, same list');

      expect(probe.setPriority(_seedersFirst), isTrue);
      expect(probe.isFrozen, isFalse);
      expect(_titles(probe.rank(results, sources)), ['Many.720p', 'Few.2160p']);
    });
  });

  group('Live check grouping', () {
    test('failed rows are grouped at the bottom when a live source exists',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 10; i++)
          _torrent('Row.$i.1080p', seeders: 1000 - i * 10),
      ];
      final live = results[4];
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        // Every probed row except one delivers nothing.
        engine: _Engine({live.title: _live()}),
      );

      await probe.probeTopCandidates(results, sources);
      final ordered = probe.rank(results, sources);
      final start = probe.failedGroupStart(ordered);

      expect(ordered.first, same(live));
      expect(probe.summary(results).failed, greaterThan(0));
      expect(probe.summary(results).notChecked, greaterThan(0),
          reason: 'a live source was found, so the check stayed bounded');
      expect(start, lessThan(ordered.length));
      for (var i = 0; i < ordered.length; i++) {
        expect(probe.failedLiveCheck(ordered[i]), i >= start,
            reason: 'failed rows are never mixed among usable or unchecked '
                'rows (${ordered[i].title})');
      }
      for (final source in ordered.skip(start)) {
        expect(probe.healthFor(source)!.label, 'NO PEERS');
      }
      // Unchecked rows sit between live and failed, by reported seeders.
      final unchecked = ordered
          .where((source) => probe.healthFor(source) == null)
          .toList();
      expect(unchecked, isNotEmpty);
      final seeds = unchecked.map((source) => source.seeders!).toList();
      expect(seeds, [...seeds]..sort((a, b) => b.compareTo(a)));
    });

    test('no live source never turns unchecked rows into failures', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 14; i++)
          _torrent('Quiet.$i.1080p', seeders: 100 - i),
      ];
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({
          for (final source in results.take(3))
            source.title: _outcome(LocalTorrentProbeStatus.metadataTimeout),
        }),
      );

      await probe.probeTopCandidates(results, sources);
      final summary = probe.summary(results);

      expect(probe.noLiveConfirmed, isTrue);
      expect(summary.notChecked, greaterThan(0));
      expect(summary.unresolved, 3);
      final ordered = probe.rank(results, sources);
      for (final source in ordered) {
        final health = probe.healthFor(source);
        if (health == null) {
          expect(probe.failedLiveCheck(source), isFalse,
              reason: 'an unchecked row is a possibility, not a failure');
        }
        if (health?.state == FreeP2pHealthState.metadataSlow) {
          expect(probe.failedLiveCheck(source), isFalse,
              reason: 'metadata timeout is not a dead swarm');
        }
      }
      // Failed rows still exist and stay marked, at the bottom.
      final start = probe.failedGroupStart(ordered);
      expect(summary.failed, ordered.length - start);
      expect(
        ordered.skip(start).every((s) => probe.healthFor(s)!.label == 'NO PEERS'),
        isTrue,
      );
    });

    test('Normal Play never auto-launches a failed torrent', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 6; i++) _torrent('Dead.$i.1080p', seeders: 900 - i),
      ];
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({}),
      );

      expect(await probe.probeBestCandidate(results, sources), isNull);
      expect(probe.summary(results).failed, results.length);
    });
  });

  group('Re-check', () {
    test('discards old evidence, keeps the priority and can change the order',
        () async {
      final sources = SourceProviderService();
      final first = _torrent('First.1080p', seeders: 100);
      final second = _torrent('Second.1080p', seeders: 10);
      final results = [first, second];
      final outcomes = <String, LocalTorrentProbeResult>{
        first.title: _live(),
        second.title: _stalled,
      };
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine(outcomes),
      );
      await probe.probeTopCandidates(results, sources);
      probe.freezeRanking(results, sources);
      expect(_titles(probe.rank(results, sources)),
          ['First.1080p', 'Second.1080p']);

      // The swarms changed since the first check.
      outcomes[first.title] = _stalled;
      outcomes[second.title] = _live();
      final run = probe.recheck(results, sources);
      expect(probe.resultFor(first), isNull, reason: 'old evidence is gone');
      expect(probe.isFrozen, isFalse, reason: 'no old frozen order');
      await run;

      expect(probe.priority, _seedersFirst);
      expect(_titles(probe.rank(results, sources)),
          ['Second.1080p', 'First.1080p']);
      expect(probe.healthFor(first)!.label, 'STALLED');
    });

    test('a Re-check during a running check discards its late results',
        () async {
      final sources = SourceProviderService();
      final first = _torrent('First.1080p', seeders: 100);
      final second = _torrent('Second.1080p', seeders: 10);
      final results = [first, second];
      final outcomes = <String, LocalTorrentProbeResult>{
        first.title: _live(),
        second.title: _stalled,
      };
      final engine = _Engine(outcomes, hold: true);
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: engine,
      );

      unawaited(probe.probeTopCandidates(results, sources));
      await _flush();
      expect(engine.probed, hasLength(2));

      final fresh = probe.recheck(results, sources);
      // The old probes finish after the Re-check, with the old evidence.
      engine.completeAll();
      await _flush();
      expect(probe.resultFor(first), isNull,
          reason: 'late results of a discarded check are dropped');
      expect(engine.retained, isEmpty,
          reason: 'its warm session is detached');

      // The fresh check probes again, never overlapping the old probes.
      outcomes[first.title] = _stalled;
      outcomes[second.title] = _live();
      expect(engine.probed, hasLength(4));
      engine.completeAll();
      await fresh;

      expect(engine.overlappingSameTorrent, isFalse);
      expect(_titles(probe.rank(results, sources)),
          ['Second.1080p', 'First.1080p']);
      expect(engine.retained, {second.title});
    });
  });

  group('Bounded picker background check', () {
    test('an open picker keeps checking in small batches and finds a deep '
        'live torrent', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 40; i++)
          _torrent('Deep.$i.1080p', seeders: 1000 - i),
      ];
      // Outside the 6 + 3 that Normal Play and the first stages check.
      final deep = results[15];
      final engine = _Engine({deep.title: _live()});
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: engine,
      );

      await probe.probeTopCandidates(
        results,
        sources,
        continueInBackground: true,
      );

      expect(probe.hasPlayableResult, isTrue);
      expect(probe.rank(results, sources).first, same(deep));
      expect(engine.probed.length, FreeP2pLiveProbeService.pickerProbeLimit);
      expect(engine.probed.toSet(), hasLength(engine.probed.length),
          reason: 'no torrent is probed twice');
      expect(engine.maxInFlight,
          lessThanOrEqualTo(FreeP2pLiveProbeService.probeConcurrency));
      expect(probe.activeProbeCount, 0);
      expect(probe.isRunning, isFalse);
      // First stages keep a warm session for a fast handoff; background
      // probes never do.
      final firstStages = FreeP2pLiveProbeService.initialShortlistSize +
          FreeP2pLiveProbeService.expansionBatchSize;
      for (final title in engine.probed.take(firstStages)) {
        expect(engine.retainRequested[title], isTrue);
      }
      for (final title in engine.probed.skip(firstStages)) {
        expect(engine.retainRequested[title], isFalse);
      }
      expect(engine.retained, isEmpty);
    });

    test('without an open picker the check stays at 6 + 3', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 40; i++)
          _torrent('Deep.$i.1080p', seeders: 1000 - i),
      ];
      final engine = _Engine({results[15].title: _live()});
      final probe = FreeP2pLiveProbeService(engine: engine);

      await probe.probeTopCandidates(results, sources);

      expect(engine.probed.length,
          FreeP2pLiveProbeService.initialShortlistSize +
              FreeP2pLiveProbeService.expansionBatchSize);
      expect(probe.hasPlayableResult, isFalse);
    });

    test('evidence from Normal Play counts towards the picker budget',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 40; i++)
          _torrent('Budget.$i.1080p', seeders: 1000 - i),
      ];
      final engine = _Engine({});
      final probe = FreeP2pLiveProbeService(engine: engine);

      expect(await probe.probeBestCandidate(results, sources), isNull);
      expect(engine.probed, hasLength(9));
      await probe.probeTopCandidates(
        results,
        sources,
        continueInBackground: true,
      );

      expect(engine.probed, hasLength(FreeP2pLiveProbeService.pickerProbeLimit));
      expect(engine.probed.toSet(), hasLength(engine.probed.length));
    });

    test('the Source Priority decides which unchecked rows are checked first',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('HD.$i.720p', quality: '720P', seeders: 900 - i),
        for (var i = 0; i < 12; i++)
          _torrent('UHD.$i.2160p',
              quality: '2160P', seeders: 10 + i, sizeBytes: 8 * _gb),
      ];

      Future<List<String>> firstBatch(List<SourceSortCriterion> priority) async {
        final engine = _Engine({});
        await FreeP2pLiveProbeService(priority: priority, engine: engine)
            .probeTopCandidates(results, sources);
        return engine.probed.take(3).toList();
      }

      expect(await firstBatch(_seedersFirst), ['HD.0.720p', 'HD.1.720p', 'HD.2.720p']);
      expect(await firstBatch(_resolutionFirst),
          ['UHD.11.2160p', 'UHD.10.2160p', 'UHD.9.2160p']);
    });

    test('closing the picker stops the check and leaks no warm session',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 20; i++)
          _torrent('Close.$i.1080p', seeders: 1000 - i),
      ];
      final engine = _Engine(
        {for (final source in results) source.title: _live()},
        hold: true,
      );
      final probe = FreeP2pLiveProbeService(engine: engine);

      final run = probe.probeTopCandidates(
        results,
        sources,
        continueInBackground: true,
      );
      await _flush();
      final firstBatch = engine.probed.toList();
      expect(firstBatch, hasLength(FreeP2pLiveProbeService.probeConcurrency));
      engine.complete(firstBatch);
      await _flush();
      expect(engine.retained, firstBatch.toSet());
      final inFlight = engine.probed.skip(firstBatch.length).toList();
      expect(inFlight, hasLength(FreeP2pLiveProbeService.probeConcurrency));

      // The user plays the first source: the picker closes.
      await probe.prepareForPlayback(results.first);
      expect(engine.retained, {results.first.title});

      // Probes still in flight finish live after the close.
      engine.complete(inFlight);
      await run;

      expect(engine.probed, hasLength(firstBatch.length + inFlight.length),
          reason: 'no batch starts after the picker closed');
      expect(engine.retained, {results.first.title},
          reason: 'late live probes do not keep warm sessions');
      expect(probe.activeProbeCount, 0);

      await probe.release();
      expect(engine.retained, isEmpty);
    });
  });

  group('Pinned sources under a user priority', () {
    test('a confirmed-live pin is still preferred', () async {
      final sources = SourceProviderService();
      final pin = _torrent('Pinned.720p', quality: '720P', seeders: 1);
      final popular = _torrent('Popular.1080p', seeders: 500);
      final results = [popular, pin];
      final engine = _Engine({pin.title: _live(), popular.title: _live()});
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: engine,
      );

      await probe.probeTopCandidates(results, sources);
      final ordered = probe.applyPinnedPreference(
        probe.rank(results, sources),
        (source) => identical(source, pin),
      );
      expect(ordered.first, same(pin));

      final normalPlay = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({pin.title: _live(), popular.title: _live()}),
      );
      expect(
        await normalPlay.probeBestCandidate(results, sources, preferred: pin),
        same(pin),
      );
    });

    test('a failed pin does not hold a healthy live source below it',
        () async {
      final sources = SourceProviderService();
      final pin = _torrent('Pinned.1080p', seeders: 900);
      final live = _torrent('Live.720p', quality: '720P', seeders: 2);
      final unchecked = _torrent('Other.1080p', seeders: 50);
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({pin.title: _stalled, live.title: _live()}),
      );
      await probe.probeTopCandidates([pin, live], sources);

      final ordered = probe.applyPinnedPreference(
        probe.rank([pin, live, unchecked], sources),
        (source) => identical(source, pin),
      );
      expect(_titles(ordered), ['Live.720p', 'Other.1080p', 'Pinned.1080p']);
      expect(probe.failedGroupStart(ordered), 2,
          reason: 'the pin stays selectable, in the failed group');
      expect(probe.healthFor(pin)!.label, 'STALLED');
    });
  });

  group('Display modes are display only', () {
    final fast = _torrent('Fast.720p', quality: '720P', seeders: 2);
    final seeded = _torrent('Seeded.1080p', seeders: 900);
    final unchecked = _torrent('Unchecked.1080p', seeders: 4000);
    final dead = _torrent('Dead.1080p', seeders: 9000);

    Future<FreeP2pLiveProbeService> checked(SourceProviderService sources) async {
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({
          fast.title: _liveAfter(const Duration(milliseconds: 300)),
          seeded.title: _liveAfter(const Duration(milliseconds: 1500)),
          dead.title: _stalled,
        }),
      );
      await probe.probeTopCandidates([fast, seeded, dead], sources);
      return probe;
    }

    test('every mode keeps live > not checked > failed; inside the live '
        'group Recommended measures, My Priority follows the user', () async {
      final sources = SourceProviderService();
      final probe = await checked(sources);
      final results = [dead, unchecked, seeded, fast];

      List<String> orderIn(SourceDisplayMode mode) {
        probe.setDisplayMode(mode);
        return _titles(probe.rank(results, sources));
      }

      expect(orderIn(SourceDisplayMode.recommended),
          ['Fast.720p', 'Seeded.1080p', 'Unchecked.1080p', 'Dead.1080p'],
          reason: 'faster first byte wins, reported seeders do not');
      expect(orderIn(SourceDisplayMode.myPriority),
          ['Seeded.1080p', 'Fast.720p', 'Unchecked.1080p', 'Dead.1080p'],
          reason: 'Seeders first inside the live group');
      final smooth = orderIn(SourceDisplayMode.smooth);
      expect(smooth.take(2).toSet(), {'Fast.720p', 'Seeded.1080p'});
      expect(smooth.skip(2), ['Unchecked.1080p', 'Dead.1080p']);
    });

    test('Smooth favors compatible 1080p inside the unchecked group',
        () async {
      final sources = SourceProviderService();
      final uhd = _torrent('Big.2160p.HDR.DV',
          quality: '2160P', seeders: 900, sizeBytes: 9 * _gb);
      final fhd = _torrent('Plain.1080p.x265', seeders: 10);
      final live = _torrent('Live.480p', quality: '480P', seeders: 1);
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({live.title: _live()}),
      );
      await probe.probeTopCandidates([live], sources);
      final results = [uhd, fhd, live];

      probe.setDisplayMode(SourceDisplayMode.smooth);
      expect(_titles(probe.rank(results, sources)),
          ['Live.480p', 'Plain.1080p.x265', 'Big.2160p.HDR.DV']);
      probe.setDisplayMode(SourceDisplayMode.myPriority);
      expect(_titles(probe.rank(results, sources)),
          ['Live.480p', 'Big.2160p.HDR.DV', 'Plain.1080p.x265']);
    });

    test('the display mode never changes which torrents are probed',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 24; i++)
          _torrent('Row.$i.${i.isEven ? '1080p' : '2160p'}',
              quality: i.isEven ? '1080P' : '2160P',
              seeders: 1000 - i * 7,
              provider: i % 3 == 0 ? 'Knaben' : 'Torrentio'),
      ];
      Future<List<String>> probedIn(SourceDisplayMode mode) async {
        final engine = _Engine({});
        final probe =
            FreeP2pLiveProbeService(priority: _seedersFirst, engine: engine)
              ..setDisplayMode(mode);
        await probe.probeTopCandidates(results, sources,
            continueInBackground: true);
        expect(engine.maxInFlight,
            lessThanOrEqualTo(FreeP2pLiveProbeService.probeConcurrency));
        return engine.probed;
      }

      final reference = await probedIn(SourceDisplayMode.recommended);
      expect(reference, hasLength(FreeP2pLiveProbeService.pickerProbeLimit));
      expect(await probedIn(SourceDisplayMode.myPriority), reference);
      expect(await probedIn(SourceDisplayMode.smooth), reference);
    });

    test('Quick Play and Normal Play each choose the same source in every '
        'mode and ignore a frozen order', () async {
      final sources = SourceProviderService();
      final results = [dead, unchecked, seeded, fast];
      final quickPlay = <SourceResult?>{};
      final normalPlay = <SourceResult?>{};
      for (final mode in SourceDisplayMode.values) {
        final probe = await checked(sources);
        probe.setDisplayMode(mode);
        probe.freezeRanking(results, sources);
        quickPlay.add(probe.quickPlayCandidate(results, sources));

        final session = FreeP2pLiveProbeService(
          priority: _seedersFirst,
          engine: _Engine({
            fast.title: _liveAfter(const Duration(milliseconds: 300)),
            seeded.title: _liveAfter(const Duration(milliseconds: 1500)),
            dead.title: _stalled,
          }),
        )..setDisplayMode(mode);
        normalPlay.add(await session.probeBestCandidate(results, sources));
      }
      // Among checked sources the faster first byte wins over the
      // Seeders-first priority: automatic choice follows measured evidence.
      expect(quickPlay, {fast},
          reason: 'one playback order (health, then measured evidence)');
      // Normal Play stops at the first READY NOW source of its first batch,
      // before the 2-seeder row is checked.
      expect(normalPlay, {seeded});
    });

    test('Quick Play never picks an unchecked or failed torrent', () async {
      final sources = SourceProviderService();
      final popularUnchecked = _torrent('Popular.1080p', seeders: 99999);
      final probe = FreeP2pLiveProbeService(
        engine: _Engine({
          dead.title: _stalled,
          'NoPeers.1080p': _noPeers,
          'Error.1080p': _outcome(LocalTorrentProbeStatus.createError),
          'Meta.1080p': _outcome(LocalTorrentProbeStatus.metadataTimeout),
          'Engine.1080p': _outcome(LocalTorrentProbeStatus.engineUnavailable),
        }),
      );
      final probed = [
        dead,
        _torrent('NoPeers.1080p', seeders: 50),
        _torrent('Error.1080p', seeders: 50),
        _torrent('Meta.1080p', seeders: 50),
        _torrent('Engine.1080p', seeders: 50),
      ];
      await probe.probeTopCandidates(probed, sources);
      final results = [popularUnchecked, ...probed];
      for (final mode in SourceDisplayMode.values) {
        probe.setDisplayMode(mode);
        expect(probe.quickPlayCandidate(results, sources), isNull,
            reason: '$mode: nothing is confirmed live');
      }
      // A direct HTTP source needs no live check.
      expect(probe.quickPlayCandidate([...results, _direct], sources),
          same(_direct));
    });

    test('a mode change drops a frozen order; the same mode keeps it',
        () async {
      final sources = SourceProviderService();
      final probe = await checked(sources);
      final results = [dead, unchecked, seeded, fast];
      probe.freezeRanking(results, sources);
      expect(probe.setDisplayMode(SourceDisplayMode.myPriority), isFalse);
      expect(probe.isFrozen, isTrue);
      expect(probe.setDisplayMode(SourceDisplayMode.recommended), isTrue);
      expect(probe.isFrozen, isFalse);
      expect(probe.rank(results, sources).first, same(fast));
    });
  });

  group('Health visibility', () {
    test('unchecked reads NOT CHECKED, engine and metadata problems are not '
        'failures, and groups get labels', () async {
      final sources = SourceProviderService();
      final live = _torrent('Live.1080p', seeders: 1);
      final engineError = _torrent('Engine.1080p', seeders: 70);
      final meta = _torrent('Meta.1080p', seeders: 60);
      final stalled = _torrent('Stalled.1080p', seeders: 50);
      final noPeers = _torrent('NoPeers.1080p', seeders: 40);
      final error = _torrent('Error.1080p', seeders: 30);
      final unchecked = _torrent('Unchecked.1080p', seeders: 10);
      final probe = FreeP2pLiveProbeService(
        engine: _Engine({
          live.title: _live(),
          engineError.title:
              _outcome(LocalTorrentProbeStatus.engineUnavailable),
          meta.title: _outcome(LocalTorrentProbeStatus.metadataTimeout),
          stalled.title: _stalled,
          noPeers.title: _noPeers,
          error.title: _outcome(LocalTorrentProbeStatus.createError),
        }),
      );
      await probe.probeTopCandidates(
          [live, engineError, meta, stalled, noPeers, error], sources);
      final results = [
        _direct, unchecked, error, noPeers, stalled, meta, engineError, live,
      ];

      String label(SourceResult s) => probe.displayHealthFor(s)!.label;
      expect(label(live), 'READY NOW');
      expect(label(unchecked), 'NOT CHECKED');
      expect(label(engineError), 'ENGINE ERROR');
      expect(label(meta), 'METADATA SLOW');
      expect(label(stalled), 'STALLED');
      expect(label(noPeers), 'NO PEERS');
      expect(label(error), 'SOURCE ERROR');
      expect(probe.displayHealthFor(_direct), isNull);
      expect(probe.healthFor(unchecked), isNull,
          reason: 'unchecked has no measured state');

      for (final s in [unchecked, engineError, meta]) {
        expect(probe.failedLiveCheck(s), isFalse, reason: s.title);
      }
      for (final s in [stalled, noPeers, error]) {
        expect(probe.failedLiveCheck(s), isTrue, reason: s.title);
      }

      final ordered = probe.rank(results, sources);
      expect(_titles(ordered), [
        'Direct.720p',
        'Live.1080p',
        'Engine.1080p',
        'Unchecked.1080p',
        'Meta.1080p',
        'Stalled.1080p',
        'NoPeers.1080p',
        'Error.1080p',
      ]);
      final headers = probe.groupHeaders(ordered);
      expect(
        {for (final e in headers.entries) e.key: e.value.label},
        {
          0: 'Direct links (1)',
          1: 'Confirmed live (1)',
          2: 'Not checked yet (2) • reported seeders only',
          4: 'Metadata slow (1) • may still start',
          5: 'Failed the live check (3) • still selectable',
        },
      );
      expect(probe.failedGroupStart(ordered), 5);
      final summary = probe.summary(results);
      expect(
          [summary.live, summary.unresolved, summary.failed, summary.notChecked],
          [1, 2, 3, 1]);
    });

    test('an unchecked list gets no group labels', () async {
      final probe = FreeP2pLiveProbeService(engine: _Engine({}));
      final results = [_torrent('A.1080p'), _torrent('B.1080p')];
      expect(probe.groupHeaders(results), isEmpty);
      expect(probe.displayHealthFor(results.first)!.state,
          FreeP2pHealthState.notChecked);
    });
  });

  group('Pins and result limits', () {
    test('an unchecked pin does not disable Quick Play when a live source '
        'exists, and a failed pin does not suppress it', () async {
      final sources = SourceProviderService();
      final pin = _torrent('Pinned.2160p', quality: '2160P', seeders: 999);
      final live = _torrent('Live.720p', quality: '720P', seeders: 1);
      final probe = FreeP2pLiveProbeService(
        engine: _Engine({live.title: _live()}),
      );
      await probe.probeTopCandidates([live], sources);
      bool isPin(SourceResult s) => identical(s, pin);

      // Unchecked pin: still shown first, but Quick Play takes the live one.
      final shown = probe.applyPinnedPreference(
          probe.rank([pin, live], sources), isPin);
      expect(shown.first, same(pin));
      expect(probe.quickPlayCandidate([pin, live], sources, isPinned: isPin),
          same(live));

      // Failed pin: drops into the failed group, Quick Play takes the live.
      final failedPin = FreeP2pLiveProbeService(
        engine: _Engine({live.title: _live(), pin.title: _stalled}),
      );
      await failedPin.probeTopCandidates([pin, live], sources);
      expect(
        failedPin.applyPinnedPreference(
            failedPin.rank([pin, live], sources), isPin),
        [live, pin],
      );
      expect(
          failedPin.quickPlayCandidate([pin, live], sources, isPinned: isPin),
          same(live));
    });

    test('a confirmed-live pin is Quick Play\'s choice', () async {
      final sources = SourceProviderService();
      final pin = _torrent('Pinned.720p', quality: '720P', seeders: 1);
      final popular = _torrent('Popular.1080p', seeders: 900);
      final probe = FreeP2pLiveProbeService(
        priority: _seedersFirst,
        engine: _Engine({pin.title: _live(), popular.title: _live()}),
      );
      await probe.probeTopCandidates([pin, popular], sources);
      expect(probe.quickPlayCandidate([pin, popular], sources),
          same(popular));
      expect(
          probe.quickPlayCandidate([pin, popular], sources,
              isPinned: (s) => identical(s, pin)),
          same(pin));
    });

    test('a result limit never hides every confirmed-live torrent', () async {
      final sources = SourceProviderService();
      final pin = _torrent('Pinned.2160p', quality: '2160P', seeders: 999);
      final live = _torrent('Live.720p', quality: '720P', seeders: 1);
      final other = _torrent('Other.1080p', seeders: 5);
      final probe = FreeP2pLiveProbeService(
        engine: _Engine({live.title: _live()}),
      );
      await probe.probeTopCandidates([live], sources);
      final shown = probe.applyPinnedPreference(
          probe.rank([pin, other, live, _direct], sources),
          (s) => identical(s, pin));
      expect(_titles(shown),
          ['Pinned.2160p', 'Direct.720p', 'Live.720p', 'Other.1080p']);
      // A limit of 2 is filled by the pin and the direct link.
      expect(_titles(probe.applyResultLimit(shown, 2)),
          ['Pinned.2160p', 'Direct.720p', 'Live.720p']);
      expect(_titles(probe.applyResultLimit(shown, 3)),
          ['Pinned.2160p', 'Direct.720p', 'Live.720p']);
      expect(probe.applyResultLimit(shown, 0), shown);
      // Without any live torrent the limit is applied as configured.
      final none = FreeP2pLiveProbeService(engine: _Engine({}));
      expect(none.applyResultLimit([pin, other, live], 1), [pin]);
    });

    test('the picker checks an unchecked pin in its first batch', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('Row.$i.1080p', seeders: 1000 - i),
      ];
      final pin = _torrent('Pinned.480p', quality: '480P', seeders: 0);
      final engine = _Engine({}, hold: true);
      final probe = FreeP2pLiveProbeService(engine: engine);
      final run = probe.probeTopCandidates([...results, pin], sources,
          preferred: pin);
      await _flush();
      expect(engine.probed.first, pin.title);
      expect(engine.probed, hasLength(FreeP2pLiveProbeService.probeConcurrency));
      var done = false;
      unawaited(run.whenComplete(() => done = true));
      while (!done) {
        engine.completeAll();
        await _flush();
      }
      expect(engine.probed.where((t) => t == pin.title), hasLength(1));
      expect(engine.probed,
          hasLength(FreeP2pLiveProbeService.initialShortlistSize +
              FreeP2pLiveProbeService.expansionBatchSize),
          reason: 'the pin takes one of the bounded slots');
    });
  });

  group('Saved display mode', () {
    test('defaults: Recommended, My Priority after a custom priority or with '
        'a cloud path; a saved choice wins', () async {
      final sources = SourceProviderService();
      expect(await sources.getDisplayMode(liveCheck: true),
          SourceDisplayMode.recommended);
      expect(await sources.getDisplayMode(liveCheck: false),
          SourceDisplayMode.myPriority);

      await sources.setPriorityOrder(_seedersFirst);
      expect(await sources.getDisplayMode(liveCheck: true),
          SourceDisplayMode.myPriority,
          reason: 'a customized priority is not silently ignored');

      await sources.setDisplayMode(SourceDisplayMode.smooth);
      expect(await sources.getDisplayMode(liveCheck: true),
          SourceDisplayMode.smooth);
      expect(await sources.getDisplayMode(liveCheck: false),
          SourceDisplayMode.smooth);
      expect(await sources.getPriorityOrder(), _seedersFirst,
          reason: 'choosing a mode never resets the saved priority');
    });
  });

  group('Android TV source browser', () {
    const movie = MediaItem(
      id: 'tt0000001',
      kind: MediaKind.movie,
      title: 'Trigger',
      year: '2025',
    );

    setUp(() => PlatformProfile.debugAndroidTvOverride = true);
    tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

    void setTvSize(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    List<String> rowOrder(WidgetTester tester, SourceProviderService sources,
        List<SourceResult> results) {
      final byKey = {
        for (final source in results)
          'tv-source-${sources.sourceIdentity(source, seriesWide: false)}':
              source.title,
      };
      return tester
          .widgetList(find.byWidgetPredicate((widget) =>
              widget.key is ValueKey<String> &&
              byKey.containsKey((widget.key! as ValueKey<String>).value)))
          .map((widget) => byKey[(widget.key! as ValueKey<String>).value]!)
          .toList();
    }

    final uhd = _torrent('Trigger.2025.2160p',
        quality: '2160P', seeders: 5, sizeBytes: 8 * _gb);
    final fhd = _torrent('Trigger.2025.1080p', seeders: 100);
    final hd = _torrent('Trigger.2025.720p', quality: '720P', seeders: 20);

    testWidgets('a saved Order reorders Free P2P rows at once',
        (tester) async {
      setTvSize(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'orvix_source_priority_v6':
            _seedersFirst.map((criterion) => criterion.name).toList(),
      });
      final sources = SourceProviderService();
      final results = [uhd, fhd, hd];
      // Probes stay in flight: every row is in the unchecked group.
      final engine = _Engine({}, hold: true);
      final session = FreeP2pLiveProbeService(engine: engine);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value(results),
          probeSession: session,
        ),
      ));
      await settle(tester);
      expect(rowOrder(tester, sources, results),
          [fhd.title, hd.title, uhd.title]);

      await tester.tap(find.text('Order'));
      await settle(tester);
      await tester.tap(find.text('Reset'));
      await settle(tester);

      // Default priority: release quality ties, then resolution.
      expect(rowOrder(tester, sources, results),
          [uhd.title, fhd.title, hd.title]);
      expect(session.priority, SourceProviderService.defaultPriority);

      engine.completeAll();
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('display modes reorder inside health groups, keep the live '
        'check and leave D-pad focus usable', (tester) async {
      setTvSize(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'orvix_source_priority_v6':
            _seedersFirst.map((criterion) => criterion.name).toList(),
      });
      final sources = SourceProviderService();
      final fast = _torrent('Trigger.2025.720p.Fast',
          quality: '720P', seeders: 2);
      final seeded = _torrent('Trigger.2025.1080p.Seeded', seeders: 900);
      final unchecked = _torrent('Trigger.2025.1080p.Unchecked', seeders: 5);
      final stalled = _torrent('Trigger.2025.1080p.Stalled', seeders: 9000);
      final results = [stalled, unchecked, seeded, fast];
      final engine = _Engine({
        fast.title: _liveAfter(const Duration(milliseconds: 300)),
        seeded.title: _liveAfter(const Duration(milliseconds: 1500)),
        stalled.title: _stalled,
      }, holdOnly: {unchecked.title});
      final session = FreeP2pLiveProbeService(engine: engine);
      await session.probeTopCandidates([fast, seeded, stalled], sources);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value(results),
          probeSession: session,
        ),
      ));
      await settle(tester);
      // Customized priority: My Priority is the default mode.
      expect(rowOrder(tester, sources, results),
          [seeded.title, fast.title, unchecked.title, stalled.title]);
      expect(find.text('Confirmed live (2)'), findsOneWidget);
      // The open browser continues the check: the remaining row is checking.
      expect(find.text('CHECKING'), findsOneWidget);
      final probedBefore = engine.probed.length;

      Future<void> chooseWithOk(String label) async {
        Focus.of(tester.element(find.text(label))).requestFocus();
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester);
      }

      await chooseWithOk('Recommended');
      expect(rowOrder(tester, sources, results),
          [fast.title, seeded.title, unchecked.title, stalled.title]);
      expect(Focus.of(tester.element(find.text('Recommended'))).hasFocus,
          isTrue, reason: 'OK keeps focus on the chosen mode');

      await chooseWithOk('Smooth');
      final smooth = rowOrder(tester, sources, results);
      expect(smooth.take(2).toSet(), {fast.title, seeded.title});
      expect(smooth.skip(2), [unchecked.title, stalled.title]);
      expect(find.text('Failed the live check (1) • still selectable'),
          findsOneWidget);

      // D-pad Down leaves the chips and lands on a source row.
      Finder rows() => find.byWidgetPredicate((widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('tv-source-'));
      bool focusInRow() {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) return false;
        final targets = rows().evaluate().toSet();
        var found = targets.contains(focused);
        focused.visitAncestorElements((ancestor) {
          if (targets.contains(ancestor)) found = true;
          return !found;
        });
        return found;
      }

      for (var i = 0; i < 4 && !focusInRow(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await settle(tester);
      }
      expect(focusInRow(), isTrue);
      expect(engine.probed.length, probedBefore,
          reason: 'mode changes neither restart nor extend the live check');
      expect(await sources.getDisplayMode(liveCheck: true),
          SourceDisplayMode.smooth);
      engine.completeAll();
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('cloud/debrid keeps the user Order and never probes',
        (tester) async {
      setTvSize(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'orvix_source_priority_v6':
            _seedersFirst.map((criterion) => criterion.name).toList(),
      });
      final sources = SourceProviderService();
      final results = [uhd, fhd, hd];
      final engine = _Engine({});
      final session = FreeP2pLiveProbeService(engine: engine);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value(results),
          preferFreeP2p: false,
          probeSession: session,
        ),
      ));
      await settle(tester);
      expect(rowOrder(tester, sources, results),
          [fhd.title, hd.title, uhd.title]);

      // No display mode probes torrents that playback would send to the
      // cloud service.
      for (final mode in ['Recommended', 'Smooth', 'My Priority']) {
        await tester.tap(find.text(mode));
        await settle(tester);
        expect(engine.probed, isEmpty, reason: mode);
      }
      expect(rowOrder(tester, sources, results),
          [fhd.title, hd.title, uhd.title]);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('failed rows sit under one label at the bottom',
        (tester) async {
      setTvSize(tester);
      final sources = SourceProviderService();
      final results = [uhd, fhd, hd];
      final session = FreeP2pLiveProbeService(
        engine: _Engine({hd.title: _live(), uhd.title: _stalled,
            fhd.title: _outcome(LocalTorrentProbeStatus.metadataTimeout)}),
      );
      await session.probeTopCandidates(results, sources);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value(results),
          probeSession: session,
        ),
      ));
      await settle(tester);

      expect(rowOrder(tester, sources, results),
          [hd.title, fhd.title, uhd.title]);
      final label = find.text('Failed the live check (1) • still selectable');
      expect(label, findsOneWidget);
      expect(tester.getTopLeft(label).dy,
          greaterThan(tester.getTopLeft(find.text(fhd.title)).dy));
      expect(tester.getTopLeft(label).dy,
          lessThan(tester.getTopLeft(find.text(uhd.title)).dy));
      expect(find.text('STALLED'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
