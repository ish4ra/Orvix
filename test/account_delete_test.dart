import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Proof extends OrvixPasswordProof {
  const _Proof(String userId) : super(userId: userId);
}

/// A signed-in account whose deletion can be scripted to fail or wait.
class _DeleteAccountFakeBackend implements OrvixAccountBackend {
  OrvixAccountUser? user =
      const OrvixAccountUser(id: 'u1', email: 'me@example.com');
  final calls = <String>[];
  OrvixAuthException? verifyError;
  Object? deleteError;
  Completer<void>? deleteGate;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixPasswordProof> verifyCurrentPassword({
    required String email,
    required String password,
  }) async {
    calls.add('verify:$email:$password');
    if (verifyError != null) throw verifyError!;
    return _Proof(user!.id);
  }

  @override
  Future<void> discardPasswordProof(OrvixPasswordProof proof) async {
    calls.add('discard');
  }

  @override
  Future<void> deleteAccount(OrvixPasswordProof proof) async {
    calls.add('delete:${proof.userId}');
    if (deleteGate != null) await deleteGate!.future;
    if (deleteError != null) throw deleteError!;
    user = null;
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
  }) async =>
      const OrvixAuthResult();

  @override
  Future<OrvixAuthResult> verifySignupCode({
    required String email,
    required String token,
  }) async =>
      const OrvixAuthResult();

  @override
  Future<void> resendSignupConfirmation({required String email}) async {}

  @override
  Future<void> requestPasswordRecovery({required String email}) async {}

  @override
  Future<void> verifyPasswordRecoveryCode({
    required String email,
    required String token,
  }) async {}

  @override
  Future<void> updateRecoveredPassword({required String newPassword}) async {}

  @override
  Future<void> endPasswordRecovery() async {}

  @override
  Future<void> changePassword({
    required String newPassword,
    String? verificationCode,
  }) async {
    calls.add('changePassword');
  }

  @override
  Future<void> requestReauthentication() async {}

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
  Future<void> cancelTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {}

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
  Future<bool> approveTvLogin(String userCode) async {
    calls.add('approveTv');
    return true;
  }
}

