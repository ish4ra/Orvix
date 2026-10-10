import 'dart:async';
import 'dart:io';

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

SourceResult _torrent(
  String name, {
  String quality = '1080P',
  int? seeders,
  int? peers,
  int sizeBytes = 1200 * _mb,
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
    releaseQuality: 'WEB-DL',
    seeders: seeders,
    peers: peers,
    sizeBytes: sizeBytes,
    torrentFileIndex: 0,
  );
}

LocalTorrentProbeResult _live({
  double speed = 2.5 * _mb,
  int latencyMs = 400,
  int peers = 12,
  int connections = 8,
}) {
  return LocalTorrentProbeResult(
    playableNow: true,
    bytesReceived: _mb,
    elapsed: const Duration(seconds: 1),
    firstByteLatency: Duration(milliseconds: latencyMs),
    peers: peers,
    connections: connections,
    downloadSpeedBytesPerSecond: speed,
    sampleWindowsPassed: 2,
    metadataElapsed: const Duration(milliseconds: 900),
  );
}

LocalTorrentProbeResult _failed(
  LocalTorrentProbeStatus outcome, {
  int? discoveredPeers,
}) {
  return LocalTorrentProbeResult(
    playableNow: false,
    bytesReceived: 0,
    elapsed: Duration.zero,
    firstByteLatency: null,
    peers: 0,
    connections: 0,
    downloadSpeedBytesPerSecond: 0,
    sampleWindowsPassed: 0,
    outcome: outcome,
    discoveredPeers: discoveredPeers,
  );
}

/// Metadata resolved, peers connected, but no media bytes arrived.
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

/// Deterministic probe runner: results by source title, unknown titles fail
/// with no peers. Records every probed title.
class _Runner {
  _Runner(this.results);

  final Map<String, LocalTorrentProbeResult> results;
  final probed = <String>[];

