import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/free_p2p_playback_trace.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1024 * 1024;
final _hash = 'c0ffee12' * 5;

SourceResult _torrent({int? seeders = 120, String title = 'Trigger.S01E01'}) {
  return SourceResult(
    provider: 'Torrentio',
    title: '$title.1080p.WEB-DL',
    resource: 'magnet:?xt=urn:btih:$_hash'
        '&tr=udp%3A%2F%2Ftracker.private.example%3A80'
        '&x-orvix-file-name=$title.mkv',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: '1080P',
    releaseQuality: 'WEB-DL',
    seeders: seeders,
    peers: 30,
    sizeBytes: 1400 * _mb,
    torrentFileIndex: 2,
    fileNameHint: '$title.mkv',
  );
}

const _live = LocalTorrentProbeResult(
  playableNow: true,
  bytesReceived: _mb,
  elapsed: Duration(seconds: 1),
  firstByteLatency: Duration(milliseconds: 420),
  peers: 9,
  connections: 6,
  downloadSpeedBytesPerSecond: 2.5 * _mb,
  sampleWindowsPassed: 2,
  metadataElapsed: Duration(milliseconds: 1300),
);

/// Engine stand-in for playback resolve.
MockClient _engine({
  bool heartbeat = true,
  int createStatus = 200,
  Map<String, Object?> createBody = const {'guessedFileIdx': 2},
  bool createHangs = false,
  bool createTransportError = false,
  Map<String, Object?>? swarmStats,
}) {
  http.StreamedResponse json(Object? body, {int status = 200}) =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(jsonEncode(body ?? {}))),
        status,
      );
  return MockClient.streaming((request, body) async {
    final path = request.url.path;
    final segments = request.url.pathSegments;
    if (path == '/heartbeat') {
      if (!heartbeat) throw http.ClientException('refused', request.url);
      return json(<String, Object?>{});
    }
    if (path == '/settings') return json(<String, Object?>{});
    if (path == '/create') {
      if (createTransportError) {
        throw http.ClientException('Connection reset', request.url);
      }
      if (createHangs) await Completer<void>().future;
      return json(createBody, status: createStatus);
    }
    if (segments.length == 2 && segments[1] == 'stats.json') {
      return swarmStats == null ? json(null, status: 404) : json(swarmStats);
    }
    return json(<String, Object?>{});
  });
}

Map<String, Object?> _attemptJson(FreeP2pPlaybackAttempt attempt) =>
    jsonDecode(jsonEncode(attempt.toDiagnostics())) as Map<String, Object?>;

