import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/supabase_orvix_account_backend.dart';
import 'package:orvix/services/tv_device_login_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeBackend implements OrvixAccountBackend {
  OrvixAccountUser? user;
  final calls = <String>[];
  Map<String, dynamic>? storedState;
  Map<String, String> storedCredentials = {};
  final savedStates = <Map<String, dynamic>>[];
  final savedCredentials = <Map<String, String>>[];
  OrvixAuthResult signInResult = const OrvixAuthResult(
    user: OrvixAccountUser(id: 'user-1', email: 'a@example.com'),
    hasSession: true,
  );
  OrvixAuthResult signUpResult = const OrvixAuthResult();
  OrvixAuthException? authError;
  final pollStatuses = <String>['approved'];
  String? tvToken;
  OrvixAuthException? recoveryVerifyError;
  final recoveryUpdateErrors = <OrvixAuthException>[];
  final updatedPasswords = <String>[];
  final changePasswordErrors = <OrvixAuthException>[];
  final passwordChanges = <(String, String?)>[];
  OrvixAuthException? verifyPasswordError;
  String? proofUserId;
  void Function()? onVerifyPassword;
  Object? deleteError;
  Completer<void>? deleteGate;
  Completer<void>? loadCredentialsGate;
  bool clearSessionOnDelete = true;
  final discardedProofs = <OrvixPasswordProof>[];

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    calls.add('signIn:$email');
    if (authError != null) throw authError!;
    user = signInResult.user;
    return signInResult;
  }

  @override
  Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  }) async {
    calls.add('signUp:$email');
    if (signUpResult.hasSession) user = signUpResult.user;
    return signUpResult;
  }

  @override
  Future<OrvixAuthResult> verifySignupCode({
    required String email,
    required String token,
  }) async {
    calls.add('verify:$email:$token');
    return const OrvixAuthResult();
  }

  @override
  Future<void> resendSignupConfirmation({required String email}) async {
    calls.add('resend:$email');
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
    calls.add('verifyRecovery:$email:$token');
    if (recoveryVerifyError != null) throw recoveryVerifyError!;
    user = OrvixAccountUser(id: 'recovered-user', email: email);
  }

  @override
  Future<void> updateRecoveredPassword({required String newPassword}) async {
    calls.add('updatePassword');
    if (recoveryUpdateErrors.isNotEmpty) throw recoveryUpdateErrors.removeAt(0);
    updatedPasswords.add(newPassword);
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
    if (changePasswordErrors.isNotEmpty) throw changePasswordErrors.removeAt(0);
    passwordChanges.add((newPassword, verificationCode));
  }

  @override
  Future<void> requestReauthentication() async {
    calls.add('reauthenticate');
  }

  @override
  Future<OrvixPasswordProof> verifyCurrentPassword({
    required String email,
    required String password,
  }) async {
    calls.add('verifyPassword:$email:$password');
    if (verifyPasswordError != null) throw verifyPasswordError!;
    onVerifyPassword?.call();
    return _FakeProof(proofUserId ?? user!.id);
  }

  @override
  Future<void> discardPasswordProof(OrvixPasswordProof proof) async {
    calls.add('discardProof:${proof.userId}');
    discardedProofs.add(proof);
  }

  @override
  Future<void> deleteAccount(OrvixPasswordProof proof) async {
    calls.add('deleteAccount:${proof.userId}');
    if (deleteGate != null) await deleteGate!.future;
    if (deleteError != null) throw deleteError!;
    if (clearSessionOnDelete) user = null;
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    user = null;
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async {
    calls.add('loadUserState:$userId');
    return storedState;
  }

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {
    calls.add('saveUserState:$userId');
    savedStates.add(state);
  }

  @override
  Future<Map<String, String>> loadCredentials() async {
    calls.add('loadCredentials');
    if (loadCredentialsGate != null) await loadCredentialsGate!.future;
    return storedCredentials;
  }

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {
    calls.add('saveCredentials');
    savedCredentials.add(credentials);
  }

  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) async {
    calls.add('startTv:$deviceName');
    return const OrvixTvLoginStart(
      deviceCode: 'device',
      userCode: 'ABC123',
      verificationUrl: 'https://example.com/tv?code=ABC123',
      pollIntervalSeconds: 2,
    );
  }

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('pollTv:$deviceCode');
    return pollStatuses.removeAt(0);
  }

  @override
  Future<void> cancelTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {}

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('exchangeTv:$deviceCode');
    return 'tv-token';
  }

  @override
  Future<void> signInWithTvLoginToken(String token) async {
    tvToken = token;
    user = const OrvixAccountUser(id: 'tv-user');
  }

  @override
  Future<bool> approveTvLogin(String userCode) async {
    calls.add('approveTv:$userCode');
    return userCode == 'ABC123';
  }
}

class _FakeProof extends OrvixPasswordProof {
  _FakeProof(String userId) : super(userId: userId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrvixAccountBackend originalBackend;
  late _FakeBackend backend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _FakeBackend();
    OrvixAccountService.backend = backend;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() => OrvixAccountService.backend = originalBackend);

  test('Supabase is the default account backend', () {
    expect(originalBackend, isA<SupabaseOrvixAccountBackend>());
  });

  group('signed out / local only', () {
    test('never touches the backend and leaves local data alone', () async {
      SharedPreferences.setMockInitialValues({
        'pikora_watchlist_v1': jsonEncode([
          {'id': '1', 'kind': 'movie'}
        ]),
        'orvix_theme_v1': 'dark',
      });

      expect(OrvixAccountService.isSignedIn, isFalse);
      expect(OrvixAccountService.currentUser, isNull);
      await OrvixAccountService.restoreSignedInState();
      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.syncCredentialsIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();

      expect(backend.calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('orvix_theme_v1'), 'dark');
      expect(jsonDecode(prefs.getString('pikora_watchlist_v1')!), [
        {'id': '1', 'kind': 'movie'}
      ]);
    });

    test('restoreSignedInState swallows cloud failures', () async {
      backend.user = const OrvixAccountUser(id: 'user-1');
      final failing = _ThrowingCloudBackend(backend);
      OrvixAccountService.backend = failing;
      await OrvixAccountService.restoreSignedInState();
    });
  });

