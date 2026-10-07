import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Orvix device telemetry wiring', () {
    test('client sends privacy-safe device make, model and type', () {
      final source =
          File('lib/services/orvix_telemetry_service.dart').readAsStringSync();

      expect(source, contains("package:device_info_plus/device_info_plus.dart"));
      expect(source, contains("'device_manufacturer'"));
      expect(source, contains("'device_model'"));
      expect(source, contains("'device_type'"));

      // Do not add stable hardware/user identifiers to analytics.
      expect(source, isNot(contains("'serial_number'")));
      expect(source, isNot(contains("'imei'")));
      expect(source, isNot(contains("'android_id'")));
      expect(source, isNot(contains("'mac_address'")));
      expect(source, isNot(contains("'computer_name'")));
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
