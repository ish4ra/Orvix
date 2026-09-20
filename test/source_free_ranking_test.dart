import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

SourceResult torrent({
  required String name,
  required int seeders,
  required int sizeBytes,
  String quality = '1080P',
}) {
  return SourceResult(
    provider: 'Torrentio',
    title: name,
    resource: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
    isMagnet: true,
    sortMode: SourceSortMode.seeders,
    quality: quality,
    releaseQuality: 'WEB-DL',
    seeders: seeders,
    sizeBytes: sizeBytes,
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

  test('Free learns from a recent successful release on this device', () async {
    final service = SourceProviderService();
    final knownGood = torrent(
      name: 'Known.Good.720p',
      seeders: 12,
      sizeBytes: 700 * 1024 * 1024,
      quality: '720P',
    );
    final unknown = torrent(
      name: 'Unknown.1080p',
      seeders: 55,
      sizeBytes: 700 * 1024 * 1024,
    );

    await service.recordPlaybackOutcome(knownGood, success: true);
    final ranked = service.sortForFreeStreaming([unknown, knownGood]);

    expect(ranked.first, same(knownGood));
    expect(service.assessFreePlayback(knownGood).label, 'WORKED BEFORE');
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
}
