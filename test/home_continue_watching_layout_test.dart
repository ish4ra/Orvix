import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android mobile and TV reuse the Windows landscape Continue Watching card', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();

    expect(home, contains('class _ContinueLandscapeCard'));
    expect(home, contains('final image = widget.preferEpisodeThumbnail'));
    expect(home, contains('preferEpisodeThumbnail: false'));
    expect(home, contains('entry.item.background'));
    expect(home, contains('entry.item.poster'));
    expect(home, contains('width: 292'));
    expect(home, contains('height: 160'));
    expect(home, contains('width: 330'));
    expect(home, contains('height: 178'));
    expect(home, contains('LinearProgressIndicator'));
    expect(home, contains("'Resume'"));
    expect(home, isNot(contains('class _TvContinueCard')));
    expect(home, isNot(contains('class _DesktopContinueCard')));
  });
}
