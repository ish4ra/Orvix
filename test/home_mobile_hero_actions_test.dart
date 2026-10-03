import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Home hero rotates through a shuffled candidate pool', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(home, contains('Timer.periodic('));
    expect(home, contains('const Duration(seconds: 15)'));
    expect(home, contains('heroCandidates.shuffle(Random())'));
    expect(home, contains('final hero = data.heroAt(_heroIndex)'));
  });

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
    expect(hero, contains("child: Text('View & Play')"));
    expect(hero, contains('if (onCustomize != null)'));
    expect(hero, contains('const SizedBox(width: 10)'));
    expect(hero, contains("child: Text('Customize Home')"));
    expect(hero, contains('Expanded('));
    expect(hero, contains('FittedBox('));
    expect(hero, contains('visualDensity: VisualDensity.compact'));
    expect(hero, contains('tv ? 28 : (mobile ? 24 : 40)'));
  });
}
