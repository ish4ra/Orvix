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
    test('approved login exchanges and signs in', () async {
      final states = <TvDeviceLoginState>[];
      await TvDeviceLoginService.run(
        onState: states.add,
        isCancelled: () => false,
      );
      expect(states.map((s) => s.phase), [
        TvDeviceLoginPhase.starting,
        TvDeviceLoginPhase.waiting,
        TvDeviceLoginPhase.signingIn,
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
      final states = <TvDeviceLoginState>[];
      await TvDeviceLoginService.run(
        onState: states.add,
        isCancelled: () => false,
      );
      expect(states.last.phase, TvDeviceLoginPhase.expired);
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
