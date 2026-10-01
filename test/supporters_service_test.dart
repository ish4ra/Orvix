import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/supporters_service.dart';

void main() {
  group('supporter models', () {
    test('maps private or missing display names safely', () {
      final supporter = OrvixSupporter.fromJson({
        'display_name': '  ',
        'provider': 'kofi',
        'support_type': 'Member',
        'tier': 'Bronze',
        'supporter_since': '2026-09-30T00:00:00Z',
      });
      expect(supporter.name, 'Anonymous supporter');
      expect(supporter.providerLabel, 'Ko-fi');
      expect(supporter.supportType, 'Member');
      expect(supporter.tier, 'Bronze');
      expect(supporter.since.toUtc(), DateTime.utc(2026, 9, 30));
    });

    test('maps GitHub contributors', () {
      final contributor = OrvixContributor.fromJson({
        'login': 'contributor',
        'contributions': 7,
        'avatar_url': 'https://example.com/avatar.png',
      });
      expect(contributor.login, 'contributor');
      expect(contributor.contributions, 7);
      expect(contributor.avatarUrl, 'https://example.com/avatar.png');
    });
  });
}
