import 'package:flutter_test/flutter_test.dart';

import 'support/orvix_admin_source.dart';

void main() {
  test('release analytics expose platform and asset download breakdowns', () {
    final admin = orvixAdminSource();

    expect(admin, contains('classifyReleaseAsset'));
    expect(admin, contains('downloads_by_platform'));
    expect(admin, contains('"Android Mobile"'));
    expect(admin, contains('"Android TV"'));
    expect(admin, contains('"Windows"'));
    expect(admin, contains('"macOS"'));
    expect(admin, contains('asset_platform'));
  });
}
