import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/source_ranking_diagnostics.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Windows and Android must order the same normalized provider results the
// same way under the same preferences. Real differences (provider answers,
// saved preferences, local history, live evidence) must be reported as
// such, never confused with a sorting defect.

const _mb = 1024 * 1024;

SourceResult _torrent(
  String hash, {
  String provider = 'Torrentio',
  String title = 'Breaking.Bad.S01E01.1080p.BluRay.x264',
  String? quality = '1080P',
  int? seeders = 50,
  int? peers,
  int sizeMb = 1400,
  int? fileIdx = 0,
  int? position,
}) =>
    SourceResult(
      provider: provider,
      title: '👥 ${seeders ?? '—'} seeders\n$title',
      resource: 'magnet:?xt=urn:btih:${hash.padRight(40, '0')}',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
      quality: quality,
      seeders: seeders,
      peers: peers,
      sizeBytes: sizeMb * _mb,
      torrentFileIndex: fileIdx,
      providerPosition: position,
    );

/// A realistic mixed answer with several exact ties: the same release from
/// two providers, two packs that only differ by file index, and equal
/// seeders/sizes.
List<SourceResult> _answer() => [
      _torrent('aa', seeders: 120, position: 0),
      _torrent('aa', provider: 'MediaFusion', seeders: 120, position: 0),
      _torrent('bb', title: 'Breaking.Bad.S01.1080p.WEB.x265', fileIdx: 1,
          seeders: 80, position: 1),
      _torrent('bb', title: 'Breaking.Bad.S01.1080p.WEB.x265', fileIdx: 2,
          seeders: 80, position: 2),
      _torrent('cc', title: 'Breaking.Bad.S01E01.720p.x264', quality: '720P',
          seeders: 80, sizeMb: 700, position: 3),
      _torrent('dd', title: 'Breaking.Bad.S01E01.2160p.HDR.x265',
          quality: '2160P', seeders: 300, sizeMb: 9000, position: 4),
      _torrent('ee', title: 'Breaking.Bad.S01E01.1080p.BluRay.x264',
          seeders: 50, position: 5),
      _torrent('ff', title: 'Breaking.Bad.S01E01.1080p.BluRay.x264',
          seeders: 50, position: 6),
      SourceResult(
        provider: 'Direct',
        title: 'Breaking.Bad.S01E01.1080p.mp4',
        resource: 'https://cdn.example.org/v/abc123?token=secret-value',
        isMagnet: false,
        sortMode: SourceSortMode.seeders,
        quality: '1080P',
        sizeBytes: 1300 * _mb,
      ),
    ];

List<String> _ids(List<SourceResult> results) =>
    results.map(SourceRankingSnapshot.identityOf).toList();

