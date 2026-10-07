import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/details_screen.dart';
import 'package:orvix/screens/player_screen.dart';
import 'package:orvix/services/catalog_service.dart';
import 'package:orvix/services/cloud_preferences_service.dart';
import 'package:orvix/services/media_state_service.dart';
import 'package:orvix/services/pikpak_service.dart';
import 'package:orvix/services/pikpak_transfer_service.dart';
import 'package:orvix/services/playback_service.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:orvix/services/torbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _movie = MediaItem(
  id: 'tt0113277',
  kind: MediaKind.movie,
  title: 'Heat',
  year: '1995',
);

final _infoHash = 'b' * 40;
const _release = 'Heat.1995.1080p.BluRay.x264-GROUP';

class _OfflineCatalog implements CatalogService {
  @override
  Future<MediaItem?> details(MediaItem item) async => item;

  @override
  Future<void> prefetchDetails(MediaItem item) async {}

  @override
  MediaItem? peekDetails(MediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SignedOutPikPak implements PikPakService {
  @override
  Future<bool> get isSignedIn async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DisconnectedTorBox implements TorBoxService {
  @override
  Future<bool> get isConnected async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlayback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The Stremio-style source provider: one torrent source for the movie.
class _Provider {
  int requests = 0;

  late final client = MockClient((request) async {
    requests++;
    return http.Response(
      jsonEncode({
        'streams': [
          {
            'name': 'Torrentio\n1080p',
            'title': '$_release\nSeeders: 80 Size: 2.1 GB',
            'infoHash': _infoHash,
            'fileIdx': 0,
          },
        ],
      }),
      200,
    );
  });
}

/// The local torrent engine on 127.0.0.1:11470. Live-probe requests fail fast;
/// once [holdCreate] is set, the next torrent creation (the playback resolve)
/// waits until the test releases it.
class _Engine {
  bool holdCreate = false;
  Completer<http.Response>? heldCreate;
  final paths = <String>[];

  late final client = MockClient((request) async {
    paths.add(request.url.path);
    if (request.url.path == '/create') {
      if (!holdCreate) return http.Response('probe disabled', 500);
      holdCreate = false;
      heldCreate = Completer<http.Response>();
      return heldCreate!.future;
    }
    return http.Response('{}', 200);
  });

  void finishCreate() => heldCreate!.complete(
        http.Response(jsonEncode({'guessedFileIdx': 0}), 200),
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Finder sourceRow() => find.textContaining(_release);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Home -> Details -> Find Sources -> choose the torrent -> preparing.
  Future<void> openPreparingSource(
    WidgetTester tester,
    _Provider provider,
    _Engine engine,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (homeContext) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(homeContext).push(
                MaterialPageRoute<void>(
                  builder: (_) => DetailsScreen(
                    item: _movie,
                    catalog: _OfflineCatalog(),
                    pikpak: _SignedOutPikPak(),
                    transfer: PikPakTransferService(),
                    sources: SourceProviderService(client: provider.client),
                    torbox: _DisconnectedTorBox(),
                    cloudPreferences: CloudPreferencesService(),
                    playback: _FakePlayback(),
                    mediaState: MediaStateService(),
                  ),
                ),
              ),
              child: const Text('Home screen'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Home screen'));
    await settle(tester);

    await tester.tap(find.text('Find Sources'));
    await settle(tester);
    expect(sourceRow(), findsWidgets, reason: 'source list is open');

    engine.holdCreate = true;
    await tester.tap(sourceRow().first);
    await settle(tester);
    expect(sourceRow(), findsNothing, reason: 'source sheet closed');
    expect(engine.heldCreate, isNotNull, reason: 'torrent is resolving');
    expect(find.textContaining('Preparing stream'), findsOneWidget);
  }

  Future<void> leaveAndUnmount(WidgetTester tester, _Engine engine) async {
    if (engine.heldCreate?.isCompleted == false) engine.finishCreate();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  for (final backVia in ['system Back', 'on-screen Back']) {
    testWidgets(
        '$backVia while preparing returns to the same source list, not Home',
        (tester) async {
      final provider = _Provider();
      final engine = _Engine();
      await http.runWithClient(() async {
        await openPreparingSource(tester, provider, engine);
        final providerRequests = provider.requests;

        if (backVia == 'system Back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('Back').last);
        }
        await settle(tester);

        expect(find.byType(DetailsScreen), findsOneWidget,
            reason: 'Back must not leave the title');
        expect(sourceRow(), findsWidgets,
            reason: 'the source list is shown again');
        expect(find.textContaining('Preparing stream'), findsNothing);
        expect(provider.requests, providerRequests,
            reason: 'the already-resolved list is reused');

        // The torrent resolve finishes after the user backed out: the player
        // must never open and the abandoned torrent is detached.
        final pathsBefore = engine.paths.length;
        engine.finishCreate();
        await settle(tester);
        expect(find.byType(PlayerScreen), findsNothing);
        expect(
          engine.paths.skip(pathsBefore),
          contains('/$_infoHash/remove'),
        );
        expect(sourceRow(), findsWidgets);
        expect(find.byType(DetailsScreen), findsOneWidget);

        // Back from the source list goes to the title, then Home.
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(sourceRow(), findsNothing);
        expect(find.byType(DetailsScreen), findsOneWidget);
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(find.byType(DetailsScreen), findsNothing);
        expect(find.text('Home screen'), findsOneWidget);

        await leaveAndUnmount(tester, engine);
      }, () => engine.client);
    });
  }

  testWidgets('a single Back while preparing never double-pops',
      (tester) async {
    final provider = _Provider();
    final engine = _Engine();
    await http.runWithClient(() async {
      await openPreparingSource(tester, provider, engine);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(DetailsScreen), findsOneWidget);
      expect(sourceRow(), findsWidgets);

      await leaveAndUnmount(tester, engine);
    }, () => engine.client);
  });

  group('Details wiring the widget tests cannot reach', () {
    final source = File('lib/screens/details_screen.dart').readAsStringSync();

    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNonNegative, reason: signature);
      final next = source.indexOf('\n  Future<', start + signature.length);
      return source.substring(start, next < 0 ? source.length : next);
    }

    test('both player engines refuse to open for a cancelled preparation', () {
      for (final opener in [
        'Future<AndroidExoPlayerResult?> _openExoPlayer(',
        'Future<void> _openMpvPlayer(',
      ]) {
        final text = body(opener);
        final guard = text.indexOf('PlaybackPreparation.throwIfCurrentCancelled()');
        final push = text.indexOf('Navigator.of(context).push');
        expect(guard, isNonNegative, reason: opener);
        expect(guard, lessThan(push), reason: opener);
      }
    });

    test('"Try Again" after no sources asks the providers again', () {
      final text = body('Future<void> _showNoSourcesDialog(');
      expect(text, contains('forceRefresh: true'));
    });
  });
}
