import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Mobile preserves pixels and covers only verified encoded letterbox', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(player, contains('PlayerResizeMode _resizeMode = PlayerResizeMode.fit'));
    expect(player, contains('fit: _effectiveVideoFit'));
    expect(player, contains('_mobileEncodedLetterboxDetected'));
    expect(player, contains('_detectAndroidMobileEncodedLetterbox()'));
    expect(player, contains('waitUntilFirstFrameRendered.timeout'));
    expect(player, contains('VideoBlackBarCropService.detectFromNativePlayer'));
    expect(player, contains('crop.isHorizontalLetterbox('));
    expect(player, contains('return BoxFit.cover'));
    expect(player, contains("'video-aspect-override': 'no'"));
    expect(player, contains("'video-aspect-method': 'container'"));
    expect(player, contains("'keepaspect': 'yes'"));
    expect(player, contains("'video-crop': ''"));
    expect(player, isNot(contains('@orvix_autocrop:crop=')));
    expect(player, isNot(contains('AndroidVideoSurfaceService')));
    expect(player, isNot(contains('VideoOutputManager.SetSurfaceSize(')));
    expect(player, isNot(contains('file-local-options/video-crop')));

    expect(player, contains('_androidMobileNativeStyledSubtitle'));
    expect(player, contains('_androidMobileTextSubtitleOverlay()'));
    expect(player, contains("'sub-font-provider': 'fontconfig'"));
    expect(player, contains("'embeddedfonts': 'yes'"));
    expect(player, contains("fontFamily: 'OrvixSubtitle'"));
    expect(pubspec, contains('family: OrvixSubtitle'));

    // Automatic normal playback must never pick an arbitrary foreign track.
    expect(player, isNot(contains('fallbackTracks =')));
    expect(player, contains('if (unknownText.length == 1)'));
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
