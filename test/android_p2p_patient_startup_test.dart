import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/player_screen.dart';

void main() {
  group('Android local P2P patient startup', () {
    const stream = 'http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0';

    test('local Android torrent is exempt from 30-second startup failure', () {
      expect(PlayerScreen.waitsForLocalTorrent(isAndroid: true, url: stream), isTrue);
      expect(PlayerScreen.waitsForLocalTorrent(isAndroid: true, url: stream.replaceFirst('127.0.0.1', 'localhost')), isTrue);
    });

    test('Windows and other Android stream kinds keep watchdog', () {
      expect(PlayerScreen.waitsForLocalTorrent(isAndroid: false, url: stream), isFalse);
      expect(PlayerScreen.waitsForLocalTorrent(isAndroid: true, url: 'https://example.org/video.mp4'), isFalse);
      expect(PlayerScreen.waitsForLocalTorrent(isAndroid: true, url: 'http://127.0.0.1:8080/video'), isFalse);
    });

    test('local Android torrent disables MPV to ExoPlayer fallback', () {
      final details = File('lib/screens/details_screen.dart').readAsStringSync();
      expect(details, contains('(Platform.isAndroid && localP2p)'));
      expect(details, contains('onStartupFallback: !fallbackToExo ||'));
    });
  });
}
