// Provider credentials (TorBox, Real-Debrid, Premiumize, PikPak) follow the
// Orvix account: connecting uploads right away, disconnecting removes only
// that provider from the account, a new device or TV restores them on
// sign-in, and open Clouds panes notice restored credentials in place.
//
// Every credential value here is a made-up placeholder.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/screens/library_screen.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:orvix/services/tv_device_login_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _torboxKey = 'orvix_torbox_api_token_v1';
const _realDebridKey = 'orvix_real_debrid_token_v1';
const _premiumizeKey = 'orvix_premiumize_token_v1';
const _syncStateKey = 'orvix_credential_sync_state_v1';

const _torboxToken = 'test-torbox-token-AAA';
const _newTorboxToken = 'test-torbox-token-BBB';
const _realDebridToken = 'test-rd-token-CCC';
const _premiumizeToken = 'test-pm-token-DDD';
const _pikpakAccess = 'test-pikpak-access-EEE';
const _pikpakRefresh = 'test-pikpak-refresh-FFF';

const _allSecrets = [
  _torboxToken,
  _newTorboxToken,
  _realDebridToken,
  _premiumizeToken,
  _pikpakAccess,
  _pikpakRefresh,
];

const _me = OrvixAccountUser(id: 'user-1', email: 'viewer@example.com');

/// An account backend whose credential store behaves like the cloud:
/// saveCredentials replaces the stored payload.
class _CloudBackend implements OrvixAccountBackend {
  OrvixAccountUser? user;
  Map<String, String> cloud = {};
  final calls = <String>[];
  final saved = <Map<String, String>>[];
  Object? saveError;
  Object? loadError;
  Completer<void>? saveGate;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<Map<String, String>> loadCredentials() async {
    calls.add('loadCredentials');
    if (loadError != null) throw loadError!;
    return Map<String, String>.from(cloud);
  }

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {
    calls.add('saveCredentials');
    if (saveGate != null) await saveGate!.future;
    if (saveError != null) throw saveError!;
    saved.add(Map<String, String>.from(credentials));
    cloud = Map<String, String>.from(credentials);
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async => null;

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {}

  @override
  Future<OrvixAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    user = _me;
    return const OrvixAuthResult(user: _me, hasSession: true);
  }

  @override
  Future<void> signOut() async => user = null;

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

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The real TorBoxService (secure storage, API-key validation) against a
/// fake TorBox API.
TorBoxService _torbox() => TorBoxService(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/user/me')) {
          return http.Response(
              jsonEncode({
                'success': true,
                'data': {'email': 'torbox-user@example.com'},
              }),
              200);
        }
        return http.Response(jsonEncode({'success': true, 'data': []}), 200);
      }),
    );

LibraryScreen _clouds(TorBoxService torbox) => LibraryScreen(
      pikpak: PikPakService(),
      transfer: PikPakTransferService(),
      torbox: torbox,
      cloudPreferences: CloudPreferencesService(),
      playback: _FakePlayback(),
      // The app rebuilds Clouds after an account change; a no-op here
      // proves the pane notices restored credentials by itself.
      onAuthChanged: () {},
    );