  group('auth through the backend abstraction', () {
    test('sign in trims the email and merges the cloud', () async {
      final result = await OrvixAccountService.signIn(
        email: '  a@example.com ',
        password: 'secret1',
      );
      expect(result.hasSession, isTrue);
      expect(OrvixAccountService.currentUser?.email, 'a@example.com');
      expect(backend.calls, [
        'signIn:a@example.com',
        'loadCredentials',
        'loadUserState:user-1',
        'saveUserState:user-1',
      ]);
    });

    test('sign up without a session waits for verification', () async {
      final result = await OrvixAccountService.signUp(
        email: 'new@example.com ',
        password: 'secret1',
      );
      expect(result.hasSession, isFalse);
      expect(backend.calls, ['signUp:new@example.com']);
      expect(OrvixAccountService.isSignedIn, isFalse);
    });

    test('verification and resend trim input and do not merge without session',
        () async {
      await OrvixAccountService.verifySignupOtp(
          email: ' v@example.com', token: ' 123456 ');
      await OrvixAccountService.resendSignupConfirmation(
          email: ' v@example.com ');
      expect(backend.calls,
          ['verify:v@example.com:123456', 'resend:v@example.com']);
    });

    test('backend auth errors reach the UI as OrvixAuthException', () async {
      backend.authError =
          const OrvixAuthException('Invalid login credentials');
      await expectLater(
        OrvixAccountService.signIn(email: 'a@example.com', password: 'x'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.message, 'message', 'Invalid login credentials')),
      );
    });

    test('sign out goes through the backend', () async {
      backend.user = const OrvixAccountUser(id: 'user-1');
      await OrvixAccountService.signOut();
      expect(OrvixAccountService.isSignedIn, isFalse);
      expect(backend.calls, ['signOut']);
    });
  });

  group('password recovery through the backend abstraction', () {
    tearDown(OrvixAccountService.cancelPasswordRecovery);

    test('request trims the email and never syncs', () async {
      await OrvixAccountService.requestPasswordRecovery(
          email: ' r@example.com ');
      expect(backend.calls, ['recover:r@example.com']);
      expect(OrvixAccountService.isSignedIn, isFalse);
    });

    test('verified code, new password, then signed out with nothing synced',
        () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: ' r@example.com', token: ' 123456 ');
      expect(OrvixAccountService.isPasswordRecoveryVerified, isTrue);
      // The recovery session is not a sign-in: nothing syncs into it.
      expect(backend.user, isNotNull);
      expect(OrvixAccountService.currentUser, isNull);
      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('orvix_password_recovery_pending_v1'), isTrue);

      await OrvixAccountService.updateRecoveredPassword(
          newPassword: 'new-secret');
      expect(backend.updatedPasswords, ['new-secret']);
      expect(backend.calls, [
        'verifyRecovery:r@example.com:123456',
        'updatePassword',
        'endRecovery',
      ]);
      expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
      expect(OrvixAccountService.currentUser, isNull);
      expect(prefs.containsKey('orvix_password_recovery_pending_v1'), isFalse);

      // Signing in afterwards is the normal path.
      await OrvixAccountService.signIn(
          email: 'r@example.com', password: 'new-secret');
      expect(OrvixAccountService.isSignedIn, isTrue);
    });

    for (final message in [
      'Token has expired or is invalid',
      'Invalid token',
    ]) {
      test('rejected code ($message) leaves no recovery session', () async {
        backend.recoveryVerifyError = OrvixAuthException(message,
            code: 'otp_expired', kind: OrvixAuthErrorKind.invalidCode);
        await expectLater(
          OrvixAccountService.verifyPasswordRecovery(
              email: 'r@example.com', token: '000000'),
          throwsA(isA<OrvixAuthException>().having(
              (e) => e.kind, 'kind', OrvixAuthErrorKind.invalidCode)),
        );
        expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
        await expectLater(
          OrvixAccountService.updateRecoveredPassword(newPassword: 'abcdef'),
          throwsA(isA<OrvixAuthException>().having(
              (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
        );
        expect(backend.calls, contains('endRecovery'));
        expect(backend.calls, isNot(contains('updatePassword')));
      });
    }

    test('a rejected new password keeps the session for another try',
        () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: 'r@example.com', token: '123456');
      backend.recoveryUpdateErrors.add(const OrvixAuthException('weak',
          kind: OrvixAuthErrorKind.weakPassword));
      await expectLater(
        OrvixAccountService.updateRecoveredPassword(newPassword: 'abcdef'),
        throwsA(isA<OrvixAuthException>()),
      );
      expect(OrvixAccountService.isPasswordRecoveryVerified, isTrue);
      expect(OrvixAccountService.currentUser, isNull);

      await OrvixAccountService.updateRecoveredPassword(
          newPassword: 'longer-secret');
      expect(backend.updatedPasswords, ['longer-secret']);
      expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
    });

    test('an expired recovery session ends recovery', () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: 'r@example.com', token: '123456');
      backend.recoveryUpdateErrors.add(const OrvixAuthException('gone',
          kind: OrvixAuthErrorKind.sessionMissing));
      await expectLater(
        OrvixAccountService.updateRecoveredPassword(newPassword: 'abcdef'),
        throwsA(isA<OrvixAuthException>()),
      );
      expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
      expect(backend.calls.last, 'endRecovery');
    });

    test('cancel discards the recovery session', () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: 'r@example.com', token: '123456');
      await OrvixAccountService.cancelPasswordRecovery();
      expect(OrvixAccountService.isPasswordRecoveryVerified, isFalse);
      expect(backend.user, isNull);
      expect(backend.calls.last, 'endRecovery');
      expect(backend.updatedPasswords, isEmpty);
    });

    test('recovery is refused while signed in', () async {
      backend.user = const OrvixAccountUser(id: 'user-1');
      await expectLater(
        OrvixAccountService.verifyPasswordRecovery(
            email: 'r@example.com', token: '123456'),
        throwsStateError,
      );
      expect(backend.user?.id, 'user-1');
      expect(backend.calls, isEmpty);
    });

    test('a recovery interrupted by closing the app is discarded on start',
        () async {
      SharedPreferences.setMockInitialValues(
          {'orvix_password_recovery_pending_v1': true});
      backend.user = const OrvixAccountUser(id: 'recovered-user');
      await OrvixAccountService.restoreSignedInState();
      expect(backend.calls, ['endRecovery']);
      expect(OrvixAccountService.isSignedIn, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('orvix_password_recovery_pending_v1'), isFalse);
    });

    test('the recovery marker never syncs to the cloud', () async {
      SharedPreferences.setMockInitialValues(
          {'orvix_password_recovery_pending_v1': true, 'orvix_theme_v1': 'x'});
      backend.user = const OrvixAccountUser(id: 'user-1');
      await OrvixAccountService.pushLocalStateIfSignedIn();
      final preferences =
          backend.savedStates.single['preferences'] as Map<String, dynamic>;
      expect(preferences, {'orvix_theme_v1': 'x'});
    });
  });

  group('signed-in password change through the backend abstraction', () {
    const signedIn = OrvixAccountUser(id: 'user-1', email: 'a@example.com');

    test('changes the password without syncing or signing out', () async {
      backend.user = signedIn;
      await OrvixAccountService.changePassword(newPassword: 'new-secret');
      expect(backend.calls, ['changePassword']);
      expect(backend.passwordChanges, [('new-secret', null)]);
      expect(OrvixAccountService.currentUser?.id, 'user-1');
    });

    test('a verification code is trimmed and blank codes are not sent',
        () async {
      backend.user = signedIn;
      await OrvixAccountService.changePassword(
          newPassword: 'new-secret', verificationCode: ' 123456 ');
      await OrvixAccountService.changePassword(
          newPassword: 'new-secret', verificationCode: '  ');
      expect(backend.passwordChanges,
          [('new-secret', '123456'), ('new-secret', null)]);
    });

    test('the code request goes through the backend', () async {
      backend.user = signedIn;
      await OrvixAccountService.requestPasswordChangeCode();
      expect(backend.calls, ['reauthenticate']);
    });

    test('backend rejections reach the caller unchanged', () async {
      backend.user = signedIn;
      backend.changePasswordErrors.add(const OrvixAuthException('reauth',
          kind: OrvixAuthErrorKind.reauthenticationRequired));
      await expectLater(
        OrvixAccountService.changePassword(newPassword: 'new-secret'),
        throwsA(isA<OrvixAuthException>().having((e) => e.kind, 'kind',
            OrvixAuthErrorKind.reauthenticationRequired)),
      );
      expect(OrvixAccountService.currentUser?.id, 'user-1');
      expect(backend.calls, ['changePassword']);
    });

    test('is refused while signed out without calling the backend', () async {
      await expectLater(
        OrvixAccountService.changePassword(newPassword: 'new-secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      await expectLater(
        OrvixAccountService.requestPasswordChangeCode(),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      expect(backend.calls, isEmpty);
    });

    test('never uses a password recovery session', () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: 'r@example.com', token: '123456');
      addTearDown(OrvixAccountService.cancelPasswordRecovery);
      await expectLater(
        OrvixAccountService.changePassword(newPassword: 'new-secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      expect(backend.calls, isNot(contains('changePassword')));
    });
  });

  group('account deletion through the backend abstraction', () {
    const me = OrvixAccountUser(id: 'user-1', email: 'a@example.com');

    bool cloudCall(String call) =>
        call.startsWith('loadUserState') ||
        call.startsWith('saveUserState') ||
        call == 'loadCredentials' ||
        call == 'saveCredentials' ||
        call.startsWith('approveTv');

    test('is refused while signed out without calling the backend', () async {
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      expect(backend.calls, isEmpty);
      expect(OrvixAccountService.isDeletingAccount, isFalse);
    });

    test('is refused during password recovery', () async {
      await OrvixAccountService.verifyPasswordRecovery(
          email: 'a@example.com', token: '123456');
      backend.calls.clear();
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      expect(backend.calls, isEmpty);
      await OrvixAccountService.cancelPasswordRecovery();
    });

    test('confirms the password for the signed-in email, deletes, signs out',
        () async {
      backend.user = me;
      await OrvixAccountService.deleteAccount(currentPassword: 'secret');
      expect(backend.calls, [
        'verifyPassword:a@example.com:secret',
        'deleteAccount:user-1',
        'discardProof:user-1',
      ]);
      expect(OrvixAccountService.currentUser, isNull);
      expect(OrvixAccountService.isSignedIn, isFalse);
      expect(OrvixAccountService.isDeletingAccount, isFalse);
    });

    test('a wrong password deletes nothing and keeps the sign-in', () async {
      backend.user = me;
      backend.verifyPasswordError = const OrvixAuthException(
          'Invalid login credentials',
          kind: OrvixAuthErrorKind.invalidCredentials);
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'wrong'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.invalidCredentials)),
      );
      expect(backend.calls, ['verifyPassword:a@example.com:wrong']);
      expect(OrvixAccountService.currentUser?.id, 'user-1');
      expect(OrvixAccountService.isDeletingAccount, isFalse);
    });

    test('a password verified for another account aborts the deletion',
        () async {
      backend.user = me;
      backend.proofUserId = 'someone-else';
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.accountChanged)),
      );
      expect(backend.calls.where((c) => c.startsWith('deleteAccount')),
          isEmpty);
      expect(backend.calls.last, 'discardProof:someone-else');
      expect(OrvixAccountService.currentUser?.id, 'user-1');
    });

    test('an account switch during verification aborts the deletion',
        () async {
      backend.user = me;
      backend.onVerifyPassword = () => backend.user =
          const OrvixAccountUser(id: 'user-2', email: 'b@example.com');
      backend.proofUserId = 'user-1';
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.accountChanged)),
      );
      expect(backend.calls.where((c) => c.startsWith('deleteAccount')),
          isEmpty);
      expect(backend.discardedProofs, hasLength(1));
      expect(OrvixAccountService.currentUser?.id, 'user-2');
    });

    test('a failed server deletion is not reported as deleted', () async {
      backend.user = me;
      backend.deleteError = const OrvixAuthException('Account deletion failed.',
          code: 'delete_failed', statusCode: '500');
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsA(isA<OrvixAuthException>()),
      );
      expect(backend.calls.last, 'discardProof:user-1');
      expect(OrvixAccountService.currentUser?.id, 'user-1');
      expect(OrvixAccountService.isDeletingAccount, isFalse);

      // Sync resumes for the account that still exists.
      await OrvixAccountService.pushLocalStateIfSignedIn();
      expect(backend.calls.last, 'saveUserState:user-1');
    });

    test('cloud sync, credential sync and TV approval wait while deleting',
        () async {
      backend.user = me;
      backend.deleteGate = Completer<void>();
      final deletion =
          OrvixAccountService.deleteAccount(currentPassword: 'secret');
      await Future<void>.delayed(Duration.zero);
      expect(OrvixAccountService.isDeletingAccount, isTrue);
      backend.calls.clear();

      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.syncCredentialsIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();
      await OrvixAccountService.restoreSignedInState();
      await expectLater(
          TvDeviceLoginService.approve('ABC123'), throwsStateError);
      await expectLater(
        OrvixAccountService.deleteAccount(currentPassword: 'secret'),
        throwsStateError,
      );
      expect(backend.calls.where(cloudCall), isEmpty);

      backend.deleteGate!.complete();
      await deletion;
      expect(OrvixAccountService.isDeletingAccount, isFalse);
      expect(OrvixAccountService.currentUser, isNull);
    });

    test('a sync already running when deletion starts writes nothing more',
        () async {
      backend.user = me;
      FlutterSecureStorage.setMockInitialValues(
          {'orvix_torbox_api_token_v1': 'local-torbox'});
      backend.loadCredentialsGate = Completer<void>();
      final merge = OrvixAccountService.mergeCloudIntoLocal();
      await Future<void>.delayed(Duration.zero);
      backend.deleteGate = Completer<void>();
      final deletion =
          OrvixAccountService.deleteAccount(currentPassword: 'secret');
      await Future<void>.delayed(Duration.zero);

      backend.loadCredentialsGate!.complete();
      await merge;
      backend.deleteGate!.complete();
      await deletion;

      expect(
          backend.calls.where((c) =>
              c == 'saveCredentials' ||
              c.startsWith('saveUserState') ||
              c.startsWith('loadUserState')),
          isEmpty);
    });

    test('local-first data stays and nothing syncs after deletion', () async {
      final watchlist = [
        {'id': 'tt1', 'kind': 'movie', 'title': 'Local'}
      ];
      SharedPreferences.setMockInitialValues({
        'pikora_watchlist_v1': jsonEncode(watchlist),
        'pikora_media_library_v1': jsonEncode(watchlist),
        'pikora_continue_watching_v1': jsonEncode({
          'movie:tt1': {'position': 42}
        }),
        'orvix_theme_v1': 'dark',
      });
      FlutterSecureStorage.setMockInitialValues(
          {'orvix_torbox_api_token_v1': 'local-torbox'});
      backend.user = me;

      await OrvixAccountService.deleteAccount(currentPassword: 'secret');
      backend.calls.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('pikora_watchlist_v1')!), watchlist);
      expect(jsonDecode(prefs.getString('pikora_media_library_v1')!),
          watchlist);
      expect(prefs.getString('pikora_continue_watching_v1'), isNotNull);
      expect(prefs.getString('orvix_theme_v1'), 'dark');
      expect(
          await const FlutterSecureStorage()
              .read(key: 'orvix_torbox_api_token_v1'),
          'local-torbox');

      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();
      await OrvixAccountService.restoreSignedInState();
      expect(backend.calls.where(cloudCall), isEmpty);
    });

    test('a stale session for the deleted account never counts as signed in',
        () async {
      backend.user = me;
      backend.clearSessionOnDelete = false;
      await OrvixAccountService.deleteAccount(currentPassword: 'secret');
      backend.calls.clear();

      expect(backend.currentUser?.id, 'user-1');
      expect(OrvixAccountService.currentUser, isNull);
      await OrvixAccountService.pushLocalStateIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(backend.calls.where(cloudCall), isEmpty);

      // A different account can still sign in afterwards.
      backend.signInResult = const OrvixAuthResult(
        user: OrvixAccountUser(id: 'user-2', email: 'b@example.com'),
        hasSession: true,
      );
      await OrvixAccountService.signIn(
          email: 'b@example.com', password: 'other');
      expect(OrvixAccountService.currentUser?.id, 'user-2');
    });
  });

  group('cloud merge semantics', () {
    test('first sign-in with no cloud row uploads local state', () async {
      SharedPreferences.setMockInitialValues({
        'pikora_watchlist_v1': jsonEncode([
          {'id': '1', 'kind': 'movie'}
        ]),
        'orvix_preferred_cloud_v1': 'torbox',
        'pikora_source_addons': 'local-only',
      });
      backend.user = const OrvixAccountUser(id: 'user-1');

      await OrvixAccountService.mergeCloudIntoLocal();

      expect(backend.savedStates, hasLength(1));
      final saved = backend.savedStates.single;
      expect(saved.keys.toSet(), {
        'watchlist',
        'library',
        'progress',
        'home_sections',
        'preferred_cloud',
        'preferences',
      });
      expect(saved['watchlist'], [
        {'id': '1', 'kind': 'movie'}
      ]);
      expect(saved['library'], isEmpty);
      expect(saved['progress'], isEmpty);
      expect(saved['home_sections'], isEmpty);
      expect(saved['preferred_cloud'], 'torbox');
      expect(saved['preferences'], {'orvix_preferred_cloud_v1': 'torbox'});
    });

    test('merges cloud and local lists, progress and preferences', () async {
      SharedPreferences.setMockInitialValues({
        'pikora_watchlist_v1': jsonEncode([
          {'id': '1', 'kind': 'movie', 'title': 'Local'},
          {'id': '3', 'kind': 'tv'},
        ]),
        'pikora_continue_watching_v1': jsonEncode({
          'a': {'updatedAt': '2026-01-02T00:00:00Z', 'pos': 'local'},
          'b': {'updatedAt': '2026-01-01T00:00:00Z', 'pos': 'local'},
        }),
        'orvix_theme_v1': 'local',
      });
      backend.user = const OrvixAccountUser(id: 'user-1');
      backend.storedState = {
        'user_id': 'user-1',
        'watchlist': [
          {'id': '1', 'kind': 'movie', 'title': 'Remote'},
          {'id': '2', 'kind': 'movie'},
        ],
        'library': [
          {'id': '9', 'kind': 'tv'}
        ],
        'progress': {
          'a': {'updatedAt': '2026-01-01T00:00:00Z', 'pos': 'remote'},
          'b': {'updatedAt': '2026-01-03T00:00:00Z', 'pos': 'remote'},
          'c': {'updatedAt': '2026-01-01T00:00:00Z', 'pos': 'remote'},
        },
        'preferences': {
          'orvix_theme_v1': 'remote',
          'orvix_new_pref_v1': true,
          'pikora_integrated_torrentio_url_v1': 'remote-only',
          'unrelated_key': 'x',
        },
      };

      await OrvixAccountService.mergeCloudIntoLocal();

      final prefs = await SharedPreferences.getInstance();
      final watchlist = jsonDecode(prefs.getString('pikora_watchlist_v1')!);
      expect(watchlist, [
        {'id': '1', 'kind': 'movie', 'title': 'Local'},
        {'id': '2', 'kind': 'movie'},
        {'id': '3', 'kind': 'tv'},
      ]);
      expect(jsonDecode(prefs.getString('pikora_media_library_v1')!), [
        {'id': '9', 'kind': 'tv'}
      ]);
      final progress =
          jsonDecode(prefs.getString('pikora_continue_watching_v1')!) as Map;
      expect(progress['a']['pos'], 'local');
      expect(progress['b']['pos'], 'remote');
      expect(progress['c']['pos'], 'remote');

      // Existing local preferences win; missing ones are restored; local-only
      // and foreign keys are never restored.
      expect(prefs.getString('orvix_theme_v1'), 'local');
      expect(prefs.getBool('orvix_new_pref_v1'), isTrue);
      expect(prefs.containsKey('pikora_integrated_torrentio_url_v1'), isFalse);
      expect(prefs.containsKey('unrelated_key'), isFalse);

      final saved = backend.savedStates.single;
      expect(saved['watchlist'], watchlist);
      expect(saved['preferred_cloud'], 'pikpak');
      expect(saved['preferences'], containsPair('orvix_theme_v1', 'local'));
      expect(saved['preferences'], containsPair('orvix_new_pref_v1', true));
      expect(
          (saved['preferences'] as Map)
              .containsKey('pikora_integrated_torrentio_url_v1'),
          isFalse);
    });

    test('credentials merge keeps local values and fills missing ones',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'orvix_torbox_api_token_v1': 'local-torbox',
      });
      backend.user = const OrvixAccountUser(id: 'user-1');
      backend.storedCredentials = {
        'orvix_torbox_api_token_v1': 'remote-torbox',
        'pikpak_username': 'remote-user',
        'pikpak_user_id': '',
      };

      await OrvixAccountService.syncCredentialsIfSignedIn();

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'orvix_torbox_api_token_v1'),
          'local-torbox');
      expect(await storage.read(key: 'pikpak_username'), 'remote-user');
      expect(await storage.read(key: 'pikpak_user_id'), isNull);
      expect(backend.savedCredentials.single, {
        'orvix_torbox_api_token_v1': 'local-torbox',
        'pikpak_username': 'remote-user',
      });
    });

    test('credentials are not saved when there are none', () async {
      backend.user = const OrvixAccountUser(id: 'user-1');
      await OrvixAccountService.syncCredentialsIfSignedIn();
      expect(backend.calls, ['loadCredentials']);
    });
  });

  group('TV device login through the backend abstraction', () {
    TvDeviceLoginController controller() => TvDeviceLoginController(
          delay: (_) async {},
          syncAfterSignIn: () async {},
        );

    test('approved login exchanges and signs in', () async {
      final login = controller();
      addTearDown(login.dispose);
      final states = <TvDeviceLoginState>[];
      login.addListener(() => states.add(login.state));
      await login.start();
      expect(states.map((s) => s.phase), [
        TvDeviceLoginPhase.preparing,
        TvDeviceLoginPhase.waiting,
        TvDeviceLoginPhase.signingIn,
        TvDeviceLoginPhase.syncing,
        TvDeviceLoginPhase.signedIn,
      ]);
      expect(states[1].userCode, 'ABC123');
      expect(states[1].verificationUrl, 'https://example.com/tv?code=ABC123');
      expect(backend.calls, [
        'startTv:Orvix Android TV',
        'pollTv:device',
        'exchangeTv:device',
      ]);
      expect(backend.tvToken, 'tv-token');
      expect(OrvixAccountService.currentUser?.id, 'tv-user');
    });

    test('expired login reports expiry', () async {
      backend.pollStatuses
        ..clear()
        ..add('expired');
      final login = controller();
      addTearDown(login.dispose);
      await login.start();
      expect(login.state.phase, TvDeviceLoginPhase.expired);
      expect(backend.tvToken, isNull);
    });

    test('phone approval goes through the backend', () async {
      expect(await TvDeviceLoginService.approve('ABC123'), isTrue);
      expect(await TvDeviceLoginService.approve('ZZZ999'), isFalse);
    });
  });

  group('Supabase adapter wiring', () {
    late List<http.Request> requests;

    SupabaseOrvixAccountBackend adapter(
        http.Response Function(http.Request request) respond) {
      requests = [];
      final client = SupabaseClient(
        'https://orvix.test',
        'publishable-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: _MemoryAuthStorage(),
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          final response = respond(request);
          return http.Response(response.body, response.statusCode,
              headers: response.headers, request: request);
        }),
      );
      return SupabaseOrvixAccountBackend(client: client);
    }

    http.Response json(Object? body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );

    test('user state is read from and upserted to orvix_user_state', () async {
      final backend = adapter((request) =>
          request.method == 'GET' ? json([{'user_id': 'u1', 'library': []}])
              : json([]));

      final state = await backend.loadUserState('u1');
      expect(state, {'user_id': 'u1', 'library': []});
      final get = requests.single;
      expect(get.url.path, '/rest/v1/orvix_user_state');
      expect(get.url.queryParameters['user_id'], 'eq.u1');
      expect(get.url.queryParameters['limit'], '1');

      await backend.saveUserState('u1', {'watchlist': [], 'preferences': {}});
      final post = requests.last;
      expect(post.method, 'POST');
      expect(post.url.path, '/rest/v1/orvix_user_state');
      expect(post.url.queryParameters['on_conflict'], 'user_id');
      expect(post.headers['Prefer'], contains('resolution=merge-duplicates'));
      expect(jsonDecode(post.body),
          {'user_id': 'u1', 'watchlist': [], 'preferences': {}});
    });

    test('missing user state row maps to null', () async {
      final backend = adapter((_) => json([]));
      expect(await backend.loadUserState('u1'), isNull);
    });

    test('credentials use the existing RPCs', () async {
      final backend = adapter((request) =>
          request.url.path.endsWith('load_orvix_credentials')
              ? json({'pikpak_username': 'name', 'pikpak_user_id': null})
              : json(null));

      expect(await backend.loadCredentials(),
          {'pikpak_username': 'name', 'pikpak_user_id': ''});
      expect(requests.single.url.path, '/rest/v1/rpc/load_orvix_credentials');

      await backend.saveCredentials({'pikpak_username': 'name'});
      expect(requests.last.url.path, '/rest/v1/rpc/save_orvix_credentials');
      expect(jsonDecode(requests.last.body), {
        'p_payload': {'pikpak_username': 'name'}
      });
    });

    test('TV login start, poll and approve use the existing RPCs', () async {
      final backend = adapter((request) {
        switch (request.url.pathSegments.last) {
          case 'start_tv_login_session':
            return json([
              {
                'device_code': 'dc',
                'user_code': 'ABC123',
                'verification_uri_complete': 'https://x/tv?code=ABC123',
                'poll_interval_seconds': 5,
              }
            ]);
          case 'poll_tv_login_session':
            return json([
              {'status': 'PENDING'}
            ]);
          default:
            return json(true);
        }
      });

      final start = await backend.startTvLogin(
          deviceNonce: 'nonce', deviceName: 'Orvix Android TV');
      expect(start.deviceCode, 'dc');
      expect(start.userCode, 'ABC123');
      expect(start.pollIntervalSeconds, 5);
      expect(jsonDecode(requests.last.body),
          {'p_device_nonce': 'nonce', 'p_device_name': 'Orvix Android TV'});

      expect(
          await backend.pollTvLogin(deviceCode: 'dc', deviceNonce: 'nonce'),
          'pending');
      expect(jsonDecode(requests.last.body),
          {'p_device_code': 'dc', 'p_device_nonce': 'nonce'});

      expect(await backend.approveTvLogin('ABC123'), isTrue);
      expect(requests.last.url.path, '/rest/v1/rpc/approve_tv_login_session');
      expect(jsonDecode(requests.last.body), {'p_user_code': 'ABC123'});
    });

    test('TV poll without a row, cancel and rate limits', () async {
      final backend = adapter((request) {
        switch (request.url.pathSegments.last) {
          case 'poll_tv_login_session':
            return json([]);
          case 'cancel_tv_login_session':
            return json(true);
          default:
            return json({
              'code': 'P0001',
              'message': 'Too many TV code attempts. Try again later.',
              'details': null,
              'hint': 'tv_login_rate_limited',
            }, 400);
        }
      });

      expect(
          await backend.pollTvLogin(deviceCode: 'dc', deviceNonce: 'wrong'),
          isNull);

      await backend.cancelTvLogin(deviceCode: 'dc', deviceNonce: 'nonce');
      expect(requests.last.url.path, '/rest/v1/rpc/cancel_tv_login_session');
      expect(jsonDecode(requests.last.body),
          {'p_device_code': 'dc', 'p_device_nonce': 'nonce'});

      await expectLater(
        backend.approveTvLogin('ZZZZZZ'),
        throwsA(isA<OrvixTvLoginException>().having(
            (e) => e.kind, 'kind', OrvixTvLoginErrorKind.rateLimited)),
      );
    });

    test('TV exchange maps the Edge Function answers', () async {
      var answer = json({'refresh_token': 'refresh', 'access_token': 'a'});
      final backend = adapter((_) => answer);

      expect(
          await backend.exchangeTvLogin(deviceCode: 'dc', deviceNonce: 'n'),
          'refresh');
      expect(requests.last.url.path, '/functions/v1/tv-login-exchange');
      expect(jsonDecode(requests.last.body),
          {'device_code': 'dc', 'device_nonce': 'n'});

      for (final (response, kind) in [
        (
          json({'error': 'exchange_in_progress'}, 409),
          OrvixTvLoginErrorKind.busy
        ),
        (
          json({'error': 'not_approved_or_expired'}, 409),
          OrvixTvLoginErrorKind.rejected
        ),
        (
          json({'error': 'session_generation_failed'}, 503),
          OrvixTvLoginErrorKind.unavailable
        ),
        (json({'error': 'claim_failed'}, 400), OrvixTvLoginErrorKind.unavailable),
        (json({'msg': 'Invalid JWT'}, 401), OrvixTvLoginErrorKind.configuration),
        (json({}, 200), OrvixTvLoginErrorKind.unavailable),
      ]) {
        answer = response;
        await expectLater(
          backend.exchangeTvLogin(deviceCode: 'dc', deviceNonce: 'n'),
          throwsA(isA<OrvixTvLoginException>()
              .having((e) => e.kind, 'kind', kind)),
        );
      }
    });

    test('invalid TV start response is rejected', () async {
      final backend = adapter((_) => json([]));
      await expectLater(
        backend.startTvLogin(deviceNonce: 'n', deviceName: 'TV'),
        throwsStateError,
      );
    });

    test('sign in maps the Supabase session and user', () async {
      final backend = adapter((_) => json({
            'access_token': 'access',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh',
            'user': {
              'id': 'u1',
              'aud': 'authenticated',
              'email': 'a@example.com',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          }));

      expect(backend.currentUser, isNull);
      final result = await backend.signInWithPassword(
          email: 'a@example.com', password: 'secret1');
      expect(result.hasSession, isTrue);
      expect(result.user?.id, 'u1');
      expect(backend.currentUser?.email, 'a@example.com');
      expect(requests.single.url.path, '/auth/v1/token');
      expect(requests.single.url.queryParameters['grant_type'], 'password');
    });

    test('Supabase auth errors become OrvixAuthException', () async {
      final backend = adapter((_) => json({
            'code': 'invalid_credentials',
            'msg': 'Invalid login credentials',
          }, 400));

      await expectLater(
        backend.signInWithPassword(email: 'a@example.com', password: 'bad'),
        throwsA(isA<OrvixAuthException>()
            .having((e) => e.message, 'message', 'Invalid login credentials')
            .having((e) => e.cause, 'cause', isA<AuthException>())),
      );
    });

    test('email verification uses the email OTP type', () async {
      final backend = adapter((_) => json({'user': null, 'session': null}));
      await backend.verifySignupCode(email: 'a@example.com', token: '123456');
      expect(requests.single.url.path, '/auth/v1/verify');
      expect(jsonDecode(requests.single.body)['type'], 'email');
    });

    final sessionJson = {
      'access_token': 'recovery-access',
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'recovery-refresh',
      'user': {
        'id': 'u1',
        'aud': 'authenticated',
        'email': 'a@example.com',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': {},
        'user_metadata': {},
      },
    };

    http.Response apiError(int status, String code, String message) =>
        http.Response(
          jsonEncode({'code': code, 'msg': message}),
          status,
          headers: {
            'content-type': 'application/json',
            'x-supabase-api-version': '2024-01-01',
          },
        );

    test('password recovery request posts the email without a redirect link',
        () async {
      final backend = adapter((_) => json({}));
      await backend.requestPasswordRecovery(email: 'a@example.com');
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/v1/recover');
      expect(request.url.queryParameters.containsKey('redirect_to'), isFalse);
      expect(jsonDecode(request.body)['email'], 'a@example.com');
    });

    test('recovery code is verified as a recovery OTP', () async {
      final backend = adapter((_) => json(sessionJson));
      await backend.verifyPasswordRecoveryCode(
          email: 'a@example.com', token: '123456');
      final body = jsonDecode(requests.single.body);
      expect(requests.single.url.path, '/auth/v1/verify');
      expect(body['type'], 'recovery');
      expect(body['email'], 'a@example.com');
      expect(body['token'], '123456');
      expect(backend.currentUser?.id, 'u1');
    });

    test('recovery verification without a session is a session failure',
        () async {
      final backend = adapter((_) => json({'user': null, 'session': null}));
      await expectLater(
        backend.verifyPasswordRecoveryCode(
            email: 'a@example.com', token: '123456'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
    });

    test('new password is set with the recovery session, then ended locally',
        () async {
      final backend = adapter((request) => request.url.path == '/auth/v1/user'
          ? json(sessionJson['user'])
          : json(sessionJson));
      await backend.verifyPasswordRecoveryCode(
          email: 'a@example.com', token: '123456');
      await backend.updateRecoveredPassword(newPassword: 'new-secret');
      final update = requests.last;
      expect(update.method, 'PUT');
      expect(update.url.path, '/auth/v1/user');
      expect(update.headers['Authorization'], 'Bearer recovery-access');
      expect(jsonDecode(update.body), {'password': 'new-secret'});

      await backend.endPasswordRecovery();
      expect(backend.currentUser, isNull);
      expect(requests.last.url.path, '/auth/v1/logout');
      expect(requests.last.url.queryParameters['scope'], 'local');
    });

    test('updating the password without a recovery session fails cleanly',
        () async {
      final backend = adapter((_) => json({}));
      await expectLater(
        backend.updateRecoveredPassword(newPassword: 'new-secret'),
        throwsA(isA<OrvixAuthException>().having(
            (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
      );
      expect(requests, isEmpty);
    });

    Future<SupabaseOrvixAccountBackend> signedInAdapter(
        http.Response Function(http.Request request) respond) async {
      final backend = adapter((request) => request.url.path == '/auth/v1/token'
          ? json({...sessionJson, 'access_token': 'signed-in-access'})
          : respond(request));
      await backend.signInWithPassword(
          email: 'a@example.com', password: 'old-secret');
      requests.clear();
      return backend;
    }

    test('password change updates the signed-in user and keeps the session',
        () async {
      final backend =
          await signedInAdapter((_) => json(sessionJson['user']));
      await backend.changePassword(newPassword: 'new-secret');
      final update = requests.single;
      expect(update.method, 'PUT');
      expect(update.url.path, '/auth/v1/user');
      expect(update.headers['Authorization'], 'Bearer signed-in-access');
      expect(jsonDecode(update.body), {'password': 'new-secret'});
      expect(backend.currentUser?.id, 'u1');
    });

    test('password change sends the verification code as the nonce',
        () async {
      final backend =
          await signedInAdapter((_) => json(sessionJson['user']));
      await backend.changePassword(
          newPassword: 'new-secret', verificationCode: '123456');
      expect(jsonDecode(requests.single.body),
          {'password': 'new-secret', 'nonce': '123456'});
      expect(backend.currentUser?.id, 'u1');
    });

    test('verification code request uses reauthenticate', () async {
      final backend = await signedInAdapter((_) => json({}));
      await backend.requestReauthentication();
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/auth/v1/reauthenticate');
      expect(request.headers['Authorization'], 'Bearer signed-in-access');
    });

    group('account deletion', () {
      final confirmSession = {
        ...sessionJson,
        'access_token': 'confirm-access',
        'refresh_token': 'confirm-refresh',
      };

      late List<http.Request> checkRequests;
      late http.Response Function(http.Request request) checkRespond;

      GoTrueClient passwordCheckAuth() => GoTrueClient(
            url: 'https://orvix.test/auth/v1',
            headers: {'apikey': 'publishable-test-key'},
            autoRefreshToken: false,
            httpClient: MockClient((request) async {
              checkRequests.add(request);
              final response = checkRespond(request);
              return http.Response(response.body, response.statusCode,
                  headers: response.headers, request: request);
            }),
          );

      /// A signed-in adapter whose password checks go to [check] and whose
      /// app client requests go to [respond].
      Future<SupabaseOrvixAccountBackend> deletionAdapter({
        http.Response Function(http.Request request)? check,
        http.Response Function(http.Request request)? respond,
      }) async {
        checkRequests = [];
        checkRespond = check ??
            (request) => request.url.path == '/auth/v1/token'
                ? json(confirmSession)
                : json({});
        requests = [];
        final reply = respond ?? (_) => json({'deleted': true});
        final client = SupabaseClient(
          'https://orvix.test',
          'publishable-test-key',
          authOptions: AuthClientOptions(
            autoRefreshToken: false,
            pkceAsyncStorage: _MemoryAuthStorage(),
          ),
          httpClient: MockClient((request) async {
            requests.add(request);
            final response = request.url.path == '/auth/v1/token'
                ? json({...sessionJson, 'access_token': 'signed-in-access'})
                : reply(request);
            return http.Response(response.body, response.statusCode,
                headers: response.headers, request: request);
          }),
        );
        final backend = SupabaseOrvixAccountBackend(
            client: client, passwordCheckAuth: passwordCheckAuth);
        await backend.signInWithPassword(
            email: 'a@example.com', password: 'old-secret');
        requests.clear();
        return backend;
      }

      test('the auth URL is derived from the project URL', () {
        expect(
            SupabaseOrvixAccountBackend.authUrlFor('https://x.supabase.co/rest/v1'),
            'https://x.supabase.co/auth/v1');
      });

      test('the password is checked on a separate client', () async {
        final backend = await deletionAdapter();
        final proof = await backend.verifyCurrentPassword(
            email: 'a@example.com', password: 'current-secret');
        expect(proof.userId, 'u1');
        final check = checkRequests.single;
        expect(check.url.path, '/auth/v1/token');
        expect(check.url.queryParameters['grant_type'], 'password');
        expect(jsonDecode(check.body),
            containsPair('password', 'current-secret'));
        // The app's own session is untouched.
        expect(requests, isEmpty);
        expect(backend.currentUser?.id, 'u1');
        await backend.discardPasswordProof(proof);
      });

      test('a wrong password is invalidCredentials and keeps the session',
          () async {
        final backend = await deletionAdapter(
            check: (_) => apiError(
                400, 'invalid_credentials', 'Invalid login credentials'));
        await expectLater(
          backend.verifyCurrentPassword(
              email: 'a@example.com', password: 'wrong-secret'),
          throwsA(isA<OrvixAuthException>()
              .having((e) => e.kind, 'kind',
                  OrvixAuthErrorKind.invalidCredentials)
              .having((e) => e.message, 'message',
                  isNot(contains('wrong-secret')))),
        );
        expect(requests, isEmpty);
        expect(backend.currentUser?.id, 'u1');
      });

      test('a rate-limited password check is rateLimited', () async {
        final backend = await deletionAdapter(
            check: (_) => apiError(
                429, 'over_request_rate_limit', 'Request rate limit reached'));
        await expectLater(
          backend.verifyCurrentPassword(
              email: 'a@example.com', password: 'current-secret'),
          throwsA(isA<OrvixAuthException>().having(
              (e) => e.kind, 'kind', OrvixAuthErrorKind.rateLimited)),
        );
      });

      test('deletion calls the Edge Function as the confirmed session only',
          () async {
        final backend = await deletionAdapter();
        final proof = await backend.verifyCurrentPassword(
            email: 'a@example.com', password: 'current-secret');
        await backend.deleteAccount(proof);

        final call = requests.first;
        expect(call.method, 'POST');
        expect(call.url.toString(),
            'https://orvix.test/functions/v1/delete-account');
        expect(call.headers['Authorization'], 'Bearer confirm-access');
        // The client never names an account to delete.
        expect(call.body, isEmpty);
        expect(backend.currentUser, isNull);

        await backend.discardPasswordProof(proof);
        expect(checkRequests.last.url.path, '/auth/v1/logout');
        expect(checkRequests.last.headers['Authorization'],
            'Bearer confirm-access');
      });

      test('an already deleted account counts as deleted', () async {
        final backend = await deletionAdapter(
            respond: (_) => json({'error': 'account_not_found'}, 410));
        final proof = await backend.verifyCurrentPassword(
            email: 'a@example.com', password: 'current-secret');
        await backend.deleteAccount(proof);
        expect(backend.currentUser, isNull);
      });

      final failures = <String, (http.Response, OrvixAuthErrorKind)>{
        'a stale password check': (
          json({'error': 'reauthentication_required'}, 401),
          OrvixAuthErrorKind.reauthenticationRequired
        ),
        'a rejected token': (
          json({'error': 'not_authenticated'}, 401),
          OrvixAuthErrorKind.sessionMissing
        ),
        'a server failure': (
          json({'error': 'delete_failed'}, 500),
          OrvixAuthErrorKind.unknown
        ),
        'a cleanup failure': (
          json({'error': 'cleanup_failed'}, 500),
          OrvixAuthErrorKind.unknown
        ),
        'a rate limit': (
          json({'error': 'rate_limited'}, 429),
          OrvixAuthErrorKind.rateLimited
        ),
      };
      failures.forEach((name, expected) {
        test('$name keeps the session and maps to ${expected.$2.name}',
            () async {
          final backend = await deletionAdapter(respond: (_) => expected.$1);
          final proof = await backend.verifyCurrentPassword(
              email: 'a@example.com', password: 'current-secret');
          await expectLater(
            backend.deleteAccount(proof),
            throwsA(isA<OrvixAuthException>()
                .having((e) => e.kind, 'kind', expected.$2)
                .having((e) => e.message, 'message', 'Account deletion failed.')),
          );
          expect(backend.currentUser?.id, 'u1');
          expect(requests.where((r) => r.url.path == '/auth/v1/logout'),
              isEmpty);
        });
      });

      test('a lost response counts as deleted only when the account is gone',
          () async {
        var accountGone = false;
        final backend = await deletionAdapter(
          respond: (request) =>
              throw http.ClientException('Connection closed'),
          check: (request) {
            if (request.url.path == '/auth/v1/token') {
              return json(confirmSession);
            }
            return accountGone
                ? apiError(403, 'user_not_found',
                    'User from sub claim in JWT does not exist')
                : json(sessionJson['user']);
          },
        );
        final proof = await backend.verifyCurrentPassword(
            email: 'a@example.com', password: 'current-secret');
        await expectLater(
          backend.deleteAccount(proof),
          throwsA(isA<OrvixAuthException>()
              .having((e) => e.kind, 'kind', OrvixAuthErrorKind.network)),
        );
        expect(backend.currentUser?.id, 'u1');

        accountGone = true;
        await backend.deleteAccount(proof);
        expect(backend.currentUser, isNull);
      });

      test('a discarded proof cannot delete', () async {
        final backend = await deletionAdapter();
        final proof = await backend.verifyCurrentPassword(
            email: 'a@example.com', password: 'current-secret');
        await backend.discardPasswordProof(proof);
        await expectLater(
          backend.deleteAccount(proof),
          throwsA(isA<OrvixAuthException>().having(
              (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
        );
        expect(requests, isEmpty);
        expect(backend.currentUser?.id, 'u1');
      });
    });

    test('password change without a session fails before any request',
        () async {
      final backend = adapter((_) => json({}));
      for (final request in [
        () => backend.changePassword(newPassword: 'new-secret'),
        backend.requestReauthentication,
      ]) {
        await expectLater(
          request(),
          throwsA(isA<OrvixAuthException>().having(
              (e) => e.kind, 'kind', OrvixAuthErrorKind.sessionMissing)),
        );
      }
      expect(requests, isEmpty);
    });

    final changeErrorKinds = <String, (http.Response, OrvixAuthErrorKind)>{
      'reauthentication needed': (
        apiError(400, 'reauthentication_needed',
            'Password update requires reauthentication'),
        OrvixAuthErrorKind.reauthenticationRequired
      ),
      'invalid or expired reauthentication code': (
        apiError(422, 'reauthentication_not_valid',
            'Nonce has expired or is invalid'),
        OrvixAuthErrorKind.invalidCode
      ),
      'same password': (
        apiError(422, 'same_password',
            'New password should be different from the old password.'),
        OrvixAuthErrorKind.samePassword
      ),
      'weak password': (
        apiError(422, 'weak_password', 'Password should be at least 6 characters.'),
        OrvixAuthErrorKind.weakPassword
      ),
      'expired session': (
        apiError(403, 'session_not_found',
            'Session from session_id claim in JWT does not exist'),
        OrvixAuthErrorKind.sessionMissing
      ),
      'rate limit': (
        apiError(429, 'over_request_rate_limit', 'Request rate limit reached'),
        OrvixAuthErrorKind.rateLimited
      ),
    };
    changeErrorKinds.forEach((name, expected) {
      test('password change: Supabase $name maps to ${expected.$2.name}',
          () async {
        final backend = await signedInAdapter((_) => expected.$1);
        await expectLater(
          backend.changePassword(
              newPassword: 'new-secret', verificationCode: '123456'),
          throwsA(isA<OrvixAuthException>()
              .having((e) => e.kind, 'kind', expected.$2)
              .having((e) => e.message, 'message',
                  isNot(contains('new-secret')))),
        );
        expect(backend.currentUser?.id, 'u1');
      });
    });

    test('verification code rate limits carry the wait time', () async {
      final backend = await signedInAdapter((_) => apiError(
          429,
          'over_email_send_rate_limit',
          'For security purposes, you can only request this after 37 seconds.'));
      await expectLater(
        backend.requestReauthentication(),
        throwsA(isA<OrvixAuthException>()
            .having((e) => e.kind, 'kind', OrvixAuthErrorKind.rateLimited)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 37)),
      );
    });

    test('password change that cannot reach Supabase is a network error',
        () async {
      var offline = false;
      final client = SupabaseClient(
        'https://orvix.test',
        'publishable-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: _MemoryAuthStorage(),
        ),
        httpClient: MockClient((request) async {
          if (offline) throw http.ClientException('Failed host lookup');
          return http.Response(jsonEncode(sessionJson), 200,
              headers: {'content-type': 'application/json'}, request: request);
        }),
      );
      final offlineBackend = SupabaseOrvixAccountBackend(client: client);
      await offlineBackend.signInWithPassword(
          email: 'a@example.com', password: 'old-secret');
      offline = true;
      await expectLater(
        offlineBackend.changePassword(newPassword: 'new-secret'),
        throwsA(isA<OrvixAuthException>()
            .having((e) => e.kind, 'kind', OrvixAuthErrorKind.network)),
      );
      expect(offlineBackend.currentUser?.id, 'u1');
    });

    final errorKinds = <String, (http.Response, OrvixAuthErrorKind)>{
      'expired or invalid code': (
        apiError(403, 'otp_expired', 'Token has expired or is invalid'),
        OrvixAuthErrorKind.invalidCode
      ),
      'email rate limit': (
        apiError(429, 'over_email_send_rate_limit',
            'For security purposes, you can only request this after 42 seconds.'),
        OrvixAuthErrorKind.rateLimited
      ),
      'malformed email': (
        apiError(400, 'validation_failed',
            'Unable to validate email address: invalid format'),
        OrvixAuthErrorKind.invalidEmail
      ),
      'weak password': (
        apiError(422, 'weak_password', 'Password should be at least 6 characters.'),
        OrvixAuthErrorKind.weakPassword
      ),
      'same password': (
        apiError(422, 'same_password',
            'New password should be different from the old password.'),
        OrvixAuthErrorKind.samePassword
      ),
      'other backend error': (
        apiError(400, 'unexpected_failure', 'Something went wrong'),
        OrvixAuthErrorKind.unknown
      ),
    };
    errorKinds.forEach((name, expected) {
      test('Supabase $name maps to ${expected.$2.name}', () async {
        final backend = adapter((_) => expected.$1);
        await expectLater(
          backend.requestPasswordRecovery(email: 'a@example.com'),
          throwsA(isA<OrvixAuthException>()
              .having((e) => e.kind, 'kind', expected.$2)),
        );
      });
    });

    test('rate limits carry the wait time', () async {
      final backend = adapter((_) => apiError(429, 'over_email_send_rate_limit',
          'For security purposes, you can only request this after 42 seconds.'));
      await expectLater(
        backend.requestPasswordRecovery(email: 'a@example.com'),
        throwsA(isA<OrvixAuthException>()
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 42)),
      );
    });

    test('unreachable backend maps to a network error', () async {
      final client = SupabaseClient(
        'https://orvix.test',
        'publishable-test-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: _MemoryAuthStorage(),
        ),
        httpClient: MockClient(
            (_) async => throw http.ClientException('Failed host lookup')),
      );
      await expectLater(
        SupabaseOrvixAccountBackend(client: client)
            .requestPasswordRecovery(email: 'a@example.com'),
        throwsA(isA<OrvixAuthException>()
            .having((e) => e.kind, 'kind', OrvixAuthErrorKind.network)),
      );
    });
  });
}

/// Delegates auth to [_inner] but fails every cloud call.
class _ThrowingCloudBackend extends _FakeBackend {
  _ThrowingCloudBackend(_FakeBackend inner) {
    user = inner.user;
  }

  @override
  Future<Map<String, String>> loadCredentials() async =>
      throw StateError('offline');
}

class _MemoryAuthStorage extends GotrueAsyncStorage {
  final _values = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => _values[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> removeItem({required String key}) async => _values.remove(key);
}
