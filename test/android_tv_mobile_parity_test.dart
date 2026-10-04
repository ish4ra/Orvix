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

    expect(app, contains('HardwareKeyboard.instance.addHandler'));
    expect(app, contains('HardwareKeyboard.instance.removeHandler'));
    expect(app, contains('current.focusInDirection(direction)'));
    expect(app, contains('current.nextFocus()'));
    expect(app, contains('current.previousFocus()'));
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
    expect(account, contains("'Scan TV QR'"));
    expect(account, contains("'approve_tv_login_session'"));
    expect(account, contains("'p_user_code': code"));
    expect(account, contains("queryParameters['code']"));
    expect(account, contains('final validCode = code.length == 6'));
    expect(account, isNot(contains("RegExp(r'^[A-Z0-9]")));

    expect(mobileCompat, contains('android.permission.CAMERA'));
    expect(mobileCompat, contains('android.hardware.camera'));
    expect(
      mobileCompat,
      isNot(contains(
        r'<manifest xmlns:android="http://schemas.android.com/apk/res/android">\\n',
      )),
    );
  });
}
