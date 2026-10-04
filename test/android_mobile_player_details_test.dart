import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Mobile defaults to native MPV aspect ratio in Fit mode', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(player, contains('fit: _resizeMode.boxFit'));
    expect(player, contains('width: double.infinity'));
    expect(player, contains('height: double.infinity'));
    expect(player, contains('_restoreAndroidMobileNativeAspectRatio()'));
    expect(player, contains("'video-aspect-override': 'no'"));
    expect(player, contains("'video-aspect-method': 'container'"));
    expect(player, contains("'keepaspect': 'yes'"));
    expect(player, contains("'video-crop': ''"));
    expect(player, contains("'video-zoom': '0'"));
    expect(player, contains("'panscan': '0'"));
    expect(player, isNot(contains('_applyAndroidMobileActiveFrameCrop')));
    expect(player, isNot(contains('VideoBlackBarCropService')));
    expect(player, isNot(contains('AndroidVideoSurfaceService')));
    expect(player, isNot(contains("'file-local-options/video-crop'")));
    expect(player, isNot(contains('@orvix_autocrop')));
    expect(player, isNot(contains('_mobileActiveAspectRatio')));
    expect(
      player,
      isNot(contains('aspectRatio: PlatformProfile.isAndroidMobile')),
    );
    expect(player, contains('_resizeModeMenu()'));
    expect(player, contains('_resizeModeSelectedByUser = true'));
    expect(
      player,
      contains('setState(() => _resizeMode = PlayerResizeMode.fit);'),
    );
    expect(
      player,
      contains('if (!PlatformProfile.isAndroidMobile) {'),
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
