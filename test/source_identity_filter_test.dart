import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/services/source_provider_service.dart';

void main() {
  final service = SourceProviderService();

  test('rejects same-name series from a conflicting explicit year', () {
    const item = MediaItem(
      id: 'tt0388629',
      kind: MediaKind.series,
      title: 'One Piece',
      year: '1999–',
    );
    const episode = EpisodeItem(
      id: 'tt0388629:1:1',
      season: 1,
      episode: 1,
      title: 'Episode 1',
    );

    expect(
      service.sourceMatchesRequestedMedia(
        item,
        episode,
        'ONE PIECE 2023 S01E01 Romance Dawn 1080p NF WEB-DL',
        null,
      ),
      isFalse,
    );

    expect(
      service.sourceMatchesRequestedMedia(
        item,
        episode,
        '[Anime Time] One Piece (0001-1071+Movies+Specials) [1080p]',
        'One Piece - 001.mkv',
      ),
      isTrue,
    );
  });

  test('rejects an explicit wrong season or episode', () {
    const item = MediaItem(
      id: 'tt0903747',
      kind: MediaKind.series,
      title: 'Breaking Bad',
      year: '2008–2013',
    );
    const episode = EpisodeItem(
      id: 'tt0903747:1:1',
      season: 1,
      episode: 1,
      title: 'Pilot',
    );

    expect(
      service.sourceMatchesRequestedMedia(
        item,
        episode,
        'Breaking.Bad.S02E01.1080p.WEB-DL',
        null,
      ),
      isFalse,
    );
  });
}
