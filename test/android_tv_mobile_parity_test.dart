import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Android TV DPAD reachability of Clouds, Account and the shell is covered
  // by widget tests in tv_screens_test.dart and tv_shell_navigation_test.dart.

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
    expect(account, contains("'Scan TV QR'"));
    // One scan approves once, after the user confirms the code.
    expect(account, contains('_scanGate.accept(value)'));
    expect(account, contains("'Sign in on this TV?'"));
    expect(account, contains('TvDeviceLoginService.approveScanned(code)'));
    final backend = File('lib/services/supabase_orvix_account_backend.dart')
        .readAsStringSync();
    expect(backend, contains("'approve_tv_login_session'"));
    expect(backend, contains("'p_user_code': userCode"));
    final login =
        File('lib/services/tv_device_login_service.dart').readAsStringSync();
    expect(login, contains("queryParameters['code']"));

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