void main() {
  late OrvixAccountBackend originalBackend;
  late _DeleteAccountFakeBackend backend;
  late int authChanges;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _DeleteAccountFakeBackend();
    OrvixAccountService.backend = backend;
    authChanges = 0;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    OrvixAccountService.backend = originalBackend;
  });

  Future<void> pumpAccount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AccountScreen(onAuthChanged: () => authChanges++)),
    ));
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder confirmField() => field('Type DELETE to confirm');
  Finder passwordField() => field('Current password');
  Finder deleteButton() =>
      find.widgetWithText(FilledButton, 'Delete permanently');

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  Future<void> openDeleteAccount(WidgetTester tester) async {
    await pumpAccount(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete account'));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndSubmit(WidgetTester tester,
      {String confirmation = 'DELETE', String password = 'current-secret'}) async {
    await tester.enterText(confirmField(), confirmation);
    await tester.enterText(passwordField(), password);
    await tester.pump();
    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
  }

  const syncCalls = [
    'loadUserState',
    'saveUserState',
    'loadCredentials',
    'saveCredentials',
    'signOut',
  ];

  testWidgets('only a signed-in account offers Delete account',
      (tester) async {
    await pumpAccount(tester);
    expect(find.widgetWithText(OutlinedButton, 'Delete account'),
        findsOneWidget);

    backend.user = null;
    await tester.pumpWidget(const SizedBox());
    await pumpAccount(tester);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('the warning explains what is deleted and what stays',
      (tester) async {
    await openDeleteAccount(tester);
    expect(find.textContaining('permanently deletes the Orvix account '
        'me@example.com'), findsOneWidget);
    expect(find.textContaining('It cannot be undone'), findsOneWidget);
    expect(find.textContaining('Your Orvix account and its sign-in'),
        findsOneWidget);
    expect(find.textContaining('library, watchlist, Continue Watching'),
        findsOneWidget);
    expect(find.textContaining('credentials synced to your account'),
        findsOneWidget);
    expect(find.textContaining('TV sign-ins and TV login codes'),
        findsOneWidget);
    expect(find.textContaining('Orvix data on this device is not erased'),
        findsOneWidget);
    expect(backend.calls, isEmpty);
  });

  testWidgets('typing DELETE and the current password are both required',
      (tester) async {
    await openDeleteAccount(tester);
    expect(enabled(tester, deleteButton()), isFalse);

    await tester.enterText(passwordField(), 'current-secret');
    await tester.pump();
    expect(enabled(tester, deleteButton()), isFalse);

    for (final wrong in ['delete', 'DELET', 'DELETE ME']) {
      await tester.enterText(confirmField(), wrong);
      await tester.pump();
      expect(enabled(tester, deleteButton()), isFalse, reason: wrong);
    }

    await tester.enterText(confirmField(), 'DELETE');
    await tester.enterText(passwordField(), '');
    await tester.pump();
    expect(enabled(tester, deleteButton()), isFalse);

    // Submitting from the keyboard is refused too.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.enterText(passwordField(), 'current-secret');
    await tester.pump();
    expect(enabled(tester, deleteButton()), isTrue);
    expect(backend.calls, isEmpty);
  });

  testWidgets('the current password is hidden', (tester) async {
    await openDeleteAccount(tester);
    final password = tester.widget<TextField>(passwordField());
    expect(password.obscureText, isTrue);
    expect(password.enableSuggestions, isFalse);
    expect(password.autocorrect, isFalse);
  });

  testWidgets('cancel returns to the account card and clears the form',
      (tester) async {
    await openDeleteAccount(tester);
    await tester.enterText(confirmField(), 'DELETE');
    await tester.enterText(passwordField(), 'current-secret');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Cloud sync active'), findsOneWidget);
    expect(backend.calls, isEmpty);
    expect(OrvixAccountService.currentUser?.id, 'u1');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete account'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(confirmField()).controller!.text, isEmpty);
    expect(tester.widget<TextField>(passwordField()).controller!.text, isEmpty);
  });

  testWidgets('a wrong password deletes nothing and can be retried',
      (tester) async {
    backend.verifyError = const OrvixAuthException('Invalid login credentials',
        kind: OrvixAuthErrorKind.invalidCredentials);
    await openDeleteAccount(tester);
    await fillAndSubmit(tester, password: 'wrong-secret');

    expect(find.text('That password is not correct. Your account was not deleted.'),
        findsOneWidget);
    expect(backend.calls, ['verify:me@example.com:wrong-secret']);
    expect(OrvixAccountService.currentUser?.id, 'u1');
    // The form stays open for another try, without the old password.
    expect(tester.widget<TextField>(passwordField()).controller!.text, isEmpty);
    expect(tester.widget<TextField>(confirmField()).controller!.text, 'DELETE');
    expect(authChanges, 0);
  });

  testWidgets('a successful deletion signs out and keeps Orvix usable',
      (tester) async {
    await openDeleteAccount(tester);
    await fillAndSubmit(tester);

    expect(backend.calls, [
      'verify:me@example.com:current-secret',
      'delete:u1',
      'discard',
    ]);
    expect(find.textContaining('Your Orvix account was permanently deleted'),
        findsOneWidget);
    expect(find.textContaining('still here'), findsOneWidget);
    expect(OrvixAccountService.currentUser, isNull);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
    expect(authChanges, 1);
    for (final call in syncCalls) {
      expect(backend.calls, isNot(contains(call)));
    }
  });

  final failures = <String, (Object, String)>{
    'a server failure': (
      const OrvixAuthException('Account deletion failed.', statusCode: '500'),
      'Could not delete your account right now, so it was not deleted. Please try again later.'
    ),
    'a network failure': (
      const OrvixAuthException('Could not reach the account deletion service.',
          kind: OrvixAuthErrorKind.network),
      'Could not reach Orvix Cloud, so your account was not deleted. Check your internet connection and try again.'
    ),
    'an expired sign-in': (
      const OrvixAuthException('Account deletion failed.',
          kind: OrvixAuthErrorKind.sessionMissing),
      'Your sign-in has expired. Sign out, sign in again, then delete your account.'
    ),
    'a stale password check': (
      const OrvixAuthException('Account deletion failed.',
          kind: OrvixAuthErrorKind.reauthenticationRequired),
      'For your security, enter your current password again to delete your account.'
    ),
    'a rate limit': (
      const OrvixAuthException('Account deletion failed.',
          kind: OrvixAuthErrorKind.rateLimited, retryAfterSeconds: 30),
      'Too many attempts. Please wait 30 seconds and try again.'
    ),
    'an unexpected error': (
      StateError('boom'),
      'Could not delete your account right now, so it was not deleted. Please try again later.'
    ),
  };
  failures.forEach((name, expected) {
    testWidgets('$name keeps the account signed in with a friendly message',
        (tester) async {
      backend.deleteError = expected.$1;
      await openDeleteAccount(tester);
      await fillAndSubmit(tester);

      expect(find.text(expected.$2), findsOneWidget);
      expect(find.textContaining('permanently deleted'), findsNothing);
      expect(find.textContaining('boom'), findsNothing);
      expect(OrvixAccountService.currentUser?.id, 'u1');
      expect(authChanges, 0);
      expect(tester.widget<TextField>(passwordField()).controller!.text,
          isEmpty);
    });
  });

  testWidgets('controls are disabled while the deletion runs',
      (tester) async {
    backend.deleteGate = Completer<void>();
    await openDeleteAccount(tester);
    await tester.enterText(confirmField(), 'DELETE');
    await tester.enterText(passwordField(), 'current-secret');
    await tester.pump();
    await tester.tap(deleteButton());
    await tester.pump();

    expect(OrvixAccountService.isDeletingAccount, isTrue);
    expect(find.text('Deleting your Orvix account…'), findsOneWidget);
    expect(enabled(tester, deleteButton()), isFalse);
    expect(
        enabled(tester, find.widgetWithText(TextButton, 'Cancel')), isFalse);
    expect(tester.widget<TextField>(confirmField()).enabled, isFalse);
    expect(tester.widget<TextField>(passwordField()).enabled, isFalse);
    // The password is not kept in the form while the request runs.
    expect(tester.widget<TextField>(passwordField()).controller!.text, isEmpty);

    // Sync started elsewhere in the app does nothing meanwhile.
    await OrvixAccountService.pushLocalStateIfSignedIn();
    expect(backend.calls, isNot(contains('saveUserState')));

    backend.deleteGate!.complete();
    await tester.pumpAndSettle();
    expect(OrvixAccountService.isDeletingAccount, isFalse);
    expect(find.textContaining('permanently deleted'), findsOneWidget);
  });

  testWidgets('a different account signed in meanwhile is never deleted',
      (tester) async {
    await openDeleteAccount(tester);
    await tester.enterText(confirmField(), 'DELETE');
    await tester.enterText(passwordField(), 'current-secret');
    await tester.pump();
    backend.user = const OrvixAccountUser(id: 'u2', email: 'other@example.com');
    await tester.tap(deleteButton());
    await tester.pumpAndSettle();

    expect(
        find.text(
            'You are no longer signed in to that account, so nothing was deleted.'),
        findsOneWidget);
    expect(deleteButton(), findsNothing);
    expect(find.text('Cloud sync active'), findsOneWidget);
    expect(backend.calls, isEmpty);
    expect(OrvixAccountService.currentUser?.id, 'u2');
  });

  test('Android TV keeps QR/device login only, without account deletion', () {
    final source = File('lib/screens/account_screen.dart').readAsStringSync();
    // TV builds render the TV layout before any phone/desktop card.
    final build = source.indexOf('Widget build(BuildContext context)');
    expect(source.indexOf('return _buildTvAccount(context, user);', build),
        greaterThan(build));
    final tvLayout = source.substring(source.indexOf('class _TvAccountView'),
        source.indexOf('class _OrvixTvQrScannerScreen'));
    expect(tvLayout, isNot(contains('Delete account')));
    expect(tvLayout, isNot(contains('deleteAccount')));
    // The phone/desktop section is also guarded against TV builds.
    expect(
        source,
        contains('if (!PlatformProfile.isAndroidTv) ...[\n'
            '          const SizedBox(height: 22),'));
  });
}
