import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android mobile reuses the Windows landscape Continue Watching card', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();

    expect(home, contains('class _ContinueLandscapeCard'));
    // Android TV has its own Continue Watching row (tv_screens_test.dart).
    expect(home, contains('episode?.thumbnail ?? entry.item.background'));
    expect(home, contains('required this.onResume'));
    expect(home, contains('entry.item.background'));
    expect(home, contains('entry.item.poster'));
    expect(home, contains('width: 292'));
    expect(home, contains('height: 160'));
    expect(home, contains('width: 330'));
    expect(home, contains('LinearProgressIndicator'));
    expect(home, contains("'Resume'"));
    expect(home, isNot(contains('class _TvContinueCard')));
    expect(home, isNot(contains('class _DesktopContinueCard')));
  });
}
