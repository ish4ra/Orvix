import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records account calls without ever storing password values.
class _RecoveryFakeBackend implements OrvixAccountBackend {
  OrvixAccountUser? user;
  final calls = <String>[];
  OrvixAuthException? requestError;
  OrvixAuthException? verifyError;
  String? updatedPassword;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    calls.add('signIn:$email');
    user = OrvixAccountUser(id: 'u1', email: email);
    return OrvixAuthResult(user: user, hasSession: true);
  }

  @override
  Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  }) async {
    calls.add('signUp:$email');
    return const OrvixAuthResult();
  }

  @override
  Future<OrvixAuthResult> verifySignupCode({
    required String email,
    required String token,
  }) async {
    calls.add('verifySignup:$email');
    return const OrvixAuthResult();
  }

  @override
  Future<void> resendSignupConfirmation({required String email}) async {
    calls.add('resendSignup:$email');
  }

  @override
  Future<void> requestPasswordRecovery({required String email}) async {
    calls.add('recover:$email');
    if (requestError != null) throw requestError!;
  }

  @override
  Future<void> verifyPasswordRecoveryCode({
    required String email,
    required String token,
  }) async {
    calls.add('verifyRecovery:$email:$token');
    if (verifyError != null) throw verifyError!;
    user = OrvixAccountUser(id: 'u1', email: email);
  }

  @override
  Future<void> updateRecoveredPassword({required String newPassword}) async {
    calls.add('updatePassword');
    updatedPassword = newPassword;
  }

  @override
  Future<void> endPasswordRecovery() async {
    calls.add('endRecovery');
    user = null;
  }

  @override
  Future<void> changePassword({
    required String newPassword,
    String? verificationCode,
  }) async {
    calls.add('changePassword');
  }

  @override
  Future<void> requestReauthentication() async {
    calls.add('reauthenticate');
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    user = null;
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async => null;

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {
    calls.add('saveUserState');
  }

  @override
  Future<Map<String, String>> loadCredentials() async => {};

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {}

  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) =>
      throw UnimplementedError();

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> signInWithTvLoginToken(String token) =>
      throw UnimplementedError();

  @override
  Future<bool> approveTvLogin(String userCode) => throw UnimplementedError();
}