/// Deterministic shuffles: reversed, rotated and interleaved inputs.
List<List<SourceResult>> _permutations(List<SourceResult> base) => [
      base,
      base.reversed.toList(),
      [...base.skip(3), ...base.take(3)],
      [
        for (var i = 0; i < base.length; i += 2) base[i],
        for (var i = 1; i < base.length; i += 2) base[i],
      ],
    ];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('identical inputs give one order on every device', () {
    test('Free P2P order is independent of provider merge order', () {
      final sources = SourceProviderService();
      final expected = _ids(sources.sortForFreeStreaming(_answer()));
      for (final input in _permutations(_answer())) {
        expect(_ids(sources.sortForFreeStreaming(input)), expected);
      }
      // Live ranking without evidence is the same static order.
      for (final input in _permutations(_answer())) {
        expect(_ids(FreeP2pLiveProbeService().rank(input, sources)), expected);
      }
    });

    test('Source Priority order is independent of provider merge order', () {
      final sources = SourceProviderService();
      for (final priority in [
        SourceProviderService.defaultPriority,
        SourceProviderService.defaultPriority.reversed.toList(),
      ]) {
        final expected = _ids(sources.sortResults(_answer(), priority));
        for (final input in _permutations(_answer())) {
          expect(_ids(sources.sortResults(input, priority)), expected);
        }
      }
    });

    test('Smooth order is independent of provider merge order', () {
      final sources = SourceProviderService();
      final expected = _ids(sources.sortForSmoothPlayback(_answer()));
      for (final input in _permutations(_answer())) {
        expect(_ids(sources.sortForSmoothPlayback(input)), expected);
      }
    });

    test('exact ties are broken by provider, then source, then file index',
        () {
      final a = _torrent('aa');
      final b = _torrent('aa', provider: 'MediaFusion');
      final c = _torrent('bb');
      final d = _torrent('bb', fileIdx: 1);
      expect(SourceProviderService.compareSourceIdentity(b, a), lessThan(0));
      expect(SourceProviderService.compareSourceIdentity(a, c), lessThan(0));
      expect(SourceProviderService.compareSourceIdentity(c, d), lessThan(0));
      expect(SourceProviderService.compareSourceIdentity(a, a), 0);
    });

    test('a Windows and an Android snapshot of the same inputs agree', () {
      final windows = SourceProviderService();
      final android = SourceProviderService();
      SourceRankingSnapshot snap(
        SourceProviderService sources,
        List<SourceResult> input,
        String platform,
      ) {
        final ordered = sources.sortForFreeStreaming(input);
        return SourceRankingSnapshot.capture(
          sources: sources,
          target: 'series:tt0903747:1:1',
          resolved: sources.sortResults(
              input, SourceProviderService.defaultPriority),
          displayed: ordered,
          mode: 'freeP2p',
          priority: SourceProviderService.defaultPriority,
          cloudConnected: false,
          platform: platform,
        );
      }

      final a = snap(windows, _answer(), 'windows');
      final b = snap(android, _answer().reversed.toList(), 'androidMobile');
      expect(a.displayedOrder, b.displayedOrder);
      expect(SourceRankingComparison.compare(a, b), isEmpty);
    });
  });

  group('real differences are reported for what they are', () {
    SourceRankingSnapshot snapshot(
      SourceProviderService sources,
      List<SourceResult> input, {
      String platform = 'windows',
      String mode = 'freeP2p',
      List<SourceSortCriterion> priority = SourceProviderService.defaultPriority,
      bool cloud = false,
      FreeP2pLiveProbeService? live,
      bool Function(SourceResult)? pinned,
      List<SourceResult>? displayed,
    }) =>
        SourceRankingSnapshot.capture(
          sources: sources,
          target: 'series:tt0903747:1:1',
          resolved: sources.sortResults(input, priority),
          displayed: displayed ??
              (mode == 'freeP2p'
                  ? (live ?? FreeP2pLiveProbeService()).rank(input, sources)
                  : sources.sortResults(input, priority)),
          mode: mode,
          priority: priority,
          cloudConnected: cloud,
          isPinned: pinned,
          liveProbe: live,
          platform: platform,
        );

    List<RankingDifferenceKind> kinds(
      SourceRankingSnapshot a,
      SourceRankingSnapshot b,
    ) =>
        SourceRankingComparison.compare(a, b).map((d) => d.kind).toList();

    test('a different provider answer', () {
      final sources = SourceProviderService();
      final a = snapshot(sources, _answer());
      final fewer = _answer()..removeAt(4);
      final b = snapshot(sources, fewer, platform: 'androidMobile');
      expect(kinds(a, b), [RankingDifferenceKind.providerResponse]);

      final reseeded = _answer();
      reseeded[0] = _torrent('aa', seeders: 7, position: 0);
      expect(kinds(a, snapshot(sources, reseeded)),
          [RankingDifferenceKind.providerResponse]);
    });

    test('a cloud/debrid connection or another Source Priority', () {
      final sources = SourceProviderService();
      final windows = snapshot(sources, _answer(),
          mode: 'priority', cloud: true);
      final android = snapshot(sources, _answer(), platform: 'androidMobile');
      expect(kinds(windows, android), [RankingDifferenceKind.preferences]);

      final custom = snapshot(sources, _answer(),
          mode: 'priority',
          priority: SourceProviderService.defaultPriority.reversed.toList());
      final standard = snapshot(sources, _answer(), mode: 'priority');
      expect(kinds(custom, standard), [RankingDifferenceKind.preferences]);
    });

    test('a pin on one device only', () {
      final sources = SourceProviderService();
      final a = snapshot(sources, _answer(),
          pinned: (s) => s.resource.contains('ee'));
      final b = snapshot(sources, _answer(), platform: 'androidTv');
      expect(kinds(a, b), [RankingDifferenceKind.pinned]);
    });

    test('local playback history on one device only', () async {
      final windows = SourceProviderService();
      final android = SourceProviderService();
      await windows.recordPlaybackOutcome(_answer()[6], success: true);
      final a = snapshot(windows, _answer());
      final b = snapshot(android, _answer(), platform: 'androidMobile');
      expect(kinds(a, b), [RankingDifferenceKind.playbackHistory]);
    });

    test('live-check evidence on one device only', () async {
      final sources = SourceProviderService();
      final live = FreeP2pLiveProbeService(
        probeRunner: (_) async => const LocalTorrentProbeResult(
          playableNow: true,
          bytesReceived: 2 * _mb,
          elapsed: Duration(seconds: 1),
          firstByteLatency: Duration(milliseconds: 300),
          peers: 12,
          connections: 12,
          downloadSpeedBytesPerSecond: 4.0 * _mb,
          sampleWindowsPassed: 2,
        ),
      );
      await live.probeTopCandidates(_answer(), sources);
      final windows = snapshot(sources, _answer(), live: live);
      final android = snapshot(sources, _answer(), platform: 'androidMobile');
      expect(kinds(windows, android), [RankingDifferenceKind.liveEvidence]);
    });

    test('only identical inputs in a different order are a defect', () {
      final sources = SourceProviderService();
      final a = snapshot(sources, _answer());
      final b = snapshot(
        sources,
        _answer(),
        platform: 'androidMobile',
        displayed: sources.sortForFreeStreaming(_answer()).reversed.toList(),
      );
      expect(kinds(a, b), [RankingDifferenceKind.orderingDefect]);
    });
  });

  group('diagnostic report', () {
    test('shows identity, positions and factors, never a secret', () async {
      final sources = SourceProviderService();
      await sources.recordPlaybackOutcome(
        _answer()[4],
        success: false,
        reason: 'Local torrent engine returned HTTP 500.',
      );
      final snapshot = SourceRankingSnapshot.capture(
        sources: sources,
        target: 'series:tt0903747:1:1',
        resolved: _answer(),
        displayed: sources.sortForFreeStreaming(_answer()).take(5).toList(),
        mode: 'freeP2p',
        priority: SourceProviderService.defaultPriority,
        cloudConnected: false,
        resultLimit: 5,
        isPinned: (s) => s.resource.contains('ee'),
        platform: 'androidMobile',
      );
      final report = snapshot.toReport();
      final rows = report
          .split('\n')
          .skip(2)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      final bb2 = rows.firstWhere((r) => r['id'] == 'bt:${'bb'.padRight(40, '0')}|2');
      expect(bb2['fileIdx'], 2);
      expect(bb2['providerPos'], 2);
      expect(bb2['providerSeeders'], 80);
      expect(bb2['sizeMb'], 1400);
      expect(bb2['factors'], containsPair('exactFile', 1));
      expect(rows.where((r) => r['pinned'] == true), hasLength(1));
      expect(rows.firstWhere((r) => (r['id'] as String).startsWith('bt:cc'))
          ['history'], -2);
      expect(rows.where((r) => r['shownPos'] == null), hasLength(4),
          reason: 'rows beyond the result limit are listed as not shown');

      // A direct link is identified without exposing its path or token.
      expect(report, isNot(contains('secret-value')));
      expect(report, isNot(contains('/v/abc123')));
      expect(report, contains('url:cdn.example.org#'));
      expect(report, isNot(contains('magnet:')));
      expect(report, isNot(contains('tracker')));
    });
  });

  group('slow starts never become failure history', () {
    test('slow-start reasons are not recorded as failures', () async {
      final sources = SourceProviderService();
      final source = _answer()[0];
      for (final reason in const [
        'The stream is taking longer than expected to start. Orvix will '
            'recover automatically if media begins playing.',
        'ExoPlayer could not initialize this stream within 35 seconds.',
        'Playback engine: tcp: ffurl_read returned 0xffffff92',
        'The local torrent engine timed out while resolving magnet metadata: '
            'no peers were found for this torrent.',
      ]) {
        await sources.recordPlaybackOutcome(
          source,
          success: false,
          reason: reason,
        );
        expect(sources.playbackHistoryRank(source), 0, reason: reason);
      }
      expect(sources.assessFreePlayback(source).label,
          isNot(contains('FAILED')));
    });

    test('a slow-start failure saved by an earlier build no longer demotes',
        () async {
      final hash = 'aa'.padRight(40, '0');
      SharedPreferences.setMockInitialValues({
        'orvix_source_playback_history_v1': jsonEncode({
          'bt:$hash:0': {
            'successes': 0,
            'failures': 1,
            'lastFailure': DateTime.now().toIso8601String(),
            'lastFailureReason':
                'The stream is taking longer than expected to start. Orvix '
                    'will recover automatically if media begins playing.',
          },
        }),
      });
      final sources = SourceProviderService();
      final results = [_answer()[0], _answer()[6]];
      // resolve() loads saved history; emulate with a no-provider resolve.
      await sources.recordPlaybackOutcome(_answer()[7], success: true);
      expect(sources.playbackHistoryRank(results[0]), 0);
      expect(_ids(sources.sortForFreeStreaming(results)).first,
          SourceRankingSnapshot.identityOf(results[0]),
          reason: 'more seeders first; no stale penalty');
    });

    test('a genuine failure still demotes the release', () async {
      final sources = SourceProviderService();
      final source = _answer()[0];
      await sources.recordPlaybackOutcome(
        source,
        success: false,
        reason: 'Playback engine: Failed to recognize file format.',
      );
      expect(sources.playbackHistoryRank(source), -2);
    });
  });

  group('review follow-ups', () {
    test('device log rows carry no release name and only a short hash',
        () {
      final sources = SourceProviderService();
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          printed.add(message ?? '');
      try {
        SourceRankingSnapshot.record(SourceRankingSnapshot.capture(
          sources: sources,
          target: 'series:tt0903747:1:1',
          resolved: _answer(),
          displayed: sources.sortForFreeStreaming(_answer()),
          mode: 'freeP2p',
          priority: SourceProviderService.defaultPriority,
          cloudConnected: false,
          platform: 'androidMobile',
        ));
      } finally {
        debugPrint = previous;
      }
      final log = printed.join('\n');
      expect(log, isNot(contains('Breaking.Bad')));
      expect(log, isNot(contains('aa'.padRight(40, '0'))));
      expect(log, contains('"id":"bt:aa000000|0"'));
      expect(SourceRankingSnapshot.latest!.toReport(),
          contains('Breaking.Bad'),
          reason: 'the explicit report keeps the full rows');
    });

    test('the same torrent from another provider is its own row', () {
      final sources = SourceProviderService();
      SourceRankingSnapshot snap(List<SourceResult> input) =>
          SourceRankingSnapshot.capture(
            sources: sources,
            target: 'series:tt0903747:1:1',
            resolved: sources.sortResults(
                input, SourceProviderService.defaultPriority),
            displayed: sources.sortForFreeStreaming(input),
            mode: 'freeP2p',
            priority: SourceProviderService.defaultPriority,
            cloudConnected: false,
          );
      final withoutMediaFusion = _answer()..removeAt(1);
      final differences =
          SourceRankingComparison.compare(snap(_answer()), snap(withoutMediaFusion));
      expect(differences.single.kind, RankingDifferenceKind.providerResponse);
      expect(differences.single.detail, startsWith('1 source(s) only on'));
    });
  });
}
