import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Player defaults to aspect-preserving Fit with user resize modes', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(
      player,
      contains(
        'fit: PlatformProfile.isAndroidMobile\n'
        '                        ? BoxFit.contain\n'
        '                        : _resizeMode.boxFit',
      ),
    );
    expect(player, contains('width: double.infinity'));
    expect(player, contains('height: double.infinity'));
    expect(player, isNot(contains('aspectRatio: PlatformProfile.isAndroidMobile')));
    expect(player, contains('_resizeModeMenu()'));
    expect(player, contains('_applyAndroidMobileActiveFrameCrop()'));
    expect(player, contains('detectFromNativePlayer('));
    expect(player, contains("'video-crop'"));
    expect(player, contains('@orvix_autocrop:crop='));
    expect(player, contains('_applyAndroidMobileNativeResize('));
    expect(player, contains("'video-aspect-override'"));
    expect(player, contains("'panscan'"));
    expect(player, contains("PlayerResizeMode.fit => '0.0'"));
    expect(player, contains("PlayerResizeMode.fill => '1.0'"));
    expect(player, contains("PlayerResizeMode.zoom => '0.5'"));
    expect(player, contains('_resizeModeSelectedByUser = true'));
    expect(
      player,
      contains('if (!mounted || _closing || _resizeModeSelectedByUser) return;'),
    );
  });

  test('Mobile source sheet keeps Quick Play beside Sort and preparation inline', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    expect(details, contains('Flexible(child: quickPlayButton(best))'));
    expect(details, contains('Preparing playback…'));
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