void main() {
  late OrvixAccountBackend originalBackend;
  late _RecoveryFakeBackend backend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _RecoveryFakeBackend();
    OrvixAccountService.backend = backend;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await OrvixAccountService.cancelPasswordRecovery();
    OrvixAccountService.backend = originalBackend;
  });

  Future<void> pumpAccount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AccountScreen(onAuthChanged: () {})),
    ));
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  TextField textField(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label));

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> reachCodeStep(WidgetTester tester) async {
    await pumpAccount(tester);
    await tapText(tester, 'Forgot password?');
    await tester.enterText(field('Email'), ' r@example.com ');
    await tapText(tester, 'Send reset code');
  }

  Future<void> reachNewPasswordStep(WidgetTester tester) async {
    await reachCodeStep(tester);
    await tester.enterText(field('6-digit reset code'), '123456');
    await tapText(tester, 'Verify code');
  }

  testWidgets('sign in offers Forgot password?, sign up does not',
      (tester) async {
    await pumpAccount(tester);
    expect(find.text('Forgot password?'), findsOneWidget);
    await tapText(tester, 'Create an account');
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('full recovery: email, code, new password, back to sign in',
      (tester) async {
    await reachCodeStep(tester);

    expect(backend.calls, ['recover:r@example.com']);
    expect(find.text('Check your email'), findsOneWidget);
    // Never says whether the address has an account.
    expect(find.textContaining('If an Orvix account uses r@example.com'),
        findsOneWidget);

    await tester.enterText(field('6-digit reset code'), '123456');
    await tapText(tester, 'Verify code');
    expect(backend.calls.last, 'verifyRecovery:r@example.com:123456');
    expect(find.text('Choose a new password'), findsOneWidget);
    // The recovery session does not look like a signed-in account.
    expect(find.text('Cloud sync active'), findsNothing);
    expect(OrvixAccountService.currentUser, isNull);

    await tester.enterText(field('New password'), 'new-secret');
    await tester.enterText(field('Confirm new password'), 'new-secret');
    await tapText(tester, 'Update password');

    expect(backend.updatedPassword, 'new-secret');
    expect(backend.calls.sublist(backend.calls.length - 2),
        ['updatePassword', 'endRecovery']);
    expect(find.text('Password updated'), findsOneWidget);
    expect(OrvixAccountService.currentUser, isNull);
    expect(backend.calls, isNot(contains('saveUserState')));

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in with your new password.'), findsOneWidget);
    expect(textField(tester, 'Email').controller!.text, 'r@example.com');
    expect(textField(tester, 'Password').controller!.text, isEmpty);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('resend is held back by a cooldown', (tester) async {
    await reachCodeStep(tester);
    expect(find.text('Resend in 60s'), findsOneWidget);
    await tester.tap(find.text('Resend in 60s'));
    await tester.pump();
    expect(backend.calls, ['recover:r@example.com']);

    await tester.pump(const Duration(seconds: 60));
    await tapText(tester, 'Resend code');
    expect(backend.calls, ['recover:r@example.com', 'recover:r@example.com']);
    expect(find.text('Resend in 60s'), findsOneWidget);
  });

  testWidgets('a rate-limited request waits for the backend cooldown',
      (tester) async {
    backend.requestError = const OrvixAuthException('slow down',
        kind: OrvixAuthErrorKind.rateLimited, retryAfterSeconds: 42);
    await reachCodeStep(tester);
    expect(find.text('Check your email'), findsOneWidget);
    expect(
        find.text('Too many attempts. Please wait 42 seconds and try again.'),
        findsOneWidget);
    expect(find.text('Resend in 42s'), findsOneWidget);
  });

  testWidgets('malformed email is caught before any request', (tester) async {
    await pumpAccount(tester);
    await tapText(tester, 'Forgot password?');
    await tester.enterText(field('Email'), 'not-an-email');
    await tapText(tester, 'Send reset code');
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(backend.calls, isEmpty);
  });

  testWidgets('invalid or expired code shows a friendly message',
      (tester) async {
    backend.verifyError = const OrvixAuthException(
        'Token has expired or is invalid',
        kind: OrvixAuthErrorKind.invalidCode);
    await reachNewPasswordStep(tester);
    expect(
        find.text(
            'That code is invalid or has expired. Check the latest Orvix email or request a new code.'),
        findsOneWidget);
    expect(find.text('Check your email'), findsOneWidget);
    expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
  });

  testWidgets('a short code is rejected before any request', (tester) async {
    await reachCodeStep(tester);
    await tester.enterText(field('6-digit reset code'), '123');
    await tapText(tester, 'Verify code');
    expect(
        find.text('Enter the 6-digit code from your email.'), findsOneWidget);
    expect(backend.calls, ['recover:r@example.com']);
  });

  testWidgets('mismatched or short passwords never reach the backend',
      (tester) async {
    await reachNewPasswordStep(tester);

    await tester.enterText(field('New password'), 'new-secret');
    await tester.enterText(field('Confirm new password'), 'new-secreT');
    await tapText(tester, 'Update password');
    expect(find.text('The passwords do not match.'), findsOneWidget);

    await tester.enterText(field('New password'), 'abc');
    await tester.enterText(field('Confirm new password'), 'abc');
    await tapText(tester, 'Update password');
    expect(find.text('Use at least 6 characters for your new password.'),
        findsOneWidget);

    expect(backend.calls, isNot(contains('updatePassword')));
    // Messages never echo the password.
    expect(find.textContaining('new-secret'), findsNothing);
  });

  testWidgets('back to sign in cancels recovery at any step', (tester) async {
    await reachNewPasswordStep(tester);
    expect(OrvixAccountService.isPasswordRecoveryVerified, isTrue);
    await tapText(tester, 'Back to sign in');
    expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
    expect(backend.calls.last, 'endRecovery');
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(backend.updatedPassword, isNull);
  });

  testWidgets('password fields are hidden by default and toggle in place',
      (tester) async {
    await pumpAccount(tester);
    await tester.enterText(field('Password'), 'secret1');
    final controller = textField(tester, 'Password').controller!;
    controller.selection = const TextSelection.collapsed(offset: 3);
    expect(textField(tester, 'Password').obscureText, isTrue);
    expect(textField(tester, 'Password').enableSuggestions, isFalse);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(textField(tester, 'Password').obscureText, isFalse);
    expect(controller.text, 'secret1');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(textField(tester, 'Password').obscureText, isTrue);
    expect(controller.text, 'secret1');

    // Sign-up uses the same field.
    await tapText(tester, 'Create an account');
    expect(textField(tester, 'Password').obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
  });

  testWidgets('new and confirm password fields toggle independently',
      (tester) async {
    await reachNewPasswordStep(tester);
    expect(textField(tester, 'New password').obscureText, isTrue);
    expect(textField(tester, 'Confirm new password').obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(textField(tester, 'New password').obscureText, isFalse);
    expect(textField(tester, 'Confirm new password').obscureText, isTrue);
  });

  testWidgets('sign in and sign up are unchanged', (tester) async {
    await pumpAccount(tester);
    await tester.enterText(field('Email'), 'new@example.com');
    await tester.enterText(field('Password'), 'secret1');
    await tapText(tester, 'Create an account');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(backend.calls, ['signUp:new@example.com']);
    expect(find.text('Verify your email'), findsOneWidget);
    await tapText(tester, 'Back to sign in');

    await tester.enterText(field('Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'saveUserState');
    expect(backend.calls, contains('signIn:new@example.com'));
    expect(find.text('Cloud sync active'), findsOneWidget);
  });
}
