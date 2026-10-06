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

    // ensureRunning() also fails its internal shared start future, which has
    // no listener when probe() is the only caller. Keep that stray error out
    // of the test zone so only probe()'s own outcome is asserted here.
    final done = Completer<LocalTorrentProbeResult>();
    runZonedGuarded(() {
      LocalTorrentService.instance
          .probe(source, retainSession: true)
          .then(done.complete, onError: done.completeError);
    }, (error, stackTrace) {
      if (error is! LocalTorrentException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
    final result = await done.future;

    expect(result.playableNow, isFalse);
    expect(result.bytesReceived, 0);
    expect(result.sampleWindowsPassed, 0);
    expect(result.label, 'No live data');
  });
}
