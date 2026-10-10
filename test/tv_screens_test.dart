// Android TV screens: remote (DPAD) traversal, focus visibility and layout at
// TV sizes. The host is not Android, so PlatformProfile.debugAndroidTvOverride
// switches the screens to their TV layouts.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/account_screen.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/screens/home_screen.dart';
import 'package:orvix/screens/library_screen.dart';
import 'package:orvix/screens/media_library_screen.dart';
import 'package:orvix/screens/search_screen.dart';
import 'package:orvix/screens/settings_screen.dart';
import 'package:orvix/screens/sources_screen.dart';
import 'package:orvix/screens/tv_source_browser_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:orvix/tv/tv_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- fakes ----

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ConnectedTorBox implements TorBoxService {
  @override
  Future<bool> get isConnected async => true;

  @override
  Future<TorBoxAccount> account() async =>
      const TorBoxAccount(email: 'viewer@example.com', plan: 'Pro');

  @override
  Future<List<TorBoxItem>> listTorrents({bool fresh = false}) async => const [];

  @override
  Future<List<TorBoxItem>> listWebDownloads({bool fresh = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _movies = <MediaItem>[
  MediaItem(
      id: 'tt0000001',
      kind: MediaKind.movie,
      title: 'First Light',
      year: '2024'),
  MediaItem(
      id: 'tt0000002',
      kind: MediaKind.movie,
      title: 'Second Wind',
      year: '2023'),
  MediaItem(
      id: 'tt0000003', kind: MediaKind.movie, title: 'Third Act', year: '2022'),
  MediaItem(
      id: 'tt0000004',
      kind: MediaKind.movie,
      title: 'Fourth Wall',
      year: '2021'),
  MediaItem(
      id: 'tt0000005',
      kind: MediaKind.movie,
      title: 'Fifth Element of a Very Long Title That Must Not Overflow',
      year: '2020'),
  MediaItem(
      id: 'tt0000006',
      kind: MediaKind.movie,
      title: 'Sixth Sense',
      year: '2019'),
  MediaItem(
      id: 'tt0000007',
      kind: MediaKind.movie,
      title: 'Seventh Seal',
      year: '2018'),
  MediaItem(
      id: 'tt0000008',
      kind: MediaKind.movie,
      title: 'Eighth Day',
      year: '2017'),
  MediaItem(
      id: 'tt0000009',
      kind: MediaKind.movie,
      title: 'Ninth Gate',
      year: '2016'),
  MediaItem(
      id: 'tt0000010',
      kind: MediaKind.movie,
      title: 'Tenth Kingdom',
      year: '2015'),
];

const _series = MediaItem(
  id: 'tt0000100',
  kind: MediaKind.series,
  title: 'A Series With A Rather Long Name For The Television Screen',
  year: '2020–',
  description: 'A long description that should never break the layout. '
      'It keeps going for several sentences so that it needs to be clipped '
      'after a few lines on the details page of the TV interface.',
  genres: ['Drama', 'Mystery'],
  episodes: [
    EpisodeItem(id: 'e1', season: 1, episode: 1, title: 'Pilot'),
    EpisodeItem(id: 'e2', season: 1, episode: 2, title: 'Second'),
    EpisodeItem(id: 'e3', season: 1, episode: 3, title: 'Third'),
    EpisodeItem(id: 'e4', season: 2, episode: 1, title: 'Return'),
  ],
);

class _FakeCatalog extends CatalogService {
  @override
  Future<List<MediaItem>> popularMovies({int limit = 40}) async => _movies;
  @override
  Future<List<MediaItem>> popularSeries({int limit = 40}) async => [_series];
  @override
  Future<List<MediaItem>> topRatedMovies({int limit = 40}) async =>
      _movies.reversed.toList();
  @override
  Future<List<MediaItem>> topRatedSeries({int limit = 40}) async => [_series];
  @override
  Future<List<MediaItem>> search(String query, {int limit = 18}) async =>
      _movies.take(7).toList();
  @override
  Future<MediaItem?> details(MediaItem item) async => item;
  @override
  Future<void> prefetchDetails(MediaItem item) async {}
  @override
  MediaItem? peekDetails(MediaItem item) => null;
}

class _FakeSources extends SourceProviderService {
  @override
  Future<void> prefetch(MediaItem item, {EpisodeItem? episode}) async {}
}

class _FakeMediaState extends MediaStateService {
  @override
  Future<List<ContinueWatchingEntry>> continueWatching(
          {int limit = 20}) async =>
      [
        ContinueWatchingEntry(
          item: _movies[1],
          position: const Duration(minutes: 40),
          duration: const Duration(minutes: 100),
          updatedAt: DateTime(2026, 10, 1),
        ),
        ContinueWatchingEntry(
          item: _series,
          episode: _series.episodes[1],
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 50),
          updatedAt: DateTime(2026, 10, 2),
        ),
      ];
}

/// TV login backend for the Account screen.
class _FakeAccountBackend implements OrvixAccountBackend {
  OrvixAccountUser? user;
  final polls = <String?>[];
  final calls = <String>[];

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) async {
    calls.add('start');
    return const OrvixTvLoginStart(
      deviceCode: 'device',
      userCode: 'ABC234',
      verificationUrl:
          'https://orvix.test/functions/v1/tv-login-link?code=ABC234',
      pollIntervalSeconds: 3,
    );
  }

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('poll');
    return polls.isEmpty ? 'pending' : polls.removeAt(0);
  }

  @override
  Future<void> cancelTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('cancel');
  }

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async =>
      'refresh';

  @override
  Future<void> signInWithTvLoginToken(String token) async {
    user = const OrvixAccountUser(id: 'tv-user', email: 'viewer@example.com');
  }

  @override
  Future<Map<String, dynamic>?> loadUserState(String userId) async => null;

  @override
  Future<void> saveUserState(String userId, Map<String, dynamic> state) async {}

  @override
  Future<Map<String, String>> loadCredentials() async => {};

  @override
  Future<void> saveCredentials(Map<String, String> credentials) async {}

  @override
  Future<void> signOut() async => user = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// -------------------------------------------------------------- helpers ----