List<String> _stageResults(FreeP2pPlaybackAttempt attempt) => [
      for (final stage in attempt.stages)
        '${stage['stage']}:${stage['result']}',
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = LocalTorrentService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() => service.debugStartEngineOverride = null);

  group('report redaction', () {
    test('a direct HTTP source keeps only its host', () {
      final trace = FreeP2pPlaybackTrace();
      const direct = SourceResult(
        provider: 'torrentio.strem.fun',
        title: 'Trigger.S01E01.1080p',
        resource: 'https://user:hunter2@torrentio.strem.fun/realdebrid/'
            'RDKEY0123456789abcdefABCDEF0123456789/abc/1/Trigger.S01E01.mkv'
            '?token=SECRETTOKEN&apikey=topsecret',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
        quality: '1080P',
      );
      final attempt = trace.begin(direct)..stage('route', 'directHttp');
      attempt.finish(
        FreeP2pPlaybackOutcome.playerFailure,
        detail: 'Failed to open https://torrentio.strem.fun/realdebrid/'
            'RDKEY0123456789abcdefABCDEF0123456789/x.mkv?token=SECRETTOKEN '
            'Authorization: Bearer abcdefghijklmnopqrstuvwxyz',
      );

      final report = trace.report();
      expect(report, contains('"host":"torrentio.strem.fun"'));
      expect(report, contains('"sourceType":"directHttp"'));
      expect(report, contains('"outcome":"playerFailure"'));
      for (final secret in [
        'hunter2',
        'RDKEY0123456789abcdefABCDEF0123456789',
        'SECRETTOKEN',
        'topsecret',
        'abcdefghijklmnopqrstuvwxyz',
        'Trigger.S01E01',
        '/realdebrid/',
      ]) {
        expect(report, isNot(contains(secret)), reason: secret);
      }
    });

    test('a torrent attempt carries no magnet, trackers, file name or hash',
        () async {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final attempt = trace.begin(source, selection: 'manual');
      attempt.finish(
        FreeP2pPlaybackOutcome.failed,
        detail: 'engine error for magnet:?xt=urn:btih:$_hash&tr=udp://x',
      );
      final report = trace.report();
      // An opaque per-report label, never any part of the info hash.
      expect(report, contains('"torrent":"T1"'));
      expect(report, isNot(contains('c0ffee12')));
      expect(report, isNot(contains('hash8')));
      expect(report, isNot(contains(_hash)));
      expect(report, isNot(contains('magnet:?')));
      expect(report, isNot(contains('tracker.private.example')));
      expect(report, isNot(contains('Trigger.S01E01')));
      expect(report, contains('"providerSeeders":120'));
    });

    test('the report is bounded', () {
      final trace = FreeP2pPlaybackTrace();
      for (var i = 0; i < 20; i++) {
        final attempt = trace.begin(_torrent());
        for (var s = 0; s < 40; s++) {
          attempt.stage('stage$s', 'ok', detail: {'detail': 'x' * 1000});
        }
      }
      expect(trace.attempts, hasLength(FreeP2pPlaybackTrace.maxAttempts));
      for (final attempt in trace.attempts) {
        expect(attempt.stages, hasLength(FreeP2pPlaybackAttempt.maxStages));
      }
      expect(trace.report().length, lessThan(40000));
    });
  });

  group('live-check state at the playback handoff', () {
    test('a confirmed-live pick carries its measured evidence', () async {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final probe = FreeP2pLiveProbeService(
        probeRunner: (_) async => _live,
        playbackTrace: trace,
      );
      await probe.probeTopCandidates([source], SourceProviderService());
      await probe.prepareForPlayback(source, selection: 'quickPlay');

      final json = _attemptJson(trace.attempts.single);
      expect(json['selection'], 'quickPlay');
      expect(json['liveCheck'], FreeP2pHealthState.readyNow.name);
      final evidence = json['liveEvidence']! as Map<String, Object?>;
      expect(evidence['livePeers'], 9);
      expect(evidence['firstByteMs'], 420);
      expect(evidence['metadataResolved'], isTrue);
      // Reported and measured figures are separate fields.
      expect(json['providerSeeders'], 120);
      expect(evidence.containsKey('providerSeeders'), isFalse);
    });

    test('an unchecked manual pick is reported as not checked', () async {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final probe = FreeP2pLiveProbeService(
        probeRunner: (_) async => _live,
        playbackTrace: trace,
      );
      await probe.prepareForPlayback(source);

      final json = _attemptJson(trace.attempts.single);
      expect(json['selection'], 'manual');
      expect(json['liveCheck'], 'notChecked');
      expect(json.containsKey('liveEvidence'), isFalse,
          reason: 'provider seeders are not live evidence');
    });

    test('a pick while its check runs is reported as checking', () async {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final gate = Completer<LocalTorrentProbeResult>();
      final probe = FreeP2pLiveProbeService(
        probeRunner: (_) => gate.future,
        playbackTrace: trace,
      );
      final run = probe.probeTopCandidates([source], SourceProviderService());
      await Future<void>.delayed(Duration.zero);
      await probe.prepareForPlayback(source);
      gate.complete(_live);
      await run;

      expect(_attemptJson(trace.attempts.single)['liveCheck'], 'checking');
    });

    test('the picker report includes the playback attempts and a legend',
        () async {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final probe = FreeP2pLiveProbeService(
        probeRunner: (_) async => _live,
        playbackTrace: trace,
      );
      await probe.probeTopCandidates([source], SourceProviderService());
      await probe.prepareForPlayback(source);
      trace.attempts.single.finish(FreeP2pPlaybackOutcome.metadataTimeout);

      final report = probe.diagnosticReport([source]);
      expect(report, contains('device='));
      expect(report, contains('reported by the provider, not verified'));
      expect(report, contains('"status":"readyNow"'));
      expect(report, contains('playback (newest first):'));
      expect(report, contains('"outcome":"metadataTimeout"'));
    });
  });

  group('playback resolve stages', () {
    test('an engine that cannot start is an engine failure', () async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      service.debugStartEngineOverride =
          () async => throw const LocalTorrentException('engine failed');

      await http.runWithClient(() async {
        await expectLater(
          service.resolve(_torrent(), trace: attempt),
          throwsA(isA<LocalTorrentException>()),
        );
      }, () => _engine(heartbeat: false));

      expect(attempt.outcome, FreeP2pPlaybackOutcome.engineFailure);
      expect(_stageResults(attempt), ['engine:failed']);
    });

    test('a healthy resolve records engine, metadata and pre-buffer stages',
        () async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      final url = await http.runWithClient(
        () => service.resolve(_torrent(), trace: attempt),
        () => _engine(),
      );
      await http.runWithClient(service.releaseCurrentStream, () => _engine());

      expect(url, contains(_hash));
      expect(_stageResults(attempt), [
        'engine:ready',
        'metadata:resolved',
        // Mobile/desktop test host: the player buffers on its own.
        'prebuffer:notRun',
      ]);
      expect(attempt.stages[1]['file'], 'provider');
      expect(attempt.stages.every((s) => s['atMs'] is int), isTrue);
      expect(attempt.outcome, FreeP2pPlaybackOutcome.inProgress,
          reason: 'the player decides the outcome');
    });

    test('an engine HTTP error is a source error', () async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      await http.runWithClient(() async {
        await expectLater(
          service.resolve(_torrent(), trace: attempt),
          throwsA(isA<LocalTorrentException>()),
        );
      }, () => _engine(createStatus: 500));

      expect(attempt.outcome, FreeP2pPlaybackOutcome.sourceError);
      expect(_stageResults(attempt), ['engine:ready', 'metadata:httpError']);
    });

    test('a torrent the engine rejects is a source error', () async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      await http.runWithClient(() async {
        await expectLater(
          service.resolve(_torrent(), trace: attempt),
          throwsA(isA<LocalTorrentException>()),
        );
      }, () => _engine(createBody: const {'error': 'invalid torrent'}));

      expect(attempt.outcome, FreeP2pPlaybackOutcome.sourceError);
      expect(
          _stageResults(attempt), ['engine:ready', 'metadata:engineRejected']);
    });

    test('a create request that dies with the engine is an engine failure',
        () async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      var heartbeat = true;
      final engine = MockClient.streaming((request, body) async {
        if (request.url.path == '/heartbeat') {
          if (!heartbeat) throw http.ClientException('refused', request.url);
          return http.StreamedResponse(
              Stream<List<int>>.value(utf8.encode('{}')), 200);
        }
        if (request.url.path == '/create') {
          heartbeat = false;
          throw http.ClientException('Connection reset', request.url);
        }
        return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{}')), 200);
      });
      await http.runWithClient(() async {
        await expectLater(
          service.resolve(_torrent(), trace: attempt),
          throwsA(isA<LocalTorrentException>()),
        );
      }, () => engine);

      expect(attempt.outcome, FreeP2pPlaybackOutcome.engineFailure);
      expect(attempt.stages.last['engineAnswering'], isFalse);
    });

    testWidgets('a metadata timeout states what the engine saw',
        (tester) async {
      final trace = FreeP2pPlaybackTrace();
      final attempt = trace.begin(_torrent());
      Object? error;
      await http.runWithClient(() async {
        final resolving = service
            .resolve(_torrent(), trace: attempt)
            .then<void>((_) {}, onError: (Object e) => error = e);
        await tester.pump(const Duration(seconds: 46));
        await tester.pump();
        await resolving;
      },
          () => _engine(
                createHangs: true,
                swarmStats: const {'unique': 14, 'peers': 2},
              ));

      expect(error, isA<LocalTorrentException>());
      expect(attempt.outcome, FreeP2pPlaybackOutcome.metadataTimeout);
      final stage = attempt.stages.last;
      expect(stage['stage'], 'metadata');
      expect(stage['result'], 'timeout');
      expect(stage['engineStats'], isTrue);
      expect(stage['discoveredPeers'], 14);
      expect(stage['connectedPeers'], 2);
    });

    test('a later generic error never overwrites the stage that failed', () {
      final attempt = FreeP2pPlaybackTrace().begin(_torrent());
      attempt.finish(FreeP2pPlaybackOutcome.metadataTimeout);
      attempt.finish(FreeP2pPlaybackOutcome.failed, detail: 'wrapped');
      expect(attempt.outcome, FreeP2pPlaybackOutcome.metadataTimeout);
    });

    test('a resolve without a trace records nothing', () async {
      final trace = FreeP2pPlaybackTrace();
      await http.runWithClient(
        () => service.resolve(_torrent(), warmForPlayback: false),
        () => _engine(),
      );
      await http.runWithClient(service.releaseCurrentStream, () => _engine());
      expect(trace.attempts, isEmpty);
    });
  });

  group('attempt lookup', () {
    test('only an open attempt for the same source is active', () {
      final trace = FreeP2pPlaybackTrace();
      final source = _torrent();
      final attempt = trace.begin(source);
      expect(trace.active(source), same(attempt));
      expect(trace.active(_torrent(seeders: 3)), same(attempt),
          reason: 'same torrent and file routing from a refreshed list');
      expect(trace.active(_torrent(title: 'Trigger.S01E02')), isNull);
      const other = SourceResult(
        provider: 'X',
        title: 'Other',
        resource: 'https://example.test/other.mkv',
        isMagnet: false,
        sortMode: SourceSortMode.quality,
      );
      expect(trace.active(other), isNull);

      expect(trace.attemptFor(source), same(attempt),
          reason: 'the handoff attempt is picked up by playback');
      attempt.stage('route', 'localP2p');
      final retry = trace.attemptFor(source);
      expect(retry, isNot(same(attempt)),
          reason: 'an attempt that already ran is never reused');
      expect(trace.active(source), same(retry));
      retry.finish(FreeP2pPlaybackOutcome.cancelled);

      attempt.finish(FreeP2pPlaybackOutcome.playing);
      expect(trace.active(source), isNull,
          reason: 'a finished attempt never collects later player events');
      final next = trace.attemptFor(source);
      expect(next, isNot(same(attempt)));
      expect(trace.attempts.first, same(next));
    });
  });
}
