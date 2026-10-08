// Provider credentials and account state (library, watchlist, progress,
// preferences) sync independently. A failure in one never stops, undoes or
// hides the other, never turns a successful sign-in into a failed one, and
// never shows backend detail.
//
// Every credential value here is a made-up placeholder.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/supabase_orvix_account_backend.dart';
import 'package:orvix/services/tv_device_login_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _torboxKey = 'orvix_torbox_api_token_v1';
const _realDebridKey = 'orvix_real_debrid_token_v1';
const _watchlistKey = 'pikora_watchlist_v1';
const _libraryKey = 'pikora_media_library_v1';
const _progressKey = 'pikora_continue_watching_v1';

const _torboxToken = 'test-torbox-token-ISO1';
const _realDebridToken = 'test-rd-token-ISO2';

/// What a failing backend might say. None of it may reach the UI.
const _backendDetail =
    'PostgrestException(message: permission denied for function '
    'save_orvix_credentials, code: 42501, details: $_torboxToken)';

const _me = OrvixAccountUser(id: 'user-1', email: 'viewer@example.com');

const _cloudItem = {'id': 'tt-cloud', 'kind': 'movie', 'title': 'Cloud'};
const _localItem = {'id': 'tt-local', 'kind': 'movie', 'title': 'Local'};

/// An account backend with a credential store and a user-state store, each
/// of which can be made to fail on its own.
class _Backend implements OrvixAccountBackend {
  OrvixAccountUser? user;
  final calls = <String>[];

  Map<String, String> credentials = {};
  Object? loadCredentialsError;
  Object? saveCredentialsError;

  /// Emulates a credential RPC that merges into the stored payload instead
  /// of replacing it.
  bool mergesCredentials = false;

  /// Emulates a credential RPC that rejects an empty payload.
  bool rejectsEmptyCredentials = false;

  Map<String, dynamic>? state;
  Object? loadStateError;
  Object? saveStateError;
  final savedStates = <Map<String, dynamic>>[];

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    calls.add('signIn');
    user = _me;
    return const OrvixAuthResult(user: _me, hasSession: true);
  }

  @override
  Future<OrvixAuthResult> signUp({
    required String email,
    required String password,
  }) async {
    calls.add('signUp');
    user = _me;
    return const OrvixAuthResult(user: _me, hasSession: true);
  }

  @override
  Future<void> signOut() async => user = null;

  @override
  Future<Map<String, String>> loadCredentials() async {
    calls.add('loadCredentials');
    if (loadCredentialsError != null) throw loadCredentialsError!;
    return Map<String, String>.from(credentials);
  }

  @override
  Future<void> saveCredentials(Map<String, String> payload) async {
    calls.add('saveCredentials');
    if (saveCredentialsError != null) throw saveCredentialsError!;
    if (rejectsEmptyCredentials && payload.isEmpty) {
      throw Exception('payload must not be empty');
    }
    credentials = mergesCredentials
        ? {...credentials, ...payload}
        : Map<String, String>.from(payload);
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async {
    calls.add('loadUserState');
    if (loadStateError != null) throw loadStateError!;
    return state == null ? null : Map<String, dynamic>.from(state!);
  }

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> next) async {
    calls.add('saveUserState');
    if (saveStateError != null) throw saveStateError!;
    savedStates.add(next);
    state = Map<String, dynamic>.from(next);
  }

  // TV QR login: one approved login that signs in as [_me].
  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) async =>
      const OrvixTvLoginStart(
        deviceCode: 'device',
        userCode: 'ABC123',
        verificationUrl: 'https://example.com/tv?code=ABC123',
        pollIntervalSeconds: 2,
      );

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async =>
      'approved';

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async =>
      'tv-session';

  @override
  Future<void> signInWithTvLoginToken(String token) async => user = _me;

  @override
  Future<void> cancelTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Future<String?> _local(String key) =>
    const FlutterSecureStorage().read(key: key);

