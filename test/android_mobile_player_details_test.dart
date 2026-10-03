import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Player defaults to aspect-preserving Fit with user resize modes', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(player, contains('fit: _resizeMode.boxFit'));
    expect(player, contains('_resizeModeMenu()'));
    expect(player, contains('_resizeModeSelectedByUser = true'));
    expect(
      player,
      contains('if (!mounted || _closing || _resizeModeSelectedByUser) return;'),
    );
  });

  test('Mobile season controls stay compact and Play uses Orvix lime family', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('height: compact ? 46 : 58'));
    expect(details, contains('height: 38'));
    expect(details, contains('minWidth: 92'));
    expect(details, contains('const selectedLime = Color(0xFF9FE52E)'));
    expect(details, contains('? selectedLime'));
    expect(details, contains('compact && PlatformProfile.isAndroidMobile'));
    expect(details, contains('backgroundColor: const Color(0xFFCBFF75)'));
  });
}
