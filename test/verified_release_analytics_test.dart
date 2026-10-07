import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('owner analytics exposes verified device counts by version', () {
    final admin =
        File('supabase/functions/orvix-admin/index.ts').readAsStringSync();

    expect(admin, contains('loadAllVersionSessions'));
    expect(admin, contains('buildVerifiedVersionStats'));
    expect(admin, contains('verified_versions'));
    expect(admin, contains('unique_devices'));
    expect(admin, contains('devices_by_platform'));
    expect(admin, contains('"Android Mobile"'));
    expect(admin, contains('"Android TV"'));
    expect(admin, contains('"Windows"'));
    expect(admin, contains('"macOS"'));
  });
}