  Future<LocalTorrentProbeResult> call(SourceResult source) async {
    probed.add(source.title);
    return results[source.title] ??
        const LocalTorrentProbeResult(
          playableNow: false,
          bytesReceived: 0,
          elapsed: Duration.zero,
          firstByteLatency: null,
          peers: 0,
          connections: 0,
          downloadSpeedBytesPerSecond: 0,
          sampleWindowsPassed: 0,
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Free P2P live-first ranking', () {
    test('100+ provider seeders with no live data never outranks a live source',
        () async {
      final sources = SourceProviderService();
      final hyped = _torrent('Hyped.1080p', seeders: 140, peers: 60);
      final modest = _torrent('Modest.720p', quality: '720P', seeders: 3);
      final runner = _Runner({
        'Hyped.1080p': _failed(
          LocalTorrentProbeStatus.metadataTimeout,
          discoveredPeers: 0,
        ),
        'Modest.720p': _live(),
      });
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      // Static provider metadata alone prefers the hyped torrent.
      expect(sources.sortForFreeStreaming([modest, hyped]).first,
          same(hyped));

      final chosen = await probe.probeBestCandidate([hyped, modest], sources);
      expect(chosen, same(modest));
      expect(probe.rank([hyped, modest], sources).first, same(modest));
    });

    test('healthy live 720p beats a dead 4K', () async {
      final sources = SourceProviderService();
      final dead4k = _torrent('Dead.2160p',
          quality: '2160P', seeders: 90, sizeBytes: 3 * _gb);
      final live720 = _torrent('Live.720p', quality: '720P', seeders: 4);
      final probe = FreeP2pLiveProbeService(
        probeRunner: _Runner({'Dead.2160p': _stalled, 'Live.720p': _live()})
            .call,
      );
      await probe.probeTopCandidates([dead4k, live720], sources);

      expect(probe.rank([dead4k, live720], sources).first, same(live720));
      expect(probe.healthFor(dead4k)!.label, 'STALLED');
      expect(probe.healthFor(live720)!.isLive, isTrue);
    });

    test('a 4K live source without bitrate headroom loses to a healthy 720p',
        () async {
      final sources = SourceProviderService();
      final heavy4k = _torrent('Heavy.2160p',
          quality: '2160P', seeders: 200, sizeBytes: 20 * _gb);
      final light720 = _torrent('Light.720p',
          quality: '720P', seeders: 10, sizeBytes: 1200 * _mb);
      final probe = FreeP2pLiveProbeService(
        mediaDuration: const Duration(hours: 2),
        probeRunner: _Runner({
          // Same real throughput; the 4K file needs ~3.6 MB/s to keep up.
          'Heavy.2160p': _live(speed: 2.0 * _mb, latencyMs: 300),
          'Light.720p': _live(speed: 2.0 * _mb, latencyMs: 300),
        }).call,
      );
      await probe.probeTopCandidates([heavy4k, light720], sources);

      expect(probe.healthFor(heavy4k)!.label, 'SLOW');
      expect(probe.rank([heavy4k, light720], sources).first, same(light720));
    });

    test('quality only breaks ties between comparably healthy live sources',
        () async {
      final sources = SourceProviderService();
      final hd720 = _torrent('A.Release.720p', quality: '720P', seeders: 30);
      final hd1080 = _torrent('B.Release.1080p', seeders: 30);
      final probe = FreeP2pLiveProbeService(
        probeRunner: _Runner({
          'A.Release.720p': _live(speed: 2.4 * _mb, latencyMs: 420, peers: 14),
          'B.Release.1080p': _live(speed: 2.2 * _mb, latencyMs: 460, peers: 11),
        }).call,
      );
      await probe.probeTopCandidates([hd720, hd1080], sources);

      // Comparable bands: the late quality tie-break picks 1080p.
      expect(probe.rank([hd720, hd1080], sources).first, same(hd1080));

      // A clearly healthier 720p still wins over a weak live 1080p.
      final weakProbe = FreeP2pLiveProbeService(
        probeRunner: _Runner({
          'A.Release.720p': _live(speed: 3.5 * _mb, latencyMs: 300),
          'B.Release.1080p': _live(speed: 200 * 1024, latencyMs: 2200),
        }).call,
      );
      await weakProbe.probeTopCandidates([hd720, hd1080], sources);
      expect(weakProbe.rank([hd720, hd1080], sources).first, same(hd720));
    });

    test('0 provider seeders with real live bytes beats unprobed high seeders',
        () {
      final sources = SourceProviderService();
      final unprobed = _torrent('Popular.1080p', seeders: 120);
      final zeroSeed = _torrent('Quiet.1080p', seeders: 0, peers: 0);

      expect(
        FreeP2pLiveProbeService.compareFreeP2p(
          zeroSeed,
          _live(),
          unprobed,
          null,
          sources: sources,
        ),
        lessThan(0),
      );
    });

    test('evidence tiers: live > unprobed > metadata unresolved > failed', () {
      expect(FreeP2pLiveProbeService.evidenceTier(_live()), 3);
      expect(FreeP2pLiveProbeService.evidenceTier(null), 2);
      // Engine failure says nothing about the torrent: same as unprobed.
      expect(
        FreeP2pLiveProbeService.evidenceTier(
            _failed(LocalTorrentProbeStatus.engineUnavailable)),
        2,
      );
      expect(
        FreeP2pLiveProbeService.evidenceTier(
            _failed(LocalTorrentProbeStatus.metadataTimeout)),
        1,
      );
      expect(FreeP2pLiveProbeService.evidenceTier(_stalled), 0);
      expect(
        FreeP2pLiveProbeService.evidenceTier(
            _failed(LocalTorrentProbeStatus.createError)),
        0,
      );
    });

    test('stalled, metadata timeout and engine errors keep distinct labels',
        () {
      expect(_stalled.status, LocalTorrentProbeStatus.stalled);
      expect(_failed(LocalTorrentProbeStatus.metadataTimeout).label,
          'METADATA SLOW');
      expect(_failed(LocalTorrentProbeStatus.engineUnavailable).label,
          'ENGINE ERROR');
      expect(_failed(LocalTorrentProbeStatus.metadataTimeout).metadataResolved,
          isFalse);
      expect(_stalled.metadataResolved, isTrue);
    });
  });

  group('Normal Play auto-pick', () {
    test('all probed torrents failing auto-picks nothing', () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('Dead.$i.1080p', seeders: 100 - i),
      ];
      final runner = _Runner({
        for (final source in results)
          source.title: _failed(LocalTorrentProbeStatus.metadataTimeout),
      });
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      final chosen = await probe.probeBestCandidate(results, sources);

      expect(chosen, isNull, reason: 'never launch a failed torrent');
      expect(probe.noLiveConfirmed, isTrue);
      // Bounded: the initial shortlist plus one expansion batch.
      expect(
        runner.probed.length,
        FreeP2pLiveProbeService.initialShortlistSize +
            FreeP2pLiveProbeService.expansionBatchSize,
      );
      final summary = probe.summary(results);
      expect(summary.live, 0);
      expect(summary.unresolved, runner.probed.length);
      expect(summary.notChecked, results.length - runner.probed.length);
    });