Future<String?> _local(String key) => const FlutterSecureStorage().read(key: key);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrvixAccountBackend originalBackend;
  late _CloudBackend backend;

  setUp(() {
    originalBackend = OrvixAccountService.backend;
    backend = _CloudBackend();
    OrvixAccountService.backend = backend;
    SharedPreferences.setMockInitialValues(
        {'orvix_preferred_cloud_v1': 'torbox'});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    OrvixAccountService.backend = originalBackend;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  group('connect', () {
    test('TorBox connect while signed in uploads the credential at once',
        () async {
      backend.user = _me;
      backend.cloud = {_realDebridKey: _realDebridToken};

      await _torbox().connectWithApiKey(_torboxToken);
      final result =
          await OrvixAccountService.providerConnected(CloudProvider.torbox);

      expect(result, ProviderCredentialSyncResult.synced);
      expect(backend.cloud, {
        _realDebridKey: _realDebridToken,
        _torboxKey: _torboxToken,
      });
    });

    testWidgets('connecting TorBox in Clouds uploads it without Sync now',
        (tester) async {
      backend.user = _me;
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: _clouds(_torbox()))));
      await _settle(tester);
      expect(find.text('Connect TorBox'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'TorBox API key'), _torboxToken);
      await tester.tap(find.text('Connect with API key'));
      await _settle(tester);

      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
      expect(backend.cloud, {_torboxKey: _torboxToken});
    });

    test('not signed in: connecting stays on this device', () async {
      await _torbox().connectWithApiKey(_torboxToken);
      final result =
          await OrvixAccountService.providerConnected(CloudProvider.torbox);
      expect(result, ProviderCredentialSyncResult.localOnly);
      expect(backend.calls, isEmpty);
    });

    test('a reconnected newer key replaces the older cloud key', () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      backend.cloud = {_torboxKey: _torboxToken};
      await OrvixAccountService.syncCredentialsIfSignedIn();

      await const FlutterSecureStorage()
          .write(key: _torboxKey, value: _newTorboxToken);
      await OrvixAccountService.providerConnected(CloudProvider.torbox);
      expect(backend.cloud[_torboxKey], _newTorboxToken);

      // A later full sync keeps the newer key.
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(backend.cloud[_torboxKey], _newTorboxToken);
      expect(await _local(_torboxKey), _newTorboxToken);
    });

    test('a key replaced on another device is adopted, not overwritten',
        () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      backend.cloud = {_torboxKey: _torboxToken};
      await OrvixAccountService.syncCredentialsIfSignedIn();

      // Another device reconnected TorBox with a new key.
      backend.cloud = {_torboxKey: _newTorboxToken};
      final revision = OrvixAccountService.providerCredentialRevision.value;
      await OrvixAccountService.syncCredentialsIfSignedIn();

      expect(await _local(_torboxKey), _newTorboxToken);
      expect(backend.cloud[_torboxKey], _newTorboxToken);
      expect(OrvixAccountService.providerCredentialRevision.value,
          greaterThan(revision));
    });

    test('a token refreshed on this device is uploaded by the next sync',
        () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({
        'pikpak_access_token': _pikpakAccess,
        'pikpak_refresh_token': _pikpakRefresh,
      });
      await OrvixAccountService.syncCredentialsIfSignedIn();

      // PikPak rotated both tokens in the background.
      const storage = FlutterSecureStorage();
      await storage.write(key: 'pikpak_access_token', value: 'test-access-2');
      await storage.write(key: 'pikpak_refresh_token', value: 'test-refresh-2');
      await OrvixAccountService.mergeCloudIntoLocal();

      expect(backend.cloud['pikpak_access_token'], 'test-access-2');
      expect(backend.cloud['pikpak_refresh_token'], 'test-refresh-2');
    });
  });

  group('new device restore', () {
    test('signing in restores the TorBox credential into secure storage',
        () async {
      backend.cloud = {_torboxKey: _torboxToken};

      await OrvixAccountService.signIn(
          email: 'viewer@example.com', password: 'secret1');

      expect(await _local(_torboxKey), _torboxToken);
      expect(await _torbox().isConnected, isTrue);
    });

    testWidgets('an open TorBox pane turns connected after sign-in restores it',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.cloud = {_torboxKey: _torboxToken};
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: _clouds(_torbox()))));
      await _settle(tester);
      expect(find.text('Connect TorBox'), findsOneWidget);

      await tester.runAsync(() => OrvixAccountService.signIn(
          email: 'viewer@example.com', password: 'secret1'));
      await _settle(tester);

      expect(find.text('Connect TorBox'), findsNothing);
      expect(find.text('torbox-user@example.com'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'TorBox API key'), findsNothing);
    });

    testWidgets('Android TV QR sign-in restores TorBox and Clouds shows it',
        (tester) async {
      PlatformProfile.debugAndroidTvOverride = true;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.cloud = {
        _torboxKey: _torboxToken,
        _realDebridKey: _realDebridToken,
        _premiumizeKey: _premiumizeToken,
      };
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: _clouds(_torbox()))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('tv-torbox-api-key')), findsOneWidget);

      // The real controller and its default sync (mergeCloudIntoLocal).
      final login = TvDeviceLoginController(delay: (_) async {});
      addTearDown(login.dispose);
      await tester.runAsync(login.start);
      await _settle(tester);

      expect(login.state.phase, TvDeviceLoginPhase.signedIn);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
      expect(
          await tester.runAsync(() => _local(_realDebridKey)), _realDebridToken);
      expect(
          await tester.runAsync(() => _local(_premiumizeKey)), _premiumizeToken);
      expect(find.byKey(const ValueKey('tv-torbox-api-key')), findsNothing);
      expect(find.byKey(const ValueKey('tv-torbox-refresh')), findsOneWidget);
    });

    testWidgets('account Sync now updates an open TorBox pane',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.user = _me;
      var accountChanges = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            Expanded(
              child: AccountScreen(onAuthChanged: () => accountChanges++),
            ),
            Expanded(child: _clouds(_torbox())),
          ]),
        ),
      ));
      await _settle(tester);
      expect(find.text('Connect TorBox'), findsOneWidget);

      // Connected on another device after this one signed in.
      backend.cloud = {_torboxKey: _torboxToken};
      await tester.ensureVisible(find.text('Sync now'));
      await tester.tap(find.text('Sync now'));
      await _settle(tester);

      expect(accountChanges, 1);
      expect(find.text('Connect TorBox'), findsNothing);
      expect(find.text('torbox-user@example.com'), findsOneWidget);
    });
  });

  group('disconnect', () {
    Future<void> connectAll() async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({
        _torboxKey: _torboxToken,
        _realDebridKey: _realDebridToken,
        _premiumizeKey: _premiumizeToken,
        'pikpak_access_token': _pikpakAccess,
        'pikpak_refresh_token': _pikpakRefresh,
        'pikpak_username': 'pikpak-user@example.com',
      });
      await OrvixAccountService.syncCredentialsIfSignedIn();
      expect(backend.cloud, hasLength(6));
    }

    test('TorBox disconnect removes only TorBox from the account', () async {
      await connectAll();

      await _torbox().logout();
      final result =
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox);

      expect(result, ProviderCredentialSyncResult.synced);
      expect(backend.cloud.containsKey(_torboxKey), isFalse);
      expect(backend.cloud, {
        _realDebridKey: _realDebridToken,
        _premiumizeKey: _premiumizeToken,
        'pikpak_access_token': _pikpakAccess,
        'pikpak_refresh_token': _pikpakRefresh,
        'pikpak_username': 'pikpak-user@example.com',
      });
      expect(await _local(_realDebridKey), _realDebridToken);
    });

    test('a later sync, sign-in or restart does not resurrect TorBox',
        () async {
      await connectAll();
      await _torbox().logout();
      await OrvixAccountService.providerDisconnected(CloudProvider.torbox);

      await OrvixAccountService.syncCredentialsIfSignedIn();
      await OrvixAccountService.mergeCloudIntoLocal();
      await OrvixAccountService.restoreSignedInState();

      expect(await _local(_torboxKey), isNull);
      expect(backend.cloud.containsKey(_torboxKey), isFalse);
    });

    test('an offline disconnect is finished by the next sync', () async {
      await connectAll();
      backend.saveError = Exception('offline');

      await _torbox().logout();
      final result =
          await OrvixAccountService.providerDisconnected(CloudProvider.torbox);
      expect(result, ProviderCredentialSyncResult.failed);
      expect(backend.cloud[_torboxKey], _torboxToken);

      // Startup / Sync now while the cloud still has the old key.
      backend.saveError = null;
      await OrvixAccountService.restoreSignedInState();

      expect(await _local(_torboxKey), isNull);
      expect(backend.cloud.containsKey(_torboxKey), isFalse);
      expect(backend.cloud[_realDebridKey], _realDebridToken);
    });

    test('disconnecting the last provider clears the account copy', () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      await OrvixAccountService.syncCredentialsIfSignedIn();

      await _torbox().logout();
      await OrvixAccountService.providerDisconnected(CloudProvider.torbox);

      expect(backend.saved.last, isEmpty);
      expect(backend.cloud, isEmpty);
    });

    test('a removal from another device is not undone here', () async {
      await connectAll();

      // Another device disconnected TorBox.
      backend.cloud.remove(_torboxKey);
      backend.saved.clear();
      await OrvixAccountService.syncCredentialsIfSignedIn();
      await OrvixAccountService.syncCredentialsIfSignedIn();

      expect(backend.cloud.containsKey(_torboxKey), isFalse);
      expect(backend.saved, isEmpty);
      // This device keeps its working key.
      expect(await _local(_torboxKey), _torboxToken);
    });

    test('reconnecting after a disconnect uploads the new key', () async {
      await connectAll();
      backend.saveError = Exception('offline');
      await _torbox().logout();
      await OrvixAccountService.providerDisconnected(CloudProvider.torbox);
      backend.saveError = null;

      await _torbox().connectWithApiKey(_newTorboxToken);
      await OrvixAccountService.providerConnected(CloudProvider.torbox);
      await OrvixAccountService.syncCredentialsIfSignedIn();

      expect(backend.cloud[_torboxKey], _newTorboxToken);
      expect(await _local(_torboxKey), _newTorboxToken);
    });

    test('a pending removal never touches a different account', () async {
      await connectAll();
      backend.saveError = Exception('offline');
      await _torbox().logout();
      await OrvixAccountService.providerDisconnected(CloudProvider.torbox);
      backend.saveError = null;

      backend.user = const OrvixAccountUser(id: 'user-2');
      backend.cloud = {_torboxKey: 'test-other-account-torbox'};
      await OrvixAccountService.syncCredentialsIfSignedIn();

      expect(backend.cloud[_torboxKey], 'test-other-account-torbox');
    });
  });

  group('every synced provider', () {
    test('Real-Debrid token syncs both ways', () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues(
          {_realDebridKey: _realDebridToken});
      await OrvixAccountService.providerConnected(CloudProvider.realDebrid);
      expect(backend.cloud, {_realDebridKey: _realDebridToken});

      FlutterSecureStorage.setMockInitialValues({});
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(await _local(_realDebridKey), _realDebridToken);

      await const FlutterSecureStorage().delete(key: _realDebridKey);
      await OrvixAccountService.providerDisconnected(CloudProvider.realDebrid);
      expect(backend.cloud, isEmpty);
    });

    test('Premiumize key syncs both ways', () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues(
          {_premiumizeKey: _premiumizeToken});
      await OrvixAccountService.providerConnected(CloudProvider.premiumize);
      expect(backend.cloud, {_premiumizeKey: _premiumizeToken});

      FlutterSecureStorage.setMockInitialValues({});
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(await _local(_premiumizeKey), _premiumizeToken);

      await const FlutterSecureStorage().delete(key: _premiumizeKey);
      await OrvixAccountService.providerDisconnected(CloudProvider.premiumize);
      expect(backend.cloud, isEmpty);
    });

    test('PikPak syncs its portable session, never device-local state',
        () async {
      backend.user = _me;
      FlutterSecureStorage.setMockInitialValues({
        'pikpak_access_token': _pikpakAccess,
        'pikpak_refresh_token': _pikpakRefresh,
        'pikpak_username': 'pikpak-user@example.com',
        'pikpak_user_id': 'pikpak-user-id',
        'pikpak_captcha_token': 'test-captcha',
        'pikpak_device_id': 'test-device-id',
      });
      await OrvixAccountService.providerConnected(CloudProvider.pikpak);

      expect(backend.cloud, {
        'pikpak_access_token': _pikpakAccess,
        'pikpak_refresh_token': _pikpakRefresh,
        'pikpak_username': 'pikpak-user@example.com',
        'pikpak_user_id': 'pikpak-user-id',
      });

      // A new device restores the session without the device-local keys.
      FlutterSecureStorage.setMockInitialValues({});
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(await PikPakService().isSignedIn, isTrue);
      expect(await _local('pikpak_refresh_token'), _pikpakRefresh);
      expect(await _local('pikpak_captcha_token'), isNull);
      expect(await _local('pikpak_device_id'), isNull);

      await PikPakService().logout();
      await OrvixAccountService.providerDisconnected(CloudProvider.pikpak);
      expect(backend.cloud, isEmpty);
    });

    test('credentials of unknown providers in the cloud are kept', () async {
      backend.user = _me;
      backend.cloud = {'future_provider_key': 'test-future'};
      FlutterSecureStorage.setMockInitialValues({_torboxKey: _torboxToken});
      await OrvixAccountService.providerConnected(CloudProvider.torbox);
      expect(backend.cloud, {
        'future_provider_key': 'test-future',
        _torboxKey: _torboxToken,
      });
    });
  });

  group('failures', () {
    test('a failed upload keeps the working local credential', () async {
      backend.user = _me;
      backend.saveError = Exception('network down');

      await _torbox().connectWithApiKey(_torboxToken);
      final result =
          await OrvixAccountService.providerConnected(CloudProvider.torbox);

      expect(result, ProviderCredentialSyncResult.failed);
      expect(await _local(_torboxKey), _torboxToken);
      expect(await _torbox().isConnected, isTrue);

      // Startup or Sync now retries.
      backend.saveError = null;
      await OrvixAccountService.restoreSignedInState();
      expect(backend.cloud, {_torboxKey: _torboxToken});
    });

    test('a failed restore leaves the provider disconnected', () async {
      backend.loadError = Exception('network down');
      await expectLater(
        OrvixAccountService.signIn(
            email: 'viewer@example.com', password: 'secret1'),
        throwsException,
      );
      expect(OrvixAccountService.isSignedIn, isTrue);
      expect(await _torbox().isConnected, isFalse);
      expect(await _local(_syncStateKey), isNull);

      backend.loadError = null;
      backend.cloud = {_torboxKey: _torboxToken};
      await OrvixAccountService.mergeCloudIntoLocal();
      expect(await _torbox().isConnected, isTrue);
    });

    testWidgets('a failed upload is reported without the token',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend.user = _me;
      backend.saveError = Exception('upload rejected for $_torboxToken');
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: _clouds(_torbox()))));
      await _settle(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'TorBox API key'), _torboxToken);
      await tester.tap(find.text('Connect with API key'));
      await _settle(tester);

      expect(find.textContaining('could not be updated'), findsOneWidget);
      expect(find.textContaining(_torboxToken), findsNothing);
      expect(find.text('torbox-user@example.com'), findsOneWidget);
      expect(await tester.runAsync(() => _local(_torboxKey)), _torboxToken);
    });
  });

  test('no credential value reaches logs, errors or plain storage', () async {
    final logs = <String>[];
    final errors = <String>[];
    await runZoned(
      () async {
        final previous = debugPrint;
        debugPrint = (message, {wrapWidth}) => logs.add('$message');
        try {
          backend.user = _me;
          FlutterSecureStorage.setMockInitialValues({
            _torboxKey: _torboxToken,
            _realDebridKey: _realDebridToken,
            _premiumizeKey: _premiumizeToken,
            'pikpak_access_token': _pikpakAccess,
            'pikpak_refresh_token': _pikpakRefresh,
          });
          await OrvixAccountService.syncCredentialsIfSignedIn();
          backend.cloud[_torboxKey] = _newTorboxToken;
          await OrvixAccountService.mergeCloudIntoLocal();

          backend.saveError = Exception('rejected');
          for (final provider in CloudProvider.values) {
            final result =
                await OrvixAccountService.providerConnected(provider);
            errors.add(result.toString());
          }
          backend.loadError = Exception('unreachable');
          try {
            await OrvixAccountService.syncCredentialsIfSignedIn();
          } catch (error) {
            errors.add(error.toString());
          }
        } finally {
          debugPrint = previous;
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => logs.add(line),
      ),
    );

    // The device-local sync bookkeeping holds fingerprints, not values.
    final syncState = await _local(_syncStateKey);
    expect(syncState, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    final plain = [
      for (final key in prefs.getKeys()) '$key=${prefs.get(key)}',
    ].join('\n');

    for (final secret in _allSecrets) {
      for (final text in [...logs, ...errors, syncState!, plain]) {
        expect(text.contains(secret), isFalse,
            reason: 'a credential leaked into "$text"');
      }
    }
  });
}
