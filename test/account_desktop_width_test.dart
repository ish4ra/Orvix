import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Signed-out backend; the layout test never signs in.
class _SignedOutBackend implements OrvixAccountBackend {
  OrvixAccountUser? user;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late OrvixAccountBackend originalBackend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    OrvixAccountService.backend = _SignedOutBackend();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    OrvixAccountService.backend = originalBackend;
  });

  Future<void> pumpAccount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AccountScreen(onAuthChanged: () {})),
    ));
    await tester.pump();
  }

  Rect emailFieldRect(WidgetTester tester) =>
      tester.getRect(find.widgetWithText(TextField, 'Email'));

  Rect titleRect(WidgetTester tester) =>
      tester.getRect(find.text('Orvix Account'));

  testWidgets('wide desktop window keeps the sign-in card compact',
      (tester) async {
    await pumpAccount(tester, const Size(1800, 1000));

    final field = emailFieldRect(tester);
    // The form lives inside the 720px column (card padding included), so it
    // must not stretch across the 1800px content area.
    expect(field.width, lessThanOrEqualTo(accountContentMaxWidth));
    expect(field.width, greaterThan(accountContentMaxWidth - 60));
    // Left-aligned with the page padding, like the title above it.
    expect(field.left, lessThan(100));
    expect(titleRect(tester).left, closeTo(34, 0.5));
    expect(find.text('What syncs'), findsOneWidget);
  });

  testWidgets('narrow window still shrinks the card to fit', (tester) async {
    await pumpAccount(tester, const Size(640, 900));

    final field = emailFieldRect(tester);
    expect(field.right, lessThanOrEqualTo(640 - 34));
    expect(field.width, greaterThan(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('card width does not depend on the shown account form',
      (tester) async {
    await pumpAccount(tester, const Size(1800, 1000));
    final signIn = emailFieldRect(tester).width;

    await tester.tap(find.text('Create an account'));
    await tester.pump();
    expect(emailFieldRect(tester).width, signIn);
  });
}