    test('a live source found in the expansion batch is promoted and picked',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('Source.$i.1080p', seeders: 100 - i),
      ];
      // Static order is by seeders, so index 8 is outside the initial six.
      final late = results[8];
      final runner = _Runner({late.title: _live()});
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      final chosen = await probe.probeBestCandidate(results, sources);

      expect(chosen, same(late));
      expect(runner.probed.take(6), isNot(contains(late.title)));
      expect(runner.probed, contains(late.title));
      expect(probe.rank(results, sources).first, same(late));
    });

    test('the picker check expands the same way when the first batch fails',
        () async {
      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('Pick.$i.1080p', seeders: 100 - i),
      ];
      final late = results[7];
      final probe = FreeP2pLiveProbeService(
        probeRunner: _Runner({late.title: _live()}).call,
      );

      await probe.probeTopCandidates(results, sources);

      expect(probe.hasPlayableResult, isTrue);
      expect(probe.rank(results, sources).first, same(late));
    });

    test('direct HTTP is returned immediately without torrent probes',
        () async {
      final sources = SourceProviderService();
      const direct = SourceResult(
        provider: 'Direct',
        title: 'Direct.720p',
        resource: 'https://example.test/movie.mkv',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
        quality: '720P',
      );
      final torrent = _torrent('Torrent.1080p', seeders: 300);
      final runner = _Runner({'Torrent.1080p': _live()});
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      expect(await probe.probeBestCandidate([torrent, direct], sources),
          same(direct));
      expect(runner.probed, isEmpty);

      // Even with live torrent evidence, direct HTTP stays first.
      await probe.probeTopCandidates([torrent, direct], sources);
      expect(probe.rank([torrent, direct], sources).first, same(direct));
    });
  });

  group('Pinned sources in Free P2P', () {
    test('a pin confirmed failed does not hold a live source below it',
        () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 80);
      final live = _torrent('Live.720p', quality: '720P', seeders: 5);
      final other = _torrent('Other.720p', quality: '720P', seeders: 2);
      final probe = FreeP2pLiveProbeService(
        probeRunner: _Runner({
          'Pinned.1080p': _stalled,
          'Live.720p': _live(),
        }).call,
      );
      await probe.probeTopCandidates([pinned, live, other], sources);
      bool isPinned(SourceResult s) => identical(s, pinned);

      final ordered = probe.applyPinnedPreference(
        probe.rank([pinned, live, other], sources),
        isPinned,
      );
      expect(ordered.first, same(live));
      expect(ordered, contains(pinned), reason: 'the pin stays selectable');
    });

    test('Normal Play: a stalled pin loses to a healthy live alternative',
        () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 120);
      final live = _torrent('Live.720p', quality: '720P', seeders: 3);
      final runner = _Runner({'Pinned.1080p': _stalled, 'Live.720p': _live()});
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      final chosen = await probe.probeBestCandidate(
        [pinned, live],
        sources,
        preferred: pinned,
      );

      expect(runner.probed.first, pinned.title, reason: 'the pin is probed first');
      expect(chosen, same(live));
    });

    test('Normal Play: a metadata-slow pin is never auto-launched', () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 120);
      final live = _torrent('Live.720p', quality: '720P', seeders: 3);
      final probe = FreeP2pLiveProbeService(
        probeRunner: _Runner({
          'Pinned.1080p': _failed(LocalTorrentProbeStatus.metadataTimeout),
          'Live.720p': _live(),
        }).call,
      );

      expect(
        await probe.probeBestCandidate([pinned, live], sources,
            preferred: pinned),
        same(live),
      );
    });

    test('Normal Play: a confirmed-live pin wins over a healthier source',
        () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.720p', quality: '720P', seeders: 1);
      final stronger = _torrent('Stronger.1080p', seeders: 300);
      final runner = _Runner({
        // Live but not "ready now": the pin preference still wins.
        'Pinned.720p': _live(speed: 600 * 1024, latencyMs: 1500),
        'Stronger.1080p': _live(speed: 6.0 * _mb, latencyMs: 200),
      });
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      final chosen = await probe.probeBestCandidate(
        [stronger, pinned],
        sources,
        preferred: pinned,
      );

      expect(chosen, same(pinned));
      expect(runner.probed.first, pinned.title);
    });

    test('Normal Play: a failed pin with no live alternative launches nothing',
        () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 200);
      final others = [
        for (var i = 0; i < 10; i++) _torrent('Other.$i.1080p', seeders: 50 - i),
      ];
      final runner = _Runner({'Pinned.1080p': _stalled});
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      final chosen = await probe.probeBestCandidate(
        [pinned, ...others],
        sources,
        preferred: pinned,
      );

      expect(chosen, isNull);
      expect(probe.noLiveConfirmed, isTrue);
      expect(runner.probed.first, pinned.title);
      // The pin takes a first-batch slot: still bounded to 6 + 3.
      expect(
        runner.probed.length,
        FreeP2pLiveProbeService.initialShortlistSize +
            FreeP2pLiveProbeService.expansionBatchSize,
      );
    });

    test('Normal Play: a direct HTTP pin is used immediately', () async {
      final sources = SourceProviderService();
      const directPin = SourceResult(
        provider: 'Direct',
        title: 'Direct.Pin',
        resource: 'https://example.test/pin.mkv',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
      );
      final runner = _Runner({});
      final probe = FreeP2pLiveProbeService(probeRunner: runner.call);

      expect(
        await probe.probeBestCandidate(
          [_torrent('Torrent.1080p', seeders: 90), directPin],
          sources,
          preferred: directPin,
        ),
        same(directPin),
      );
      expect(runner.probed, isEmpty);
    });

    test('Normal Play: a pinned torrent is checked before a direct fallback',
        () async {
      final sources = SourceProviderService();
      const direct = SourceResult(
        provider: 'Direct',
        title: 'Direct.720p',
        resource: 'https://example.test/movie.mkv',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
      );
      final pinned = _torrent('Pinned.1080p', seeders: 40);

      final dead = FreeP2pLiveProbeService(
        probeRunner: _Runner({'Pinned.1080p': _stalled}).call,
      );
      expect(
        await dead.probeBestCandidate([pinned, direct], sources,
            preferred: pinned),
        same(direct),
      );

      final live = FreeP2pLiveProbeService(
        probeRunner: _Runner({'Pinned.1080p': _live()}).call,
      );
      expect(
        await live.probeBestCandidate([pinned, direct], sources,
            preferred: pinned),
        same(pinned),
      );
    });

    test('Quick Play needs confirmed live evidence, pinned or not', () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 80);
      final live = _torrent('Live.720p', quality: '720P', seeders: 5);
      final failed = _torrent('Failed.720p', quality: '720P', seeders: 9);
      const direct = SourceResult(
        provider: 'Direct',
        title: 'Direct.720p',
        resource: 'https://example.test/movie.mkv',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
      );
      final pending = Completer<LocalTorrentProbeResult>();
      final probe = FreeP2pLiveProbeService(
        probeRunner: (source) async => switch (source.title) {
          'Live.720p' => _live(),
          'Failed.720p' => _stalled,
          _ => pending.future,
        },
      );

      // Unprobed pinned magnet: no Quick Play.
      expect(probe.quickPlayAllowed(pinned), isFalse);
      expect(probe.quickPlayAllowed(direct), isTrue);

      final run = probe.probeTopCandidates([pinned, live, failed], sources);
      await Future<void>.delayed(Duration.zero);
      // Still checking: no Quick Play.
      expect(probe.healthFor(pinned)?.state, FreeP2pHealthState.checking);
      expect(probe.quickPlayAllowed(pinned), isFalse);
      expect(probe.quickPlayAllowed(live), isTrue);
      expect(probe.quickPlayAllowed(failed), isFalse);

      pending.complete(_failed(LocalTorrentProbeStatus.metadataTimeout));
      await run;
      expect(probe.quickPlayAllowed(pinned), isFalse);
    });

    test('an unprobed or live pin still goes first', () async {
      final sources = SourceProviderService();
      final pinned = _torrent('Pinned.1080p', seeders: 1);
      final live = _torrent('Live.720p', quality: '720P', seeders: 50);
      final unprobedPin = FreeP2pLiveProbeService(
        probeRunner: _Runner({}).call,
      );
      expect(
        unprobedPin
            .applyPinnedPreference(
              unprobedPin.rank([live, pinned], sources),
              (s) => identical(s, pinned),
            )
            .first,
        same(pinned),
      );

      final failedNoAlternative = FreeP2pLiveProbeService(
        probeRunner: _Runner({'Pinned.1080p': _stalled}).call,
      );
      await failedNoAlternative.probeTopCandidates([live, pinned], sources);
      // Nothing else is confirmed live, so the preference still wins.
      expect(
        failedNoAlternative
            .applyPinnedPreference(
              failedNoAlternative.rank([live, pinned], sources),
              (s) => identical(s, pinned),
            )
            .first,
        same(pinned),
      );
    });
  });

  test('diagnostic report carries no magnet, trackers or titles', () async {
    final sources = SourceProviderService();
    final source = SourceResult(
      provider: 'Torrentio',
      title: 'Secret.Title.1080p',
      resource: 'magnet:?xt=urn:btih:${'c' * 40}'
          '&tr=udp%3A%2F%2Ftracker.example%3A80&dn=Secret.Title',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
      seeders: 120,
      peers: 4,
    );
    final probe = FreeP2pLiveProbeService(
      probeRunner: (_) async => _failed(
        LocalTorrentProbeStatus.metadataTimeout,
        discoveredPeers: 3,
      ),
    );
    await probe.probeTopCandidates([source], sources);

    final report = probe.diagnosticReport([source]);
    expect(report, contains('"status":"metadataTimeout"'));
    expect(report, contains('"providerSeeders":120'));
    expect(report, contains('"discoveredPeers":3'));
    expect(report, contains('"metadataResolved":false'));
    expect(report, isNot(contains('magnet:')));
    expect(report, isNot(contains('tracker.example')));
    expect(report, isNot(contains('Secret.Title')));
    expect(report, isNot(contains('c' * 40)));
  });

  test('mobile, desktop and TV pickers share the same live ranking path', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final tv =
        File('lib/screens/tv_source_browser_screen.dart').readAsStringSync();
    for (final source in [details, tv]) {
      expect(source, contains('applyPinnedPreference('));
      expect(source, contains('healthFor('));
    }
    expect(details, contains('liveProbe.rank(results, widget.sources)'));
    expect(tv, contains('_liveProbe.rank(_results, widget.sources)'));
    // Normal Play hands its evidence to the picker instead of releasing it,
    // and TV receives the same session.
    expect(details, contains('final probeSession = autoProbeSession ??'));
    expect(details, contains('probeSession: probeSession,'));
    // One cloud/debrid eligibility check drives Normal Play, the picker,
    // Android TV and playback.
    // Android Mobile and Android TV never run Normal Play's live check.
    expect(details, contains('!_androidPlayback &&\n          !hasCloudConnection &&\n          chosen == null'));
    expect(details, contains('var freeStreamingRanking = !hasCloudConnection;'));
    expect(details, isNot(contains('hasDebridConnection')));
    expect(details, contains('Future<bool> _hasCloudConnection() async'));
    expect(
      RegExp(r'await _hasCloudConnection\(\)').allMatches(details).length,
      greaterThanOrEqualTo(5),
    );
    expect(details, isNot(contains('preferFreeP2p: !hasDebrid')));
    expect(
      RegExp(r'preferFreeP2p: !hasCloudConnection').allMatches(details).length,
      2,
    );
    // Pinned torrents go through the live check; Quick Play has no pin bypass.
    expect(details, contains('preferred: pinnedResult,'));
    // Without a cloud path, only a direct HTTP pin skips the live check.
    expect(details, contains('(hasCloudConnection || !pinnedResult.isMagnet)'));
    expect(details, contains('liveProbe.quickPlayAllowed(source)'));
    expect(details, isNot(contains('health.state == FreeP2pHealthState.checking')));
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

    Finder rows() => find.byWidgetPredicate((widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('tv-source-'));

    bool focusIn(WidgetTester tester, Finder finder) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      final target = tester.element(finder);
      if (focused == target) return true;
      var found = false;
      focused.visitAncestorElements((ancestor) {
        if (ancestor == target) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    testWidgets('uses the same live-first ranking and health labels',
        (tester) async {
      setTvSize(tester);
      final sources = SourceProviderService();
      final dead4k = _torrent('Trigger.2025.2160p',
          quality: '2160P', seeders: 150, sizeBytes: 3 * _gb);
      final live720 =
          _torrent('Trigger.2025.720p', quality: '720P', seeders: 2);
      final session = FreeP2pLiveProbeService(
        probeRunner: _Runner({
          dead4k.title: _stalled,
          live720.title: _live(),
        }).call,
      );
      await session.probeTopCandidates([dead4k, live720], sources);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value([dead4k, live720]),
          probeSession: session,
        ),
      ));
      await settle(tester);

      expect(
        find.descendant(
            of: rows().first, matching: find.text('Trigger.2025.720p')),
        findsOneWidget,
      );
      expect(find.text('STALLED'), findsOneWidget);
      expect(find.text('150 seeders reported'), findsOneWidget);
      // Same comparator as mobile/desktop.
      expect(session.rank([dead4k, live720], sources).first, same(live720));
    });

    testWidgets('a live-check reorder keeps focus on the same source',
        (tester) async {
      setTvSize(tester);
      final sources = SourceProviderService();
      final first =
          _torrent('Verity.2026.2160p', quality: '2160P', seeders: 150);
      final focused = _torrent('Verity.2026.1080p', seeders: 100);
      final quiet = _torrent('Verity.2026.720p', quality: '720P', seeders: 2);
      final pending = <String, Completer<LocalTorrentProbeResult>>{};
      final session = FreeP2pLiveProbeService(
        probeRunner: (source) =>
            (pending[source.title] = Completer<LocalTorrentProbeResult>())
                .future,
      );

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value([first, focused, quiet]),
          probeSession: session,
        ),
      ));
      await settle(tester);

      Finder rowFor(SourceResult source) => find.byKey(ValueKey(
          'tv-source-${sources.sourceIdentity(source, seriesWide: false)}'));
      // Opening the browser checks nothing; the check runs only when the
      // user asks for it with "Re-check live".
      expect(pending, isEmpty);
      expect(find.text('CHECKING'), findsNothing);
      expect(focusIn(tester, rowFor(first)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(focusIn(tester, rowFor(focused)), isTrue);
      // Start the check from the chip without moving focus off the row.
      final recheck = tester.widget(find.ancestor(
        of: find.text('Re-check live'),
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_TvFilterChip',
        ),
      )) as dynamic;
      (recheck.onPressed as VoidCallback)();
      await settle(tester);
      // Static order while checking: 2160p (150 seeds), 1080p, 720p.
      expect(find.text('CHECKING'), findsNWidgets(3));
      expect(focusIn(tester, rowFor(focused)), isTrue);

      // After the check: 720p live, 2160p unresolved, the focused 1080p
      // stalled. The focused row moves from the 2nd to the 3rd position.
      pending[first.title]!
          .complete(_failed(LocalTorrentProbeStatus.metadataTimeout));
      pending[focused.title]!.complete(_stalled);
      pending[quiet.title]!.complete(_live());
      await settle(tester);

      final order = tester
          .widgetList(rows())
          .map((widget) => (widget.key! as ValueKey<String>).value)
          .toList();
      String keyOf(SourceResult source) =>
          'tv-source-${sources.sourceIdentity(source, seriesWide: false)}';
      expect(order, [keyOf(quiet), keyOf(first), keyOf(focused)]);
      expect(focusIn(tester, rowFor(focused)), isTrue,
          reason: 'focus follows the source, not the old row index');
    });

    testWidgets('debrid mode keeps its normal order and never probes',
        (tester) async {
      setTvSize(tester);
      final sources = SourceProviderService();
      final uhd = _torrent('Movie.2160p', quality: '2160P', seeders: 5);
      final hd = _torrent('Movie.720p', quality: '720P', seeders: 500);
      final runner = _Runner({});
      final session = FreeP2pLiveProbeService(probeRunner: runner.call);

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value([hd, uhd]),
          preferFreeP2p: false,
          probeSession: session,
        ),
      ));
      await settle(tester);

      expect(runner.probed, isEmpty);
      expect(
        find.descendant(of: rows().first, matching: find.text('Movie.2160p')),
        findsOneWidget,
        reason: 'default priority still ranks resolution',
      );
      expect(find.text('5 seeders'), findsOneWidget);
    });
  });
}
