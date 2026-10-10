import 'dart:async';
import 'dart:io';

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

SourceResult _torrent(
  String name, {
  String? hash,
  int fileIndex = 0,
  int seeders = 10,
  String provider = 'Torrentio',
}) {
  final infoHash = hash ??
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(40, '0');
  return SourceResult(
    provider: provider,
    title: name,
    resource: 'magnet:?xt=urn:btih:$infoHash',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: '1080P',
    seeders: seeders,
    sizeBytes: 1200 * _mb,
    torrentFileIndex: fileIndex,
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

const _live = LocalTorrentProbeResult(
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

/// Deterministic torrent engine that records the session lifecycle.
class _Engine implements FreeP2pProbeEngine {
  _Engine(this.outcomes, {this.holdOnly = const <String>{}});

  final Map<String, LocalTorrentProbeResult> outcomes;
  final Set<String> holdOnly;

  /// When true every new probe waits until the test completes it.
  bool hold = false;

  final probed = <String>[];
  final released = <String>[];
  final handedOff = <String>[];
  var releaseAllCalls = 0;
  final held = <String, Completer<void>>{};

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) async {
    probed.add(source.title);
    if (hold || holdOnly.contains(source.title)) {
      await (held[source.title] = Completer<void>()).future;
    } else {
      await Future<void>.value();
    }
    return outcomes[source.title] ?? _stalled;
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
    released.add(source.title);
  }

  @override
  Future<void> prepareForPlayback(SourceResult source) async {
    handedOff.add(source.title);
  }

  @override
  Future<void> releaseAll() async => releaseAllCalls++;
}

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('probe-to-playback handoff', () {
    test(
        'a late live probe of another file in the handed-off torrent does not '
        'release the playback session', () async {
      final sources = SourceProviderService();
      final hash = 'a' * 40;
      final chosen = _torrent('Pack.E01.Torrentio', hash: hash, fileIndex: 0);
      final sibling = _torrent(
        'Pack.E01.OtherAddon',
        hash: hash,
        fileIndex: 3,
        provider: 'MediaFusion',
      );
      final engine = _Engine(
        {chosen.title: _live, sibling.title: _live},
        holdOnly: {sibling.title},
      );
      final probe = FreeP2pLiveProbeService(engine: engine);

      final run = probe.probeTopCandidates([chosen, sibling], sources);
      await _flush();
      expect(probe.quickPlayAllowed(chosen), isTrue);

      // The user plays the confirmed-live row while the sibling row of the
      // same torrent is still being checked.
      await probe.prepareForPlayback(chosen);
      engine.completeAll();
      await run;

      expect(engine.released, isEmpty,
          reason: 'releasing the sibling would detach the playing torrent');
    });

    test('a late live probe of a different torrent is still released',
        () async {
      final sources = SourceProviderService();
      final chosen = _torrent('Chosen.1080p');
      final other = _torrent('Other.1080p');
      final engine = _Engine(
        {chosen.title: _live, other.title: _live},
        holdOnly: {other.title},
      );
      final probe = FreeP2pLiveProbeService(engine: engine);

      final run = probe.probeTopCandidates([chosen, other], sources);
      await _flush();
      await probe.prepareForPlayback(chosen);
      engine.completeAll();
      await run;

      expect(engine.released, [other.title]);
    });
  });

  group('expired live-health evidence', () {
    test('is never used for Quick Play, Normal Play or the live group',
        () async {
      var now = DateTime(2026, 10, 10, 20);
      final sources = SourceProviderService();
      final live = _torrent('Trigger.S01E01.1080p');
      final engine = _Engine({live.title: _live});
      final probe = FreeP2pLiveProbeService(engine: engine, clock: () => now);

      await probe.probeTopCandidates([live], sources);
      expect(probe.quickPlayAllowed(live), isTrue);
      expect(probe.healthFor(live)?.isLive, isTrue);

      now = now.add(const Duration(minutes: 4));
      expect(probe.healthFor(live), isNull);
      expect(
          probe.displayHealthFor(live)?.state, FreeP2pHealthState.notChecked);
      expect(probe.quickPlayAllowed(live), isFalse);
      expect(probe.quickPlayCandidate([live], sources), isNull);
      expect(probe.hasPlayableResult, isFalse);
      expect(probe.groupHeaders([live]), isEmpty);

      // Normal Play checks again instead of trusting the expired result.
      engine.outcomes[live.title] = _stalled;
      final picked = await probe.probeBestCandidate([live], sources);
      expect(picked, isNull);
      expect(engine.probed, [live.title, live.title]);
    });
  });

  group('playback safety does not depend on the display mode', () {
    late SourceProviderService sources;
    setUp(() => sources = SourceProviderService());
    final live = _torrent('Live.720p', seeders: 2);
    final unchecked = _torrent('Unchecked.2160p', seeders: 900);
    final stalled = _torrent('Stalled.1080p', seeders: 500);
    final noPeers = _torrent('NoPeers.1080p', seeders: 400);
    final engineError = _torrent('EngineError.1080p', seeders: 300);
    final metadata = _torrent('MetadataSlow.1080p', seeders: 200);
    final all = [unchecked, stalled, noPeers, engineError, metadata, live];

    Future<FreeP2pLiveProbeService> checked(SourceDisplayMode mode) async {
      final engine = _Engine({
        live.title: _live,
        stalled.title: _stalled,
        noPeers.title: _outcome(LocalTorrentProbeStatus.noPeers),
        engineError.title: _outcome(LocalTorrentProbeStatus.engineUnavailable),
        metadata.title: _outcome(LocalTorrentProbeStatus.metadataTimeout),
      });
      final probe = FreeP2pLiveProbeService(engine: engine)
        ..setDisplayMode(mode);
      // Probe everything except the unchecked row.
      await probe.probeTopCandidates(
        all.where((s) => !identical(s, unchecked)),
        sources,
      );
      return probe;
    }

    for (final mode in SourceDisplayMode.values) {
      test(
          '${mode.name}: only confirmed-live torrents or direct HTTP may '
          'auto-launch', () async {
        final probe = await checked(mode);
        for (final source in all) {
          expect(
            probe.quickPlayAllowed(source),
            identical(source, live),
            reason: source.title,
          );
        }
        expect(probe.quickPlayAllowed(_direct), isTrue);
        expect(probe.quickPlayCandidate(all, sources), same(live));
        // An unchecked or failed pin never blocks the live alternative.
        for (final pin in [unchecked, stalled, engineError]) {
          expect(
            probe.quickPlayCandidate(all, sources,
                isPinned: (s) => identical(s, pin)),
            same(live),
            reason: 'pinned ${pin.title}',
          );
        }
        // Manual choice: every row is still listed with an honest state.
        final ranked = probe.rank(all, sources);
        expect(ranked.toSet(), all.toSet());
        expect(probe.displayHealthFor(unchecked)!.label, 'NOT CHECKED');
        expect(probe.displayHealthFor(engineError)!.label, 'ENGINE ERROR');
        expect(probe.displayHealthFor(noPeers)!.label, 'NO PEERS');
        expect(probe.failedLiveCheck(engineError), isFalse,
            reason: 'an engine error is not a verdict on the torrent');
        expect(probe.failedLiveCheck(unchecked), isFalse);
      });
    }

    test('a healthy pinned torrent is preferred by Quick Play', () async {
      final otherLive = _torrent('OtherLive.1080p', seeders: 999);
      final engine = _Engine({live.title: _live, otherLive.title: _live});
      final probe = FreeP2pLiveProbeService(engine: engine);
      await probe.probeTopCandidates([otherLive, live], sources);
      expect(
        probe.quickPlayCandidate([otherLive, live], sources,
            isPinned: (s) => identical(s, live)),
        same(live),
      );
    });

    test('provider seeders are never shown as live peer evidence', () async {
      final probe = await checked(SourceDisplayMode.recommended);
      final unknown = probe.displayHealthFor(unchecked)!;
      expect(unknown.isLive, isFalse);
      expect(unknown.result, isNull);
      expect(unknown.metrics, isNull);
      final measured = probe.displayHealthFor(live)!;
      expect(measured.metrics, contains('12 live peers'));
      expect(measured.metrics, isNot(contains('seeder')));
    });
  });

  test('mobile, TV and cloud playback paths keep their routing and tracing',
      () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final tv =
        File('lib/screens/tv_source_browser_screen.dart').readAsStringSync();

    // Normal Play and the mobile picker name how the source was chosen.
    expect(details, contains("selection: 'normalPlay'"));
    expect(details, contains("selectedVia = 'quickPlay';"));
    expect(
        details,
        contains(
            'liveProbe.prepareForPlayback(selected, selection: selectedVia)'));
    // TV hands off through the same probe session API.
    expect(tv, contains('await _liveProbe.prepareForPlayback(source);'));
    expect(tv, contains("label: 'Live report'"));
    expect(tv, contains('_liveProbe.diagnosticReport(_results)'));

    // Only the Free P2P branches trace; a cloud/debrid route never does and
    // never resolves through the local torrent engine.
    final play = details.substring(
      details.indexOf('Future<void> _playSourceResult('),
      details.indexOf('EpisodeItem? _episodeForPinnedRelease('),
    );
    final cloud = play
        .substring(play.indexOf('final cloud = await _chooseCloudProvider();'));
    expect(cloud, isNot(contains('FreeP2pPlaybackTrace')));
    expect(cloud, isNot(contains('LocalTorrentService')));
    expect(play, contains('final trace = cloudConnected'));
    expect(play, contains('trace: trace,'));
    // Direct HTTP keeps its own route: no torrent resolve.
    final direct = play.substring(0, play.indexOf('if (!cloudConnected) {'));
    expect(direct, contains('chosen.resource,'));
    expect(direct, isNot(contains('LocalTorrentService.instance.resolve(')));
  });

  group('Android TV source browser lifecycle', () {
    const movie = MediaItem(
      id: 'tt0000001',
      kind: MediaKind.movie,
      title: 'Trigger',
      year: '2025',
    );

    setUp(() => PlatformProfile.debugAndroidTvOverride = true);
    tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets(
        'leaving after a playback and a re-check stops the check and releases '
        'its sessions', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final sources = SourceProviderService();
      final results = [
        for (var i = 0; i < 12; i++)
          _torrent('Trigger.Source.$i.1080p', seeders: 500 - i),
      ];
      final engine = _Engine({for (final s in results) s.title: _live});
      final session = FreeP2pLiveProbeService(engine: engine);
      final played = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: TvSourceBrowserScreen(
          sources: sources,
          item: movie,
          resultsFuture: Future.value(results),
          probeSession: session,
          onPlaySource: (source) async => played.add(source.title),
        ),
      ));
      await settle(tester);

      // Play a source; the player returns to the browser.
      await tester.tap(find.text(results.first.title).first);
      await settle(tester);
      expect(played, [results.first.title]);
      expect(engine.handedOff, [results.first.title]);

      // Re-check starts a new bounded check whose probes are held.
      engine.hold = true;
      await tester.tap(find.text('Re-check live'));
      await settle(tester);
      final probedBeforeLeave = engine.probed.length;
      expect(session.isRunning, isTrue);
      final releasesBeforeLeave = engine.releaseAllCalls;

      // Leave the browser.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await settle(tester);
      expect(engine.releaseAllCalls, greaterThan(releasesBeforeLeave),
          reason: 'leaving releases the warm probe sessions');

      // The in-flight probes finish; no further batch may start.
      engine.hold = false;
      engine.completeAll();
      await settle(tester);
      await tester.runAsync(_flush);
      expect(engine.probed.length, probedBeforeLeave,
          reason: 'no background probing after the browser is gone');
    });

    testWidgets('choosing a source keeps its warm session for playback',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final sources = SourceProviderService();
      final source = _torrent('Trigger.Chosen.1080p');
      final engine = _Engine({source.title: _live});
      final session = FreeP2pLiveProbeService(engine: engine);
      SourceResult? popped;

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<SourceResult>(
                MaterialPageRoute(
                  builder: (_) => TvSourceBrowserScreen(
                    sources: sources,
                    item: movie,
                    resultsFuture: Future.value([source]),
                    probeSession: session,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.text(source.title).first);
      await settle(tester);

      expect(popped, same(source));
      expect(engine.handedOff, [source.title]);
      expect(engine.releaseAllCalls, 0,
          reason: 'the handed-off session must survive until resolve()');
    });
  });
}
