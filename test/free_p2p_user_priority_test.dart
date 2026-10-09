import 'dart:async';

import 'package:flutter/material.dart';
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
  _Engine(this.outcomes, {this.hold = false});

  final Map<String, LocalTorrentProbeResult> outcomes;

  /// When true each probe waits until the test completes it.
  final bool hold;

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
      if (hold) {
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

      // Choosing the Free P2P order by hand still does not probe torrents
      // that playback would send to the cloud service.
      await tester.tap(find.text('Free P2P'));
      await settle(tester);
      expect(engine.probed, isEmpty);
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
