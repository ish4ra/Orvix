import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/source_provider_service.dart';

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
