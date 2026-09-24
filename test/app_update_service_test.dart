import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';

void main() {
  test('prerelease update ordering handles Orvix beta tags', () {
    expect(
      AppUpdateService.isVersionNewer(
        'v0.7.5-beta.17',
        '0.7.5-beta.16',
      ),
      isTrue,
    );
    expect(
      AppUpdateService.isVersionNewer(
        'v0.7.5-beta.16',
        '0.7.5-beta.17',
      ),
      isFalse,
    );
    expect(
      AppUpdateService.isVersionNewer(
        'v0.7.5',
        '0.7.5-beta.99',
      ),
      isTrue,
    );
    expect(
      AppUpdateService.isVersionNewer(
        'v0.8.0-alpha.1',
        '0.7.9',
      ),
      isTrue,
    );
  });

  test('beta decade boundaries never break update ordering', () {
    for (final pair in <(String, String)>[
      ('v0.7.6-beta.10', '0.7.6-beta.9'),
      ('v0.7.6-beta.20', '0.7.6-beta.19'),
      ('v0.7.6-beta.30', '0.7.6-beta.29'),
      ('v0.7.6-beta.40', '0.7.6-beta.39'),
      ('v0.7.6-beta.50', '0.7.6-beta.49'),
    ]) {
      expect(
        AppUpdateService.isVersionNewer(pair.$1, pair.$2),
        isTrue,
        reason: '${pair.$1} must be newer than ${pair.$2}',
      );
      expect(
        AppUpdateService.isVersionNewer(pair.$2, pair.$1),
        isFalse,
        reason: '${pair.$2} must not be newer than ${pair.$1}',
      );
    }
  });
}
