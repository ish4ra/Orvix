import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android mobile keeps Customize Home aligned with View & Play', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();

    expect(
      home,
      contains(
        'onCustomize: PlatformProfile.isAndroidMobile\n'
        '                      ? _customizeHome\n'
        '                      : null',
      ),
    );
    expect(home, contains('if (!PlatformProfile.isAndroidMobile)'));
    expect(home, contains('final mobile = PlatformProfile.isAndroidMobile;'));

    final heroStart = home.indexOf('class _Hero extends StatelessWidget');
    final heroEnd = home.indexOf('class _ContinueRail', heroStart);
    final hero = home.substring(heroStart, heroEnd);

    expect(hero, contains('Row('));
    expect(hero, contains("label: const Text('View & Play')"));
    expect(hero, contains('if (onCustomize != null)'));
    expect(hero, contains('const Spacer()'));
    expect(hero, contains("label: const Text('Customize Home')"));
    expect(hero, contains('tv ? 28 : (mobile ? 24 : 40)'));
  });
}