const _tvSizes = <Size>[Size(960, 540), Size(1280, 720), Size(1920, 1080)];

void _setSize(WidgetTester tester, [Size size = const Size(960, 540)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _tvApp(Widget screen) => MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB9FF45),
          brightness: Brightness.dark,
        ),
      ),
      home: TvShell(
        destinations: const [
          TvDestination(
              icon: Icons.tv, selectedIcon: Icons.tv, label: 'Screen'),
        ],
        selectedIndex: 0,
        onSelected: (_) {},
        screenBuilder: (_, __) => screen,
      ),
    );

/// Pumps [screen] in the TV shell, collecting layout overflows.
Future<List<String>> _pump(WidgetTester tester, Widget screen,
    {bool app = true}) async {
  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (message.contains('overflowed')) {
      overflows.add(message.split('\n').first);
    } else {
      previous?.call(details);
    }
  };
  try {
    await tester.pumpWidget(app ? _tvApp(screen) : screen);
    await _settle(tester);
  } finally {
    FlutterError.onError = previous;
  }
  return overflows;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

/// Whether the primary focus is [finder]'s widget or inside it.
bool _focusIn(WidgetTester tester, Finder finder) {
  final primary = FocusManager.instance.primaryFocus;
  final context = primary?.context;
  if (context == null || finder.evaluate().isEmpty) return false;
  final target = tester.element(finder);
  if (context == target) return true;
  var found = false;
  context.visitAncestorElements((ancestor) {
    if (ancestor == target) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

void _expectFocus(WidgetTester tester, Finder finder, String reason) {
  expect(_focusIn(tester, finder), isTrue,
      reason: '$reason (focus: ${FocusManager.instance.primaryFocus})');
}

void _expectSingleLine(WidgetTester tester, String label) {
  for (final element in find.text(label).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, isFalse, reason: '"$label" clipped');
    expect(
      paragraph.size.height,
      lessThanOrEqualTo(paragraph.getMinIntrinsicHeight(double.infinity) + .5),
      reason: '"$label" wrapped onto several lines',
    );
    expect(
      paragraph.size.width,
      greaterThanOrEqualTo(
          paragraph.getMaxIntrinsicWidth(double.infinity) - .5),
      reason: '"$label" was squeezed',
    );
  }
}

/// The focused control must be fully on screen.
void _expectFocusVisible(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus!.context!;
  final box = context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final screen = Offset.zero & tester.view.physicalSize;
  expect(
      screen.contains(rect.topLeft) &&
          screen.contains(rect.bottomRight - const Offset(1, 1)),
      isTrue,
      reason: 'focused $rect is outside the screen $screen');
}

bool _imeVisible(WidgetTester tester) => tester.testTextInput.isVisible;

LibraryScreen _clouds({TorBoxService? torbox}) => LibraryScreen(
      pikpak: PikPakService(),
      transfer: PikPakTransferService(),
      torbox: torbox ?? TorBoxService(),
      cloudPreferences: CloudPreferencesService(),
      playback: _FakePlayback(),
      onAuthChanged: () {},
    );

DetailsScreen _details(MediaItem item) => DetailsScreen(
      item: item,
      catalog: _FakeCatalog(),
      pikpak: PikPakService(),
      transfer: PikPakTransferService(),
      sources: _FakeSources(),
      torbox: TorBoxService(),
      cloudPreferences: CloudPreferencesService(),
      playback: _FakePlayback(),
      mediaState: MediaStateService(),
    );

final _sourceResults = <SourceResult>[
  for (var i = 0; i < 6; i++)
    SourceResult(
      provider: 'Provider ${i + 1}',
      title: 'Movie.2024.${i == 0 ? '2160p' : '1080p'}.WEB-DL.H265-GROUP$i',
      resource: 'https://example.test/source-$i.mkv',
      isMagnet: false,
      sortMode: SourceSortMode.quality,
      quality: i == 0 ? '4K' : '1080p',
      seeders: 100 - i,
      peers: 10 + i,
      sizeBytes: 4000000000 - i * 100000000,
    ),
];

void main() {
  late _FakeAccountBackend account;

  setUp(() {
    PlatformProfile.debugAndroidTvOverride = true;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    account = _FakeAccountBackend();
    OrvixAccountService.backend = account;
  });

  tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

  group('Clouds', () {
    // The test font is much wider than the app font, so the one-row tab
    // layout needs a wide screen here; 960x540 is covered by the 2x2 test.
    const wide = Size(1920, 1080);

    testWidgets('all four providers are reachable and readable',
        (tester) async {
      _setSize(tester, wide);
      await _pump(tester, _clouds());

      _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-pikpak')),
          'Clouds starts on the selected provider');
      for (final provider in ['torbox', 'realDebrid', 'premiumize']) {
        await _key(tester, LogicalKeyboardKey.arrowRight);
        _expectFocus(tester, find.byKey(ValueKey('tv-cloud-tab-$provider')),
            'Right reaches $provider');
      }
      for (final label in ['PikPak', 'TorBox', 'Real-Debrid', 'Premiumize']) {
        _expectSingleLine(tester, label);
      }
      // Right at the last tab stays there instead of jumping elsewhere.
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(
          tester,
          find.byKey(const ValueKey('tv-cloud-tab-premiumize')),
          'Right stops at the last provider');
    });

    testWidgets('choosing a provider keeps focus on its tab', (tester) async {
      _setSize(tester, wide);
      await _pump(tester, _clouds());
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('Connect TorBox'), findsOneWidget);
      _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-torbox')),
          'the selected tab keeps focus');
      // Content below receives focus naturally.
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-device')),
          'Down enters the TorBox form');
    });

    testWidgets('TorBox: API key field to Connect with the DPAD',
        (tester) async {
      _setSize(tester, wide);
      await _pump(tester, _clouds());
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.select);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-device')),
          'Device login first');

      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-api-key')),
          'then the API key field');
      expect(_imeVisible(tester), isFalse,
          reason: 'moving onto the field must not open the keyboard');

      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-connect')),
          'Down from the field reaches Connect');
      _expectFocusVisible(tester);

      // Typing: OK opens the keyboard; Done closes it and moves to Connect.
      await _key(tester, LogicalKeyboardKey.arrowUp);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-api-key')),
          'Up returns to the field');
      await _key(tester, LogicalKeyboardKey.select);
      expect(_imeVisible(tester), isTrue, reason: 'OK starts typing');
      tester.testTextInput.enterText('my-api-key');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      expect(_imeVisible(tester), isFalse, reason: 'Done ends typing');
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-connect')),
          'Done moves to Connect');

      // While typing, Down also leaves the field.
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.select);
      expect(_imeVisible(tester), isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_imeVisible(tester), isFalse);
      _expectFocus(tester, find.byKey(const ValueKey('tv-torbox-connect')),
          'Down while typing reaches Connect');
    });

    testWidgets('TorBox connected actions are reachable', (tester) async {
      _setSize(tester, wide);
      SharedPreferences.setMockInitialValues(
          {'orvix_preferred_cloud_v1': 'torbox'});
      await _pump(tester, _clouds(torbox: _ConnectedTorBox()));
      _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-torbox')),
          'starts on the saved provider');
      final refresh = find.byKey(const ValueKey('tv-torbox-refresh'));
      final signOut = find.byKey(const ValueKey('tv-torbox-sign-out'));
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, refresh) || _focusIn(tester, signOut), isTrue,
          reason: 'Down reaches the library actions');
      if (_focusIn(tester, signOut)) {
        await _key(tester, LogicalKeyboardKey.arrowLeft);
        _expectFocus(tester, refresh, 'Left reaches Refresh');
      } else {
        await _key(tester, LogicalKeyboardKey.arrowRight);
        _expectFocus(tester, signOut, 'Right reaches Sign out');
      }
      // Up goes back to the selected provider.
      await _key(tester, LogicalKeyboardKey.arrowUp);
      _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-torbox')),
          'Up returns to the TorBox tab');
    });

    testWidgets('PikPak: username, password, Sign in', (tester) async {
      _setSize(tester, wide);
      await _pump(tester, _clouds());
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(
          tester, find.byKey(const ValueKey('tv-pikpak-username')), 'username');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(
          tester, find.byKey(const ValueKey('tv-pikpak-password')), 'password');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(
          tester, find.byKey(const ValueKey('tv-pikpak-sign-in')), 'Sign in');
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      _expectFocus(tester, find.byKey(const ValueKey('tv-pikpak-username')),
          'Up walks back');
      await _key(tester, LogicalKeyboardKey.arrowUp);
      _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-pikpak')),
          'and back to the provider tabs');
    });

    testWidgets('Real-Debrid and Premiumize: token field to Connect',
        (tester) async {
      _setSize(tester, wide);
      await _pump(tester, _clouds());
      for (final (steps, name) in [(2, 'realDebrid'), (1, 'premiumize')]) {
        for (var i = 0; i < steps; i++) {
          await _key(tester, LogicalKeyboardKey.arrowRight);
        }
        await _key(tester, LogicalKeyboardKey.select);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        _expectFocus(tester, find.byKey(ValueKey('tv-$name-token')), name);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        _expectFocus(
            tester, find.byKey(ValueKey('tv-$name-connect')), '$name Connect');
        await _key(tester, LogicalKeyboardKey.arrowUp);
        await _key(tester, LogicalKeyboardKey.arrowUp);
        _expectFocus(tester, find.byKey(ValueKey('tv-cloud-tab-$name')),
            'back to the $name tab');
      }
    });
  });

  testWidgets('Clouds tabs fall back to a 2x2 grid without squeezing labels',
      (tester) async {
    _setSize(tester);
    await _pump(tester, _clouds());
    final pikpak =
        tester.getRect(find.byKey(const ValueKey('tv-cloud-tab-pikpak')));
    final torbox =
        tester.getRect(find.byKey(const ValueKey('tv-cloud-tab-torbox')));
    final realDebrid =
        tester.getRect(find.byKey(const ValueKey('tv-cloud-tab-realDebrid')));
    for (final label in ['PikPak', 'TorBox', 'Real-Debrid', 'Premiumize']) {
      _expectSingleLine(tester, label);
    }
    final row = torbox.top == pikpak.top && realDebrid.top == pikpak.top;
    _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-pikpak')),
        'starts on PikPak');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    _expectFocus(tester, find.byKey(const ValueKey('tv-cloud-tab-torbox')),
        'Right reaches TorBox');
    if (!row) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(
          tester,
          find.byKey(const ValueKey('tv-cloud-tab-premiumize')),
          'Down reaches Premiumize');
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      _expectFocus(
          tester,
          find.byKey(const ValueKey('tv-cloud-tab-realDebrid')),
          'Left reaches Real-Debrid');
      await _key(tester, LogicalKeyboardKey.select);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-realDebrid-token')),
          'Down leaves the grid into the form');
      await _key(tester, LogicalKeyboardKey.arrowUp);
      _expectFocus(
          tester,
          find.byKey(const ValueKey('tv-cloud-tab-realDebrid')),
          'Up returns to the selected provider');
    }
  });

  group('Account', () {
    testWidgets('waiting QR: code shown, Refresh and Cancel reachable',
        (tester) async {
      _setSize(tester);
      await _pump(tester, AccountScreen(onAuthChanged: () {}));
      expect(find.text('ABC-234'), findsOneWidget);
      expect(find.text('Waiting for approval on your phone…'), findsOneWidget);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-new-code')),
          'Refresh code is focused');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-cancel')),
          'Cancel is reachable');

      // Cancel stops the code; focus moves to the remaining action.
      await _key(tester, LogicalKeyboardKey.select);
      expect(account.calls, contains('cancel'));
      expect(find.text('ABC-234'), findsNothing);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-new-code')),
          'focus recovers after Cancel');
      final polls = account.calls.where((c) => c == 'poll').length;
      await tester.pump(const Duration(seconds: 10));
      expect(account.calls.where((c) => c == 'poll').length, polls,
          reason: 'no polling after Cancel');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('expired QR puts focus on Generate new code', (tester) async {
      _setSize(tester);
      account.polls.add('expired');
      await _pump(tester, AccountScreen(onAuthChanged: () {}));
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('Generate new code'), findsOneWidget);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-new-code')),
          'Generate new code is focused');
      expect(find.byKey(const ValueKey('tv-account-cancel')), findsNothing);
      await _key(tester, LogicalKeyboardKey.select);
      expect(account.calls.where((c) => c == 'start').length, 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('approval signs the TV in and focuses Sync now',
        (tester) async {
      _setSize(tester);
      account.polls.add('approved');
      var authChanges = 0;
      await _pump(tester, AccountScreen(onAuthChanged: () => authChanges++));
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('Account connected'), findsOneWidget);
      expect(authChanges, 1);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-sync')),
          'Sync now is focused after signing in');
    });

    testWidgets('signed in: Sync now and Sign out, no password management',
        (tester) async {
      _setSize(tester);
      account.user =
          const OrvixAccountUser(id: 'u1', email: 'viewer@example.com');
      await _pump(tester, AccountScreen(onAuthChanged: () {}));
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-sync')),
          'Sync now is focused');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-sign-out')),
          'Down reaches Sign out');
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.select);
      _expectFocus(tester, find.byKey(const ValueKey('tv-account-sync')),
          'Sync now keeps focus while syncing');
      expect(find.text('Change password'), findsNothing);
      expect(find.text('Delete account'), findsNothing);
    });

    testWidgets('leaving Account stops the QR login', (tester) async {
      _setSize(tester);
      final active = ValueNotifier(true);
      await _pump(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, value, __) =>
              AccountScreen(active: value, onAuthChanged: () {}),
        ),
      );
      expect(find.text('ABC-234'), findsOneWidget);
      active.value = false;
      await _settle(tester);
      expect(account.calls, contains('cancel'));
      final polls = account.calls.where((c) => c == 'poll').length;
      await tester.pump(const Duration(seconds: 10));
      expect(account.calls.where((c) => c == 'poll').length, polls);

      active.value = true;
      await _settle(tester);
      expect(account.calls.where((c) => c == 'start').length, 2,
          reason: 'returning starts a fresh code');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Search: field to first result and back', (tester) async {
    _setSize(tester);
    await _pump(
      tester,
      SearchScreen(catalog: _FakeCatalog(), onOpen: (_) {}, active: true),
    );
    final field = find.byKey(const ValueKey('tv-search-field'));
    _expectFocus(tester, field, 'Search starts on the field');
    expect(_imeVisible(tester), isFalse);

    await _key(tester, LogicalKeyboardKey.select);
    tester.testTextInput.enterText('light');
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    expect(find.byKey(const ValueKey('tv-search-result-0')), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    _expectFocus(tester, find.byKey(const ValueKey('tv-search-result-0')),
        'Down from the field enters the first result');
    expect(_imeVisible(tester), isFalse);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    _expectFocus(tester, find.byKey(const ValueKey('tv-search-result-1')),
        'Right moves along the results');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    _expectFocus(tester, field, 'Up from the first row returns to the field');
  });

  testWidgets('Home: hero first, rows below, focused cards stay visible',
      (tester) async {
    _setSize(tester);
    await _pump(
      tester,
      HomeScreen(
        catalog: _FakeCatalog(),
        sources: _FakeSources(),
        mediaState: _FakeMediaState(),
        onOpen: (_) {},
        onResume: (_) {},
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    _expectFocus(tester, find.byKey(const ValueKey('tv-home-hero-open')),
        'Home starts on the hero action');

    await _key(tester, LogicalKeyboardKey.arrowDown);
    _expectFocus(tester, find.byKey(const ValueKey('tv-home-continue')),
        'Down enters Continue Watching');
    expect(find.byType(LinearProgressIndicator), findsWidgets,
        reason: 'Continue Watching shows progress');

    await _key(tester, LogicalKeyboardKey.arrowDown);
    _expectFocus(tester, find.byKey(const ValueKey('tv-home-popularMovies')),
        'Down enters the next row');
    for (var i = 0; i < 8; i++) {
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocusVisible(tester);
    }

    // Leaving and coming back to a row restores its item.
    final remembered = FocusManager.instance.primaryFocus;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus, same(remembered));
  });

  testWidgets('Library: filters and titles are reachable', (tester) async {
    _setSize(tester);
    final state = MediaStateService();
    for (final item in [_movies[0], _movies[1], _series]) {
      await state.toggleLibrary(item);
    }
    await _pump(
      tester,
      MediaLibraryScreen(mediaState: state, onOpen: (_) {}),
    );
    _expectFocus(tester, find.byKey(const ValueKey('tv-library-filter-all')),
        'filters first');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.select);
    _expectFocus(tester, find.byKey(const ValueKey('tv-library-filter-movies')),
        'the chosen filter keeps focus');
    expect(find.text(_series.title), findsNothing);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    _expectFocusVisible(tester);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<GridView>(),
      isNotNull,
      reason: 'Down enters the titles',
    );
  });

  group('Details', () {
    testWidgets('movie actions are reachable from Play', (tester) async {
      _setSize(tester);
      await tester.pumpWidget(MaterialApp(home: _details(_movies[0])));
      await _settle(tester);
      _expectFocus(tester, find.byKey(const ValueKey('tv-details-play')),
          'Play is focused');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(tester, find.byKey(const ValueKey('tv-details-sources')),
          'the manual source browser is next to Play');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(
          tester, find.byKey(const ValueKey('tv-details-library')), 'Library');
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(tester, find.byKey(const ValueKey('tv-details-watchlist')),
          'Watchlist');
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('Watchlisted'), findsOneWidget);
      _expectFocus(tester, find.byKey(const ValueKey('tv-details-watchlist')),
          'toggling keeps focus');
    });

    testWidgets('series: seasons and episodes traverse with the DPAD',
        (tester) async {
      _setSize(tester);
      await tester.pumpWidget(MaterialApp(home: _details(_series)));
      await _settle(tester);
      expect(find.text('Play S1 · E1'), findsOneWidget);
      _expectFocus(tester, find.byKey(const ValueKey('tv-details-play')),
          'Play is focused');

      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-season-1')),
          'Down reaches the seasons');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-episode-1-1')),
          'Down reaches the first episode');
      _expectFocusVisible(tester);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(tester, find.byKey(const ValueKey('tv-episode-1-2')),
          'Right moves to the next episode');
      _expectFocusVisible(tester);

      // Another season: its episodes replace the row.
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      _expectFocus(
          tester, find.byKey(const ValueKey('tv-season-2')), 'Season 2 tab');
      await _key(tester, LogicalKeyboardKey.select);
      _expectFocus(tester, find.byKey(const ValueKey('tv-season-2')),
          'selecting a season keeps focus');
      expect(find.byKey(const ValueKey('tv-episode-2-1')), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(const ValueKey('tv-episode-2-1')),
          'Season 2 episode');
    });
  });

  testWidgets('source picker: rows traverse and stay visible', (tester) async {
    _setSize(tester);
    await tester.pumpWidget(MaterialApp(
      home: TvSourceBrowserScreen(
        sources: _FakeSources(),
        item: _movies[0],
        resultsFuture: Future.value(_sourceResults),
        preferFreeP2p: false,
      ),
    ));
    await _settle(tester);
    final rows = find.byWidgetPredicate((widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('tv-source-'));
    expect(rows, findsWidgets);
    expect(find.text('4K'), findsOneWidget, reason: 'quality is shown');
    expect(find.text('100 seeders'), findsOneWidget);
    expect(_focusIn(tester, rows.first), isTrue, reason: 'first source');
    for (var i = 1; i < 5; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, rows.at(0)), isFalse);
      _expectFocusVisible(tester);
    }
  });

  testWidgets('Settings: every tile is reachable and toggles keep focus',
      (tester) async {
    _setSize(tester);
    await _pump(tester, const SettingsScreen());
    _expectFocus(tester, find.byKey(const ValueKey('tv-settings-engine-auto')),
        'engine first');
    await _key(tester, LogicalKeyboardKey.arrowDown);
    _expectFocus(
        tester, find.byKey(const ValueKey('tv-settings-skip')), 'skip tile');
    await _key(tester, LogicalKeyboardKey.select);
    _expectFocus(tester, find.byKey(const ValueKey('tv-settings-skip')),
        'toggle keeps focus');
    for (final key in [
      'tv-settings-language',
      'tv-settings-ai-sinhala',
      'tv-settings-gemini',
    ]) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
      _expectFocus(tester, find.byKey(ValueKey(key)), key);
      _expectFocusVisible(tester);
    }
  });

  testWidgets('no overflow with larger text at 1280x720', (tester) async {
    _setSize(tester, const Size(1280, 720));
    final screens = <String, Widget>{
      'clouds': _clouds(),
      'account': AccountScreen(onAuthChanged: () {}),
      'settings': const SettingsScreen(),
      'sources': SourcesScreen(sources: _FakeSources()),
      'home': HomeScreen(
        catalog: _FakeCatalog(),
        sources: _FakeSources(),
        mediaState: _FakeMediaState(),
        onOpen: (_) {},
        onResume: (_) {},
      ),
    };
    for (final entry in screens.entries) {
      final overflows = await _pump(
        tester,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: entry.value,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      expect(overflows, isEmpty, reason: entry.key);
    }
    await tester.pump(const Duration(seconds: 5));
  });

  group('no overflow at TV sizes', () {
    for (final size in _tvSizes) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        _setSize(tester, size);
        final screens = <String, Widget>{
          'clouds': _clouds(),
          'clouds torbox': _clouds(torbox: _ConnectedTorBox()),
          'account': AccountScreen(onAuthChanged: () {}),
          'search': SearchScreen(catalog: _FakeCatalog(), onOpen: (_) {}),
          'settings': const SettingsScreen(),
          'sources': SourcesScreen(sources: _FakeSources()),
          'library': MediaLibraryScreen(
              mediaState: MediaStateService(), onOpen: (_) {}),
          'home': HomeScreen(
            catalog: _FakeCatalog(),
            sources: _FakeSources(),
            mediaState: _FakeMediaState(),
            onOpen: (_) {},
            onResume: (_) {},
          ),
        };
        for (final entry in screens.entries) {
          final overflows = await _pump(tester, entry.value);
          expect(overflows, isEmpty, reason: entry.key);
          await tester.pumpWidget(const SizedBox());
        }
        account.user = const OrvixAccountUser(id: 'u', email: 'a@b.test');
        expect(
            await _pump(tester, AccountScreen(onAuthChanged: () {})), isEmpty,
            reason: 'account signed in');
        for (final item in [_movies[4], _series]) {
          final overflows = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (details) {
            final message = details.exceptionAsString();
            if (message.contains('overflowed')) {
              overflows.add(message);
            } else {
              previous?.call(details);
            }
          };
          try {
            await tester.pumpWidget(MaterialApp(home: _details(item)));
            await _settle(tester);
          } finally {
            FlutterError.onError = previous;
          }
          expect(overflows, isEmpty, reason: 'details ${item.title}');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    }
  });
}
