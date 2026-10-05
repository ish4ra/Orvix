import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SourceResult torrent({
  required String name,
  required int seeders,
  int? peers,
  required int sizeBytes,
  String quality = '1080P',
  bool exactFile = false,
}) {
  return SourceResult(
    provider: 'Torrentio',
    title: name,
    resource:
        'magnet:?xt=urn:btih:${name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: quality,
    releaseQuality: 'WEB-DL',
    seeders: seeders,
    peers: peers,
    sizeBytes: sizeBytes,
    fileNameHint: exactFile ? name : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Free prefers efficient viable source over huge highly seeded source', () {
    final service = SourceProviderService();
    final efficient = torrent(
      name: 'Prison.Break.S01E01.1080p.WEB-DL.x264',
      seeders: 12,
      sizeBytes: 620 * 1024 * 1024,
    );
    final huge = torrent(
      name: 'Prison.Break.S01E01.2160p.REMUX',
      seeders: 120,
      sizeBytes: 9 * 1024 * 1024 * 1024,
      quality: '2160P',
    );

    final ranked = service.sortForFreeStreaming([huge, efficient]);

    expect(ranked.first, same(efficient));
  });

  test('Free prefers a much healthier 720p swarm over a weaker 1080p swarm', () {
    final service = SourceProviderService();
    final weaker1080 = torrent(
      name: 'Prison.Break.S01E01.1080p.WEB-DL.x264',
      seeders: 9,
      sizeBytes: 650 * 1024 * 1024,
    );
    final healthy720 = torrent(
      name: 'Prison.Break.S01E01.720p.WEB-DL.x264',
      seeders: 55,
      sizeBytes: 720 * 1024 * 1024,
      quality: '720P',
    );

    final ranked = service.sortForFreeStreaming([weaker1080, healthy720]);

    expect(ranked.first, same(healthy720));
  });

  test('Free prefers practical healthy 720p over a heavy 1080p torrent', () {
    final service = SourceProviderService();
    final heavy1080 = torrent(
      name: 'The.Dark.Knight.2008.1080p.BluRay.x264.AAC',
      seeders: 2000,
      sizeBytes: 8 * 1024 * 1024 * 1024,
      exactFile: true,
    );
    final practical720 = torrent(
      name: 'The.Dark.Knight.2008.720p.BluRay.x264.AAC',
      seeders: 120,
      sizeBytes: 1100 * 1024 * 1024,
      quality: '720P',
      exactFile: true,
    );

    final ranked =
        service.sortForFreeStreaming([heavy1080, practical720]);

    expect(ranked.first, same(practical720));
  });

  test('Free recent success can break a healthy-swarm tie without hiding current health', () async {
    final service = SourceProviderService();
    final knownGood = torrent(
      name: 'Known.Good.720p.x264',
      seeders: 12,
      sizeBytes: 700 * 1024 * 1024,
      quality: '720P',
    );
    final healthier = torrent(
      name: 'Healthier.1080p.x264',
      seeders: 55,
      sizeBytes: 700 * 1024 * 1024,
    );

    await service.recordPlaybackOutcome(knownGood, success: true);
    final ranked = service.sortForFreeStreaming([healthier, knownGood]);

    // Both swarms are currently viable. A recent successful startup is useful
    // evidence for Free P2P and may outrank the larger reported swarm.
    expect(ranked.first, same(knownGood));
    expect(service.assessFreePlayback(knownGood).label, isNot('WORKED BEFORE'));
  });

  test('Free ignores resolution when playability signals are otherwise equal', () {
    final service = SourceProviderService();
    final low = torrent(
      name: 'A.Portable.480p.x264.AAC',
      seeders: 25,
      sizeBytes: 700 * 1024 * 1024,
      quality: '480P',
    );
    final high = torrent(
      name: 'Z.Portable.1080p.x264.AAC',
      seeders: 25,
      sizeBytes: 700 * 1024 * 1024,
      quality: '1080P',
    );

    final ranked = service.sortForFreeStreaming([high, low]);

    // Resolution contributes no Free-P2P score. The deterministic title
    // tie-break decides this pair, proving 1080p gets no priority bonus.
    expect(ranked.first, same(low));
  });

  test('Free demotes an exact release that failed recently', () async {
    final service = SourceProviderService();
    final failed = torrent(
      name: 'Failed.1080p',
      seeders: 80,
      sizeBytes: 650 * 1024 * 1024,
    );
    final alternative = torrent(
      name: 'Alternative.720p',
      seeders: 25,
      sizeBytes: 700 * 1024 * 1024,
      quality: '720P',
    );

    await service.recordPlaybackOutcome(
      failed,
      success: false,
      reason: 'stream timed out • speed: 90 KB/s',
    );
    final ranked = service.sortForFreeStreaming([failed, alternative]);

    expect(ranked.first, same(alternative));
    expect(service.assessFreePlayback(failed).label, 'SLOW / STALLED');
  });

  test('Free does not put a zero-seed small file above a viable swarm', () {
    final service = SourceProviderService();
    final dead = torrent(
      name: 'Dead.Small.Source',
      seeders: 0,
      sizeBytes: 600 * 1024 * 1024,
    );
    final viable = torrent(
      name: 'Viable.Source',
      seeders: 4,
      sizeBytes: 2 * 1024 * 1024 * 1024,
    );

    final ranked = service.sortForFreeStreaming([dead, viable]);

    expect(ranked.first, same(viable));
  });

  test('Free keeps provider peers separate from complete seeders', () {
    final service = SourceProviderService();
    final oneSeed = torrent(
      name: 'One.Real.Seed',
      seeders: 1,
      peers: 0,
      sizeBytes: 900 * 1024 * 1024,
    );
    final peerOnly = torrent(
      name: 'Peer.Only.Swarm',
      seeders: 0,
      peers: 200,
      sizeBytes: 900 * 1024 * 1024,
    );

    final ranked = service.sortForFreeStreaming([peerOnly, oneSeed]);

    // A complete seed is stronger static availability evidence than any raw
    // peer count. Live probing can still promote the peer-only swarm later if
    // it proves that the required pieces are actually available.
    expect(ranked.first, same(oneSeed));
  });

  test('Free still lets a peer-only swarm outrank a completely dead source', () {
    final service = SourceProviderService();
    final dead = torrent(
      name: 'No.Swarm',
      seeders: 0,
      peers: 0,
      sizeBytes: 900 * 1024 * 1024,
    );
    final peerOnly = torrent(
      name: 'Peer.Only.But.Active',
      seeders: 0,
      peers: 8,
      sizeBytes: 900 * 1024 * 1024,
    );

    final ranked = service.sortForFreeStreaming([dead, peerOnly]);

    expect(ranked.first, same(peerOnly));
  });

  test('Seeder parser no longer aliases provider peer fields to seeds', () {
    final source =
        File('lib/services/source_provider_service.dart').readAsStringSync();
    final start = source.indexOf('int? _guessSeeders');
    final end = source.indexOf('int? _guessPeers', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final seederParser = source.substring(start, end);

    expect(seederParser, isNot(contains("raw['peers']")));
    expect(seederParser, isNot(contains("hints['peers']")));
    expect(seederParser, isNot(contains(r'\bpeers?')));
  });

}
