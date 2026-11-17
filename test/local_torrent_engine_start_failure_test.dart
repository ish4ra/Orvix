import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/local_torrent_service.dart';

// A source check can only say "ENGINE ERROR". The reason the engine could
// not start must stay available, so the source list can say whether the
// engine is missing from the installation or merely failed to answer.
void main() {
  final service = LocalTorrentService.instance;

  tearDown(() => service.debugStartEngineOverride = null);

  test('the reason of a failed engine start is kept for the source list',
      () async {
    service.debugStartEngineOverride = () async {
      throw const LocalTorrentException(
        'The Orvix torrent engine is missing from this installation. '
        'Reinstall the latest Orvix build.',
      );
    };
    await expectLater(service.ensureRunning(), throwsA(isA<LocalTorrentException>()));
    expect(service.engineStartFailure, contains('missing from this installation'));
  });

  test('an unexpected failure still gives a readable reason', () async {
    service.debugStartEngineOverride = () async => throw StateError('boom');
    await expectLater(service.ensureRunning(), throwsStateError);
    expect(service.engineStartFailure, 'The local torrent engine could not be started.');
    expect(service.engineStartFailure, isNot(contains('boom')));
  });

  test('the source list shows the reason and still offers a re-check', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    expect(
      details,
      contains('No source delivered live data. Choose one manually or re-check.'),
    );
    expect(details, contains('engineStartFailure} Re-check to try again.'));
  });

  test('macOS looks for the engine inside the app bundle', () {
    final source =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    expect(source, contains("bundledMacName = 'orvix-stream-server'"));
    expect(
      source,
      contains('The Orvix torrent engine is missing from this installation.'),
    );
  });
}
