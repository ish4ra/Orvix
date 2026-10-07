import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Orvix device telemetry wiring', () {
    test('client reads Android make/model through the existing native layer', () {
      final source =
          File('lib/services/orvix_telemetry_service.dart').readAsStringSync();
      final androidBuild =
          File('tools/configure_android_build.py').readAsStringSync();

      expect(source, contains('orvix/device_info'));
      expect(source, contains("'device_manufacturer'"));
      expect(source, contains("'device_model'"));
      expect(source, contains("'device_type'"));
      expect(androidBuild, contains('"orvix/device_info"'));
      expect(androidBuild, contains('Build.MANUFACTURER'));
      expect(androidBuild, contains('Build.MODEL'));

      // Do not add stable hardware/user identifiers to analytics.
      for (final forbidden in <String>[
        'serial_number',
        'imei',
        'android_id',
        'mac_address',
        'Build.SERIAL',
        'Settings.Secure.ANDROID_ID',
      ]) {
        expect(source.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
        expect(androidBuild.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
      }
    });

    test('backend stores device fields and dashboard exposes a device column', () {
      final migration = File(
        'supabase/migrations/20261007193000_add_analytics_device_info.sql',
      ).readAsStringSync();
      final telemetry =
          File('supabase/functions/orvix-telemetry/index.ts').readAsStringSync();
      final admin =
          File('supabase/functions/orvix-admin/index.ts').readAsStringSync();

      expect(migration, contains('device_manufacturer'));
      expect(migration, contains('device_model'));
      expect(migration, contains('device_type'));
      expect(telemetry, contains('device_manufacturer'));
      expect(telemetry, contains('device_model'));
      expect(telemetry, contains('device_type'));
      expect(admin, contains('friendlyDeviceName'));
      expect(admin, contains('<th>Device</th>'));
    });

    test('friendly mappings cover the requested examples', () {
      final admin =
          File('supabase/functions/orvix-admin/index.ts').readAsStringSync();

      expect(admin, contains('SM-S928B'));
      expect(admin, contains('Galaxy S24 Ultra'));
      expect(admin, contains('MIBOX'));
      expect(admin, contains('Xiaomi Mi Box'));
    });
  });
}
