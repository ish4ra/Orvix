import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';

void main() {
  test('rich metadata keeps logo cast portraits and season posters', () {
    final item = MediaItem.fromCinemeta(
      {
        'id': 'tt0903747',
        'name': 'Breaking Bad',
        'logo': 'https://example.invalid/logo.png',
        'poster': 'https://example.invalid/poster.jpg',
        'background': 'https://example.invalid/backdrop.jpg',
        'app_extras': {
          'cast': [
            {
              'name': 'Actor One',
              'character': 'Character One',
              'photo': 'https://example.invalid/person.jpg',
            },
          ],
          'seasonPosters': [
            'https://example.invalid/s1.jpg',
            'https://example.invalid/s2.jpg',
          ],
        },
      },
      kind: MediaKind.series,
    );

    expect(item.logo, 'https://example.invalid/logo.png');
    expect(item.cast, ['Actor One']);
    expect(item.castMembers, hasLength(1));
    expect(item.castMembers.first.character, 'Character One');
    expect(item.castMembers.first.photo, 'https://example.invalid/person.jpg');
    expect(item.seasonPoster(1), 'https://example.invalid/s1.jpg');
    expect(item.seasonPoster(2), 'https://example.invalid/s2.jpg');
    expect(item.seasonPoster(3), isNull);
  });
}
