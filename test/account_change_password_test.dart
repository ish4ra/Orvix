import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A signed-in account whose password changes can be scripted to fail.
class _ChangePasswordFakeBackend implements OrvixAccountBackend {
  OrvixAccountUser? user =
      const OrvixAccountUser(id: 'u1', email: 'me@example.com');
  final calls = <String>[];
  final changeErrors = <OrvixAuthException>[];
  final reauthErrors = <OrvixAuthException>[];
  final changes = <(String, String?)>[];

  /// Mimics a backend that wants a code for older sessions.
  bool requireCode = false;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<void> changePassword({
    required String newPassword,
    String? verificationCode,
  }) async {
    calls.add(verificationCode == null
        ? 'changePassword'
        : 'changePassword:$verificationCode');
    if (changeErrors.isNotEmpty) throw changeErrors.removeAt(0);
    if (requireCode && verificationCode == null) {
      throw const OrvixAuthException(
          'Password update requires reauthentication',
          kind: OrvixAuthErrorKind.reauthenticationRequired);
    }
    changes.add((newPassword, verificationCode));
  }

  @override
  Future<void> requestReauthentication() async {
    calls.add('reauthenticate');
    if (reauthErrors.isNotEmpty) throw reauthErrors.removeAt(0);
  }

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    calls.add('signIn:$email');
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
  }

  @override
  Future<void> verifyPasswordRecoveryCode({
    required String email,
    required String token,
  }) async {
    calls.add('verifyRecovery:$email');
  }

  @override
  Future<void> updateRecoveredPassword({required String newPassword}) async {
    calls.add('updatePassword');
  }

  @override
  Future<void> endPasswordRecovery() async {
    calls.add('endRecovery');
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    user = null;
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async {
    calls.add('loadUserState');
    return null;
  }

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {
    calls.add('saveUserState');
  }

  @override
  Future<Map<String, String>> loadCredentials() async {
    calls.add('loadCredentials');
    return {};
  }

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {
    calls.add('saveCredentials');
  }

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
  late _ChangePasswordFakeBackend backend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _ChangePasswordFakeBackend();
    OrvixAccountService.backend = backend;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
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

  Finder changeButton() =>
      find.widgetWithText(FilledButton, 'Change password');

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> openChangePassword(WidgetTester tester) async {
    await pumpAccount(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Change password'));
    await tester.pumpAndSettle();
  }

  Future<void> submitPasswords(WidgetTester tester, String password,
      [String? confirmation]) async {
    await tester.enterText(field('New password'), password);
    await tester.enterText(
        field('Confirm new password'), confirmation ?? password);
    await tester.tap(changeButton());
    await tester.pumpAndSettle();
  }

  Future<void> reachCodeStep(WidgetTester tester) async {
    backend.requireCode = true;
    await openChangePassword(tester);
    await submitPasswords(tester, 'new-secret');
  }

  const noSync = ['loadUserState', 'saveUserState', 'loadCredentials',
      'saveCredentials', 'signOut'];

  void expectNoSync() {
    for (final call in noSync) {
      expect(backend.calls, isNot(contains(call)));
    }
  }

  testWidgets('only a signed-in account offers Change password',
      (tester) async {
    await pumpAccount(tester);
    expect(find.widgetWithText(OutlinedButton, 'Change password'),
        findsOneWidget);
    expect(find.text('Cloud sync active'), findsOneWidget);

    backend.user = null;
    await tester.pumpWidget(const SizedBox());
    await pumpAccount(tester);
    expect(find.text('Change password'), findsNothing);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('a recent session changes the password without a code',
      (tester) async {
    await openChangePassword(tester);
    expect(find.text('Change password'), findsWidgets);
    expect(field('New password'), findsOneWidget);
    expect(field('Confirm new password'), findsOneWidget);
    expect(find.textContaining('Choose a new password for me@example.com'),
        findsOneWidget);

    await submitPasswords(tester, 'new-secret');

    expect(backend.calls, ['changePassword']);
    expect(backend.changes, [('new-secret', null)]);
    expect(find.text('Password changed'), findsOneWidget);
    expect(find.textContaining('still signed in on this device'),
        findsOneWidget);
    // Still the same signed-in account, and nothing was synced.
    expect(OrvixAccountService.currentUser?.id, 'u1');
    expectNoSync();
    // The new password is not kept in the form.
    expect(find.textContaining('new-secret'), findsNothing);

    await tapText(tester, 'Done');
    expect(find.text('Cloud sync active'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Change password'),
        findsOneWidget);
  });

  testWidgets('mismatched, short or long passwords never reach the backend',
      (tester) async {
    await openChangePassword(tester);

    await submitPasswords(tester, 'new-secret', 'new-secreT');
    expect(find.text('The passwords do not match.'), findsOneWidget);

    await submitPasswords(tester, 'abc');
    expect(find.text('Use at least 6 characters for your new password.'),
        findsOneWidget);

    await submitPasswords(tester, 'x' * 73);
    expect(find.text('Use at most 72 characters for your new password.'),
        findsOneWidget);

    expect(backend.calls, isEmpty);
    expect(find.textContaining('new-secret'), findsNothing);
  });

  testWidgets('an older session confirms an emailed code, then changes',
      (tester) async {
    await reachCodeStep(tester);

    expect(backend.calls, ['changePassword', 'reauthenticate']);
    expect(find.text('Confirm it\'s you'), findsOneWidget);
    expect(find.textContaining('6-digit code to me@example.com'),
        findsOneWidget);
    expect(find.text('Resend in 60s'), findsOneWidget);
    // The chosen password is kept while the code is entered.
    expect(textField(tester, 'New password').controller!.text, 'new-secret');
    expect(textField(tester, 'Confirm new password').controller!.text,
        'new-secret');

    await tester.enterText(field('6-digit security code'), '123456');
    await tester.tap(changeButton());
    await tester.pumpAndSettle();

    expect(backend.calls.last, 'changePassword:123456');
    expect(backend.changes, [('new-secret', '123456')]);
    expect(find.text('Password changed'), findsOneWidget);
    expect(OrvixAccountService.currentUser?.id, 'u1');
    expectNoSync();
  });

  testWidgets('an invalid or expired code can be retried', (tester) async {
    await reachCodeStep(tester);
    backend.changeErrors.add(const OrvixAuthException(
        'Nonce has expired or is invalid',
        kind: OrvixAuthErrorKind.invalidCode));

    await tester.enterText(field('6-digit security code'), '000000');
    await tester.tap(changeButton());
    await tester.pumpAndSettle();
    expect(
        find.text(
            'That security code is invalid or has expired. Check the latest Orvix email or request a new code.'),
        findsOneWidget);
    expect(find.text('Confirm it\'s you'), findsOneWidget);
    expect(find.textContaining('Nonce'), findsNothing);

    await tester.enterText(field('6-digit security code'), '654321');
    await tester.tap(changeButton());
    await tester.pumpAndSettle();
    expect(backend.changes, [('new-secret', '654321')]);
    expect(find.text('Password changed'), findsOneWidget);
  });

  testWidgets('a malformed code is rejected before any request',
      (tester) async {
    await reachCodeStep(tester);
    await tester.enterText(field('6-digit security code'), '12a');
    await tester.tap(changeButton());
    await tester.pumpAndSettle();
    expect(find.text('Enter the 6-digit security code from your email.'),
        findsOneWidget);
    expect(backend.calls, ['changePassword', 'reauthenticate']);
  });

  testWidgets('resend waits for the cooldown', (tester) async {
    await reachCodeStep(tester);
    await tester.tap(find.text('Resend in 60s'));
    await tester.pump();
    expect(backend.calls, ['changePassword', 'reauthenticate']);

    await tester.pump(const Duration(seconds: 60));
    await tapText(tester, 'Resend code');
    expect(backend.calls,
        ['changePassword', 'reauthenticate', 'reauthenticate']);
    expect(find.text('A new security code was sent.'), findsOneWidget);
    expect(find.text('Resend in 60s'), findsOneWidget);
  });

  testWidgets('a rate-limited code request follows the backend wait time',
      (tester) async {
    backend.reauthErrors.add(const OrvixAuthException('slow down',
        kind: OrvixAuthErrorKind.rateLimited, retryAfterSeconds: 42));
    await reachCodeStep(tester);
    expect(find.text('Confirm it\'s you'), findsOneWidget);
    expect(
        find.text('Too many attempts. Please wait 42 seconds and try again.'),
        findsOneWidget);
    expect(find.text('Resend in 42s'), findsOneWidget);
  });

  testWidgets('a rate-limited change shows the wait time', (tester) async {
    backend.changeErrors.add(const OrvixAuthException('slow down',
        kind: OrvixAuthErrorKind.rateLimited));
    await openChangePassword(tester);
    await submitPasswords(tester, 'new-secret');
    expect(find.text('Too many attempts. Please wait a minute and try again.'),
        findsOneWidget);
    expect(field('New password'), findsOneWidget);
  });

  testWidgets('an expired sign-in asks the user to sign in again',
      (tester) async {
    backend.changeErrors.add(const OrvixAuthException('Auth session missing!',
        kind: OrvixAuthErrorKind.sessionMissing));
    await openChangePassword(tester);
    await submitPasswords(tester, 'new-secret');
    expect(
        find.text(
            'Your sign-in has expired. Sign out, sign in again, then change your password.'),
        findsOneWidget);
    expect(backend.changes, isEmpty);
    expectNoSync();
  });

  testWidgets('network failures show a friendly message', (tester) async {
    backend.changeErrors.add(const OrvixAuthException('Failed host lookup',
        kind: OrvixAuthErrorKind.network));
    await openChangePassword(tester);
    await submitPasswords(tester, 'new-secret');
    expect(
        find.text(
            'Could not reach Orvix Cloud. Check your internet connection and try again.'),
        findsOneWidget);
    expect(find.textContaining('host lookup'), findsNothing);
  });

  testWidgets('a code request that cannot reach the backend stays put',
      (tester) async {
    backend.reauthErrors.add(const OrvixAuthException('Failed host lookup',
        kind: OrvixAuthErrorKind.network));
    await reachCodeStep(tester);
    expect(
        find.text(
            'Could not reach Orvix Cloud. Check your internet connection and try again.'),
        findsOneWidget);
    expect(field('6-digit security code'), findsNothing);
    expect(field('New password'), findsOneWidget);
  });

  for (final (kind, text) in [
    (
      OrvixAuthErrorKind.samePassword,
      'Choose a password that is different from your current one.'
    ),
    (
      OrvixAuthErrorKind.weakPassword,
      'That password is too weak. Choose a longer password that is harder to guess.'
    ),
  ]) {
    testWidgets('a ${kind.name} rejection asks for another password',
        (tester) async {
      await reachCodeStep(tester);
      backend.changeErrors.add(OrvixAuthException('rejected', kind: kind));
      await tester.enterText(field('6-digit security code'), '123456');
      await tester.tap(changeButton());
      await tester.pumpAndSettle();

      expect(find.text(text), findsOneWidget);
      expect(field('6-digit security code'), findsNothing);
      expect(textField(tester, 'New password').controller!.text, isEmpty);
      expect(textField(tester, 'Confirm new password').controller!.text,
          isEmpty);

      // The next attempt asks for a fresh code again.
      await submitPasswords(tester, 'other-secret');
      expect(backend.calls.sublist(backend.calls.length - 2),
          ['changePassword', 'reauthenticate']);
      expect(field('6-digit security code'), findsOneWidget);
    });
  }

  testWidgets('cancel returns to the account card and clears the form',
      (tester) async {
    await reachCodeStep(tester);
    await tapText(tester, 'Cancel');
    expect(find.text('Cloud sync active'), findsOneWidget);
    expect(backend.changes, isEmpty);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Change password'));
    await tester.pumpAndSettle();
    expect(field('6-digit security code'), findsNothing);
    expect(textField(tester, 'New password').controller!.text, isEmpty);
  });

  testWidgets('a different account signed in mid-change is never updated',
      (tester) async {
    await openChangePassword(tester);
    backend.user = const OrvixAccountUser(id: 'u2', email: 'other@example.com');
    await submitPasswords(tester, 'new-secret');
    expect(backend.calls, isEmpty);
    expect(find.textContaining('no longer signed in to that account'),
        findsOneWidget);
  });

  testWidgets('new password fields are hidden and toggle in place',
      (tester) async {
    await reachCodeStep(tester);
    for (final label in ['New password', 'Confirm new password']) {
      final input = textField(tester, label);
      expect(input.obscureText, isTrue);
      expect(input.autocorrect, isFalse);
      expect(input.enableSuggestions, isFalse);
    }
    expect(find.byTooltip('Show password'), findsNWidgets(2));

    final controller = textField(tester, 'New password').controller!;
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(textField(tester, 'New password').obscureText, isFalse);
    expect(textField(tester, 'Confirm new password').obscureText, isTrue);
    expect(controller.text, 'new-secret');
    expect(controller.selection, const TextSelection.collapsed(offset: 4));

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(textField(tester, 'New password').obscureText, isTrue);
    expect(controller.text, 'new-secret');
  });

  testWidgets('sign out still works after a password change', (tester) async {
    await openChangePassword(tester);
    await submitPasswords(tester, 'new-secret');
    await tapText(tester, 'Done');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'signOut');
    expect(find.text('Forgot password?'), findsOneWidget);
  });
}
