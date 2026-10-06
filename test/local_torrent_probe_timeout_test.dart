import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';

void main() {
  test('probe metadata timeout is a failed probe, not an escaped exception',
      () async {
    const infoHash = '0123456789abcdef0123456789abcdef01234567';
    final removed = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 11470);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/create') {
        // Stall past the probe's short create-torrent deadline.
        await Future<void>.delayed(const Duration(seconds: 3));
      } else if (path.endsWith('/remove')) {
        removed.add(path);
      }
      try {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      } catch (_) {}
    });

    const source = SourceResult(
      provider: 'Test',
      title: 'Slow swarm',
      resource: 'magnet:?xt=urn:btih:$infoHash',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
    );

    final result = await LocalTorrentService.instance.probe(
      source,
      retainSession: true,
    );

    expect(result.playableNow, isFalse);
    expect(result.bytesReceived, 0);
    expect(result.sampleWindowsPassed, 0);
    expect(result.label, 'No live data');
    // The temporary probe session is still cleaned up, not retained.
    expect(removed, contains('/$infoHash/remove'));
  });

  test(
      'probe engine startup failure is a failed probe, not an escaped exception',
      () async {
    // No engine is listening on the local port and this host has no bundled
    // engine to start, so ensureRunning() throws LocalTorrentException.
    const source = SourceResult(
      provider: 'Test',
      title: 'Engine unavailable',
      resource: 'magnet:?xt=urn:btih:89abcdef0123456789abcdef0123456789abcdef',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
    );

    // Awaited directly: the failed startup must surface only as probe()'s
    // own failed result, with no stray uncaught error in the test zone.
    final result = await LocalTorrentService.instance.probe(
      source,
      retainSession: true,
    );

    expect(result.playableNow, isFalse);
    expect(result.bytesReceived, 0);
    expect(result.sampleWindowsPassed, 0);
    expect(result.label, 'No live data');
  });

  group('ensureRunning startup lifecycle', () {
    final service = LocalTorrentService.instance;
    tearDown(() => service.debugStartEngineOverride = null);

    test('a single failed startup is one awaited failure, nothing uncaught',
        () async {
      // No engine listens locally and this host has no bundled engine, so the
      // real startup path fails. Any extra uncaught error fails this test.
      await expectLater(
        service.ensureRunning(),
        throwsA(isA<LocalTorrentException>()),
      );
    });

    test('concurrent callers share one failed startup and each receive it',
        () async {
      var starts = 0;
      final gate = Completer<void>();
      service.debugStartEngineOverride = () {
        starts++;
        return gate.future;
      };

      final first = service.ensureRunning();
      while (starts == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final second = service.ensureRunning();
      // Let the second caller's heartbeat (700 ms timeout) finish so it joins
      // the in-flight startup instead of racing it.
      await Future<void>.delayed(const Duration(seconds: 1));

      final matcher = throwsA(
        isA<LocalTorrentException>()
            .having((e) => e.message, 'message', 'engine failed'),
      );
      final outcomes = [
        expectLater(first, matcher),
        expectLater(second, matcher),
      ];
      gate.completeError(const LocalTorrentException('engine failed'));
      await Future.wait(outcomes);
      expect(starts, 1);
    });

    test('a failed startup is reset so the next call retries', () async {
      var starts = 0;
      service.debugStartEngineOverride = () async {
        starts++;
        if (starts == 1) {
          throw const LocalTorrentException('engine failed');
        }
      };

      await expectLater(
        service.ensureRunning(),
        throwsA(isA<LocalTorrentException>()),
      );
      await service.ensureRunning();
      expect(starts, 2);
    });
  });
}
