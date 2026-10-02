import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android TV cloud login remains vertically reachable by DPAD', () {
    final library = File('lib/screens/library_screen.dart').readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(library, contains("PageStorageKey('torbox-login-scroll')"));
    expect(library, contains("PageStorageKey('pikpak-login-scroll')"));
    expect(library, contains('SingleChildScrollView'));
    expect(app, contains('class _TvFocusAutoScroll'));
    expect(app, contains('Scrollable.ensureVisible'));
  });

  test('Android mobile can approve the QR session shown by TV', () {
    final account = File('lib/screens/account_screen.dart').readAsStringSync();

    expect(account, contains('MobileScanner('));
    expect(account, contains("'Scan TV QR'"));
    expect(account, contains("'approve_tv_login_session'"));
    expect(account, contains("'p_user_code': code"));
    expect(account, contains("queryParameters['code']"));
    expect(account, contains('final validCode = code.length == 6'));
    expect(account, isNot(contains("RegExp(r'^[A-Z0-9]")));
  });
}
