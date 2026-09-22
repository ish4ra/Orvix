import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active library membership uses the same lime selected language as season tabs', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('_desktopSecondaryButtonStyle(\n                            selected: _inLibrary'));
    expect(details, contains('_tvGlowButtonStyle(\n                                      selected: _inLibrary'));
    expect(details, contains('backgroundColor: const Color(0xFFB9FF45)'));
    expect(details, contains('selected ? Colors.black : Colors.white'));
  });
}
