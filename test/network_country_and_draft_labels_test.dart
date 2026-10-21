import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/orvix_admin_source.dart';

void main() {
  test('telemetry refreshes network country instead of pinning the first value', () {
    final source =
        File('supabase/functions/orvix-telemetry/index.ts').readAsStringSync();

    expect(source, contains('resolvedCountryCode'));
    expect(
      source,
      contains('resolvedCountryCode ?? existing.data?.country_code ?? null'),
    );
  });

  test('owner console labels country as network country and draft releases clearly', () {
    final source = orvixAdminSource();

    expect(source, contains('Network country'));
    expect(source, contains('Network countries'));
    expect(source, contains('Draft / Private'));
    expect(source, contains('row.draft'));
  });
}
