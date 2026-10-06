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
        authOptions: const AuthClientOptions(autoRefreshToken: false),
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
