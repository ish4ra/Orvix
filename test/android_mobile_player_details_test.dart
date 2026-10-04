import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Mobile crops encoded bars through MPV and keeps Fit geometry synced', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(player, contains('fit: _resizeMode.boxFit'));
    expect(player, contains('width: double.infinity'));
    expect(player, contains('height: double.infinity'));
    expect(player, contains('_restoreAndroidMobileNativeAspectRatio()'));
    expect(player, contains('_applyAndroidMobileAutoCrop()'));
    expect(player, contains('VideoBlackBarCropService.detectFromNativePlayer'));
    expect(player, contains("'vf',"));
    expect(player, contains("'add',"));
    expect(player, contains('@orvix_autocrop:crop='));
    expect(player, contains('widget.playback.controller.rect.value'));
    expect(player, contains('final params = player.state.videoParams'));
    expect(player, contains("'video-aspect-override': 'no'"));
    expect(player, contains("'video-aspect-method': 'container'"));
    expect(player, contains("'keepaspect': 'yes'"));
    expect(player, contains("'video-crop': ''"));
    expect(player, contains("'video-zoom': '0'"));
    expect(player, contains("'panscan': '0'"));
    expect(player, isNot(contains('AndroidVideoSurfaceService')));
    expect(player, isNot(contains('file-local-options/video-crop')));
    expect(player, isNot(contains('VideoOutputManager.SetSurfaceSize(')));
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
