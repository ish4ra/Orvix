import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android TV cloud login remains vertically reachable by DPAD', () {
    final library = File('lib/screens/library_screen.dart').readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(library, contains("PageStorageKey('torbox-login-scroll')"));
    expect(library, contains("PageStorageKey('pikpak-login-scroll')"));
    expect(library, contains('SingleChildScrollView'));
    expect(
      library,
      contains('onSubmitted: (_) => _busy ? null : _connectApiKey()'),
    );
    expect(library, contains('textInputAction: TextInputAction.done'));
    expect(library, contains("tv-linear-torbox-device"));
    expect(library, contains("tv-linear-torbox-api-key"));
    expect(library, contains("tv-linear-torbox-connect"));
    expect(library, contains("tv-linear-debrid-token"));

    expect(app, contains('HardwareKeyboard.instance.addHandler'));
    expect(app, contains('HardwareKeyboard.instance.removeHandler'));
    expect(app, contains('current.focusInDirection(direction)'));
    expect(app, contains('current.nextFocus()'));
    expect(app, contains('current.previousFocus()'));
    expect(app, contains("debugLabel?.startsWith('tv-linear-')"));
    expect(app, contains('route == null || !route.isCurrent'));
    expect(app, contains('class _TvFocusAutoScroll'));
    expect(app, contains('Scrollable.ensureVisible'));
    expect(app, contains('alignment: 0.30'));
    expect(
      app,
      contains('alignmentPolicy: ScrollPositionAlignmentPolicy.explicit'),
    );
    expect(app, contains('return PopScope('));
    expect(app, contains('canPop: false'));
    expect(app, contains('_selectDestination(0)'));
  });

  test('Android mobile TV QR scanner owns camera lifecycle and recovery', () {
    final account = File('lib/screens/account_screen.dart').readAsStringSync();
    final mobileCompat =
        File('tools/configure_android_mobile_compat.py').readAsStringSync();

    expect(account, contains('MobileScannerController(autoStart: false)'));
    expect(account, contains('with WidgetsBindingObserver'));
    expect(account, contains('didChangeAppLifecycleState'));
    expect(account, contains('_scannerController.start()'));
    expect(account, contains('_scannerController.stop()'));
    expect(account, contains('errorBuilder: _cameraError'));
    expect(account, contains("'Retry camera'"));
    expect(account, contains("'Enter TV code'"));
    expect(account, contains("orvix-tv-qr-scanner-"));
    expect(account, contains("tv-linear-account-sync"));
    expect(account, contains("tv-linear-account-sign-out"));
    expect(account, contains("'Scan TV QR'"));
    expect(account, contains('TvDeviceLoginService.approve(code)'));
    final backend = File('lib/services/supabase_orvix_account_backend.dart')
        .readAsStringSync();
    expect(backend, contains("'approve_tv_login_session'"));
    expect(backend, contains("'p_user_code': userCode"));
    expect(account, contains("queryParameters['code']"));
    expect(account, contains('final validCode = code.length == 6'));
    expect(account, isNot(contains("RegExp(r'^[A-Z0-9]")));

    expect(mobileCompat, contains('android.permission.CAMERA'));
    expect(mobileCompat, contains('android.hardware.camera'));
    expect(mobileCompat, contains(r're.search(r"<manifest\b[^>]*>", text)'));
    expect(
      mobileCompat,
      isNot(contains(
        r'<manifest xmlns:android="http://schemas.android.com/apk/res/android">\\n',
      )),
    );
  });

  test('Android mobile Clouds selector keeps all four providers visible', () {
    final library = File('lib/screens/library_screen.dart').readAsStringSync();

    expect(library, contains('final mobile = PlatformProfile.isAndroidMobile'));
    expect(library, contains('expandedInsets: mobile ? EdgeInsets.zero : null'));
    expect(library, contains("ButtonSegment(value: CloudProvider.pikpak, label: Text('PikPak'))"));
    expect(library, contains("ButtonSegment(value: CloudProvider.torbox, label: Text('TorBox'))"));
    expect(library, contains("ButtonSegment(value: CloudProvider.realDebrid, label: Text('Real-Debrid'))"));
    expect(library, contains("ButtonSegment(value: CloudProvider.premiumize, label: Text('Premiumize'))"));
    expect(library, contains('SizedBox(width: double.infinity, child: providerSelector)'));
  });
}
