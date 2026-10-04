import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Player keeps active-picture Fit without stretching the Flutter texture', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final surface =
        File('lib/services/android_video_surface_service.dart').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(player, contains('fit: _resizeMode.boxFit'));
    expect(player, contains('width: double.infinity'));
    expect(player, contains('height: double.infinity'));
    expect(player, isNot(contains('_mobileActiveAspectRatio')));
    expect(
      player,
      isNot(contains('aspectRatio: PlatformProfile.isAndroidMobile')),
    );
    expect(player, contains('_resizeModeMenu()'));
    expect(player, contains('_applyAndroidMobileActiveFrameCrop()'));
    expect(player, contains('detectFromNativePlayer('));
    expect(player, contains("'file-local-options/video-crop'"));
    expect(player, contains('@orvix_autocrop:crop='));
    expect(
      player,
      contains('AndroidVideoSurfaceService.resizeToActiveFrame('),
    );
    expect(player, isNot(contains('_applyAndroidMobileNativeResize(')));
    expect(player, isNot(contains("'panscan'")));
    expect(player, isNot(contains("'video-aspect-override'")));
    expect(player, contains('_resizeModeSelectedByUser = true'));
    expect(
      player,
      contains('if (!mounted || _closing || _resizeModeSelectedByUser) return;'),
    );

    expect(
      surface,
      contains("MethodChannel('com.alexmercerind.media_kit_video')"),
    );
    expect(
      surface,
      contains("'VideoOutputManager.SetSurfaceSize'"),
    );
    expect(surface, contains('final rawPar = params.par;'));
    expect(surface, contains('final rotation ='));
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
