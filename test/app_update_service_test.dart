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
}