Future<List<dynamic>> _localList(String key) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(key);
  return raw == null ? const [] : jsonDecode(raw) as List<dynamic>;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrvixAccountBackend originalBackend;
  late _Backend backend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _Backend();
    OrvixAccountService.backend = backend;
    SharedPreferences.setMockInitialValues({
      _watchlistKey: jsonEncode([_localItem]),
      _libraryKey: jsonEncode([_localItem]),
      _progressKey: jsonEncode({
        'tt-local': {'position': 10, 'updatedAt': '2026-10-01T00:00:00Z'}
      }),
      'orvix_theme_v1': 'dark',
    });
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    OrvixAccountService.backend = originalBackend;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  void cloudHasState() {
    backend.state = {
      'watchlist': [_cloudItem],
      'library': [_cloudItem],
      'progress': {
        'tt-cloud': {'position': 20, 'updatedAt': '2026-10-02T00:00:00Z'}
      },
      'preferences': {'orvix_subtitle_size_v1': 'large'},
    };
  }

  group('each part syncs on its own', () {
    test('credential load failure: account state still merges', () async {
      backend.user = _me;
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadCredentialsError = Exception(_backendDetail);

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentials, OrvixSyncStatus.failed);
      expect(result.state, OrvixSyncStatus.synced);
      expect(await _localList(_watchlistKey), hasLength(2));
      expect(await _localList(_libraryKey), hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('orvix_subtitle_size_v1'), 'large');
      expect(backend.savedStates.single['watchlist'], hasLength(2));
      expect(backend.savedStates.single['progress'],
          containsPair('tt-local', isA<Map>()));
      // Nothing was restored, and nothing pretends it was.
      expect(await _local(_torboxKey), isNull);
    });

    test('credential save failure: library, watchlist, progress still push',
        () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      backend.saveCredentialsError = Exception(_backendDetail);

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentialsFailed, isTrue);
      expect(result.state, OrvixSyncStatus.synced);
      final pushed = backend.savedStates.single;
      expect(pushed['watchlist'], [_localItem]);
      expect(pushed['library'], [_localItem]);
      expect(pushed['progress'], contains('tt-local'));
      expect(pushed['preferences'], containsPair('orvix_theme_v1', 'dark'));
      // The working local credential is untouched.
      expect(await _local(_torboxKey), _torboxToken);
    });

    test('state load failure: credentials still restore', () async {
      backend.user = _me;
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadStateError = Exception('state unavailable');
      final revision = OrvixAccountService.providerCredentialRevision.value;

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentials, OrvixSyncStatus.synced);
      expect(result.stateFailed, isTrue);
      expect(await _local(_torboxKey), _torboxToken);
      expect(OrvixAccountService.providerCredentialRevision.value,
          greaterThan(revision));
      expect(await _localList(_watchlistKey), [_localItem]);
    });

    test('state save failure: credentials still upload and stay uploaded',
        () async {
      backend.user = _me;
      cloudHasState();
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      backend.saveStateError = Exception('state rejected');

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentials, OrvixSyncStatus.synced);
      expect(result.stateFailed, isTrue);
      expect(backend.credentials, {_torboxKey: _torboxToken});
      expect(await _local(_torboxKey), _torboxToken);
    });

    test('both failing reports both, throws nothing, keeps local data',
        () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      backend.loadCredentialsError = Exception(_backendDetail);
      backend.loadStateError = Exception(_backendDetail);

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentialsFailed && result.stateFailed, isTrue);
      expect(result.problem, 'Your cloud data did not sync.');
      expect(await _local(_torboxKey), _torboxToken);
      expect(await _localList(_watchlistKey), [_localItem]);
    });

    test('a later sync retries only what failed and finishes it', () async {
      backend.user = _me;
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadCredentialsError = Exception('offline');
      expect(
          (await OrvixAccountService.mergeCloudIntoLocal()).credentialsFailed,
          isTrue);
      expect(await _local(_torboxKey), isNull);

      backend.loadCredentialsError = null;
      final retry = await OrvixAccountService.mergeCloudIntoLocal();
      expect(retry.hasFailure, isFalse);
      expect(retry.problem, isNull);
      expect(await _local(_torboxKey), _torboxToken);
    });

    test('a fully successful sync runs exactly as before', () async {
      backend.user = _me;
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};

      final result = await OrvixAccountService.mergeCloudIntoLocal();

      expect(result.credentials, OrvixSyncStatus.synced);
      expect(result.state, OrvixSyncStatus.synced);
      expect(result.problem, isNull);
      expect(
          backend.calls, ['loadCredentials', 'loadUserState', 'saveUserState']);
      expect(await _local(_torboxKey), _torboxToken);
    });

    test('signed out syncs nothing and reports it as skipped', () async {
      final result = await OrvixAccountService.mergeCloudIntoLocal();
      expect(result.credentials, OrvixSyncStatus.skipped);
      expect(result.state, OrvixSyncStatus.skipped);
      expect(result.hasFailure, isFalse);
      expect(backend.calls, isEmpty);
    });
  });

  group('sign-in is not a sync', () {
    test('sign-in succeeds when only the credential sync fails', () async {
      backend.loadCredentialsError = Exception(_backendDetail);
      cloudHasState();

      final result = await OrvixAccountService.signIn(
          email: 'viewer@example.com', password: 'secret1');

      expect(result.hasSession, isTrue);
      expect(OrvixAccountService.isSignedIn, isTrue);
      expect(result.sync?.credentialsFailed, isTrue);
      expect(result.sync?.state, OrvixSyncStatus.synced);
      expect(await _localList(_watchlistKey), hasLength(2));
    });

    test('sign-up with a session reports its sync the same way', () async {
      backend.saveStateError = Exception(_backendDetail);
      final result = await OrvixAccountService.signUp(
          email: 'viewer@example.com', password: 'secret1');
      expect(result.hasSession, isTrue);
      expect(result.sync?.stateFailed, isTrue);
      expect(result.sync?.credentials, OrvixSyncStatus.synced);
    });

    // Windows and Android Mobile share this sign-in path; Android Mobile only
    // adds Scan TV QR next to Sync now. The compact width stays above the
    // point where the square test font makes the account buttons overflow.
    for (final (name, size) in [
      ('Windows', const Size(1400, 1000)),
      ('Android Mobile', const Size(560, 960)),
    ]) {
      testWidgets(
          '$name: sign-in shows a sync warning, never a sign-in failure',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        backend.loadCredentialsError = Exception(_backendDetail);
        var authChanges = 0;
        await tester.pumpWidget(MaterialApp(
          home:
              Scaffold(body: AccountScreen(onAuthChanged: () => authChanges++)),
        ));

        await tester.enterText(
            find.widgetWithText(TextField, 'Email'), 'viewer@example.com');
        await tester.enterText(
            find.widgetWithText(TextField, 'Password'), 'secret1');
        await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
        await _settle(tester);

        expect(OrvixAccountService.isSignedIn, isTrue);
        expect(authChanges, 1);
        expect(find.text('Cloud sync active'), findsOneWidget);
        expect(find.textContaining('Signed in.'), findsOneWidget);
        expect(find.textContaining('cloud provider connections did not'),
            findsOneWidget);
        expect(
            find.textContaining('Use Sync now to try again'), findsOneWidget);
        expect(find.textContaining('Could not connect'), findsNothing);
        expect(find.textContaining('PostgrestException'), findsNothing);
        expect(find.textContaining(_torboxToken), findsNothing);
      });
    }

    testWidgets('a fully synced sign-in keeps the original message',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountScreen(onAuthChanged: () {})),
      ));
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'viewer@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret1');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await _settle(tester);

      expect(
          find.text('Signed in. Your local and cloud Orvix data were merged.'),
          findsOneWidget);
    });
  });

  group('Sync now', () {
    Future<void> pumpSignedIn(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.user = _me;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountScreen(onAuthChanged: () {})),
      ));
      await _settle(tester);
    }

    Future<void> syncNow(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Sync now'));
      await tester.tap(find.text('Sync now'));
      await _settle(tester);
    }

    testWidgets('reports the failed part and retries it next time',
        (tester) async {
      await pumpSignedIn(tester);
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadCredentialsError = Exception(_backendDetail);

      await syncNow(tester);
      expect(find.textContaining('cloud provider connections did not'),
          findsOneWidget);
      expect(find.textContaining('Sync complete'), findsNothing);
      expect(find.textContaining('PostgrestException'), findsNothing);
      expect(find.textContaining('42501'), findsNothing);
      expect(find.textContaining(_torboxToken), findsNothing);
      expect(
          await tester.runAsync(() => _localList(_watchlistKey)), hasLength(2));

      backend.loadCredentialsError = null;
      await syncNow(tester);
      expect(find.textContaining('Sync complete'), findsOneWidget);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
    });

    testWidgets('an account data failure is reported, credentials stay synced',
        (tester) async {
      await pumpSignedIn(tester);
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadStateError = Exception(_backendDetail);

      await syncNow(tester);
      expect(
          find.textContaining(
              'library, watchlist, progress and settings did not'),
          findsOneWidget);
      expect(find.textContaining('PostgrestException'), findsNothing);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
    });
  });

  group('Android TV QR login', () {
    testWidgets(
        'a credential restore failure keeps the TV signed in and syncs state',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadCredentialsError = Exception(_backendDetail);

      // The real controller and its default sync (mergeCloudIntoLocal).
      final login = TvDeviceLoginController(delay: (_) async {});
      addTearDown(login.dispose);
      await tester.runAsync(login.start);

      expect(login.state.phase, TvDeviceLoginPhase.syncFailed);
      expect(login.state.signedIn, isTrue);
      expect(OrvixAccountService.isSignedIn, isTrue);
      expect(login.state.message, contains('cloud provider connections'));
      expect(login.state.message, isNot(contains('PostgrestException')));
      // Library, watchlist, progress and preferences still arrived.
      expect(
          await tester.runAsync(() => _localList(_watchlistKey)), hasLength(2));
      expect(backend.savedStates, hasLength(1));
      expect(await tester.runAsync(() => _local(_torboxKey)), isNull);
    });

    testWidgets('a state failure keeps the restored TorBox credential',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadStateError = Exception(_backendDetail);

      final login = TvDeviceLoginController(delay: (_) async {});
      addTearDown(login.dispose);
      await tester.runAsync(login.start);

      expect(login.state.phase, TvDeviceLoginPhase.syncFailed);
      expect(login.state.signedIn, isTrue);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
      expect(backend.credentials, {_torboxKey: _torboxToken});
    });

    testWidgets('Sync now on the TV retries and clears the login warning',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      cloudHasState();
      backend.credentials = {_torboxKey: _torboxToken};
      backend.loadCredentialsError = Exception(_backendDetail);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountScreen(onAuthChanged: () {})),
      ));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(OrvixAccountService.isSignedIn, isTrue);
      expect(find.textContaining('cloud provider connections did not'),
          findsOneWidget);

      backend.loadCredentialsError = null;
      await tester.tap(find.byKey(const ValueKey('tv-account-sync')));
      await _settle(tester);

      expect(find.textContaining('cloud provider connections did not'),
          findsNothing);
      expect(find.textContaining('Sync complete'), findsOneWidget);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
    });
  });

  group('credential payload semantics', () {
    test('every save sends the complete credential set', () async {
      backend.user = _me;
      backend.credentials = {
        _torboxKey: _torboxToken,
        _realDebridKey: _realDebridToken,
        'future_provider_token_v1': 'test-future-token',
      };
      await OrvixAccountService.mergeCloudIntoLocal();
      backend.calls.clear();

      await const FlutterSecureStorage().delete(key: _torboxKey);
      expect(
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox),
          ProviderCredentialSyncResult.synced);
      // Real-Debrid and the unknown provider stay; TorBox is gone, not merged.
      expect(backend.credentials, {
        _realDebridKey: _realDebridToken,
        'future_provider_token_v1': 'test-future-token',
      });
    });

    test('the final disconnect saves an empty set and clears the account',
        () async {
      backend.user = _me;
      backend.credentials = {_torboxKey: _torboxToken};
      await OrvixAccountService.mergeCloudIntoLocal();

      await const FlutterSecureStorage().delete(key: _torboxKey);
      expect(
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox),
          ProviderCredentialSyncResult.synced);
      expect(backend.credentials, isEmpty);
      expect(await OrvixAccountService.backend.loadCredentials(), isEmpty);
    });

    test('a store that merges is caught and the removal stays pending',
        () async {
      backend.user = _me;
      backend.mergesCredentials = true;
      backend.credentials = {
        _torboxKey: _torboxToken,
        _realDebridKey: _realDebridToken,
      };
      await OrvixAccountService.mergeCloudIntoLocal();

      await const FlutterSecureStorage().delete(key: _torboxKey);
      expect(
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox),
          ProviderCredentialSyncResult.failed);
      // The merging store still holds TorBox, but this device never gets it
      // back, however often it syncs.
      for (var i = 0; i < 2; i++) {
        final result = await OrvixAccountService.mergeCloudIntoLocal();
        expect(result.credentialsFailed, isTrue);
        expect(await _local(_torboxKey), isNull);
      }
      expect(await _local(_realDebridKey), _realDebridToken);

      // Once the store replaces again, the pending removal goes through.
      backend.mergesCredentials = false;
      final fixed = await OrvixAccountService.mergeCloudIntoLocal();
      expect(fixed.hasFailure, isFalse);
      expect(backend.credentials, {_realDebridKey: _realDebridToken});
    });

    test('a store that rejects an empty set keeps the removal pending',
        () async {
      backend.user = _me;
      backend.rejectsEmptyCredentials = true;
      backend.credentials = {_torboxKey: _torboxToken};
      await OrvixAccountService.mergeCloudIntoLocal();

      await const FlutterSecureStorage().delete(key: _torboxKey);
      expect(
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox),
          ProviderCredentialSyncResult.failed);
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(await _local(_torboxKey), isNull);
    });

    test('the Supabase adapter never sends a user id to the credential RPCs',
        () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://orvix.test',
        'publishable-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            request.url.path.endsWith('load_orvix_credentials') ? '{}' : 'null',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final adapter = SupabaseOrvixAccountBackend(client: client);

      expect(await adapter.loadCredentials(), isEmpty);
      await adapter.saveCredentials(const {});

      expect(requests.map((r) => r.url.path), [
        '/rest/v1/rpc/load_orvix_credentials',
        '/rest/v1/rpc/save_orvix_credentials',
      ]);
      // The account is whoever the session belongs to; the body is only the
      // complete payload, and an empty payload is sent as {}.
      expect(
          jsonDecode(requests.last.body), {'p_payload': <String, dynamic>{}});
      for (final request in requests) {
        expect(request.url.queryParameters.keys, isNot(contains('user_id')));
        expect(request.body, isNot(contains('user')));
      }
    });
  });

  test('no credential or backend detail reaches logs or results', () async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add('$message');
    addTearDown(() => debugPrint = previous);

    backend.user = _me;
    FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
    backend.saveCredentialsError = Exception(_backendDetail);
    backend.saveStateError = Exception(_backendDetail);
    final result = await OrvixAccountService.mergeCloudIntoLocal();

    expect(result.hasFailure, isTrue);
    expect(logs, isNotEmpty);
    for (final text in [...logs, result.problem!]) {
      expect(text, isNot(contains(_torboxToken)));
      expect(text, isNot(contains('PostgrestException')));
      expect(text, isNot(contains('save_orvix_credentials')));
    }
  });
}
