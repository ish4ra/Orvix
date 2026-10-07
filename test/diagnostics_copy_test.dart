import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings explains diagnostics without exposing a scary field list', () {
    final source = File('lib/screens/settings_screen.dart').readAsStringSync();

    expect(source, contains('Diagnostics'));
    expect(
      source,
      contains(
        'Orvix uses limited technical diagnostics to improve reliability, performance, and compatibility across devices.',
      ),
    );
    expect(
      source,
      contains(
        'Raw IP addresses, precise location, and unique hardware identifiers are not stored.',
      ),
    );
  });
}
