import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android mobile playback fills the physical display', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('PlatformProfile.isAndroidMobile'));
    expect(player, contains('? BoxFit.cover'));
    expect(player, contains(': BoxFit.contain'));
  });

  test('Mobile season controls stay compact and Play is visually distinct', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('height: compact ? 46 : 58'));
    expect(details, contains('height: 38'));
    expect(details, contains('minWidth: 92'));
    expect(details, contains('selectedLime'));
    expect(details, contains('compact && PlatformProfile.isAndroidMobile'));
    expect(details, contains('backgroundColor: const Color(0xFFCBFF75)'));
    expect(details, contains('backgroundColor: const Color(0xFF9FE52E)'));
  });
}
