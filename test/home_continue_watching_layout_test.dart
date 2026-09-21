import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Continue Watching keeps the Nuvio-style wide information-card layout', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();

    expect(home, contains('class _ContinueWideCard'));
    expect(home, contains('final image = item.poster ?? item.background'));
    expect(home, contains('width: 400'));
    expect(home, contains('height: 160'));
    expect(home, contains('imageWidth: 104'));
    expect(home, contains('width: 280'));
    expect(home, contains('height: 120'));
    expect(home, contains('imageWidth: 82'));
    expect(home, contains("'Up Next'"));
    expect(home, contains('% watched'));
    expect(home, isNot(contains('class _TvContinueCard')));
    expect(home, isNot(contains('class _DesktopContinueCard')));
  });
}
