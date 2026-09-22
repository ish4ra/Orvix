import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/local_torrent_service.dart';

void main() {
  group('LocalTorrentService magnet preparation', () {
    test('strips Orvix-only metadata before native engine handoff', () {
      const raw =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&tr=udp%3A%2F%2Ftracker.example%3A80%2Fannounce'
          '&x-orvix-file-idx=3'
          '&x-orvix-file-name=Episode.mkv'
          '&x-orvix-video-size=123456789';

      final normalized = LocalTorrentService.normalizeMagnetForEngine(raw);

      expect(normalized, contains('xt=urn:btih:'));
      expect(normalized, contains('tr=udp%3A%2F%2Ftracker.example'));
      expect(normalized, isNot(contains('x-orvix-')));
    });

    test('prepends bundled FFmpeg tools to the Windows stream-server PATH', () {
      final environment = LocalTorrentService.windowsStreamServerEnvironment(
        r'C:\\Apps\\Orvix',
        baseEnvironment: <String, String>{
          'Path': r'C:\\Windows\\System32;C:\\Windows',
          'TEMP': r'C:\\Temp',
        },
      );

      expect(
        environment['Path'],
        r'C:\\Apps\\Orvix\\tools\\ffmpeg\\bin;C:\\Windows\\System32;C:\\Windows',
      );
      expect(environment['TEMP'], r'C:\\Temp');
    });

    test('keeps provider tracker and adds fallback trackers without duplicates', () {
      final duplicateFallback = Uri.encodeQueryComponent(
        LocalTorrentService.fallbackTrackers.first,
      );
      final raw =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&tr=udp%3A%2F%2Ftracker.example%3A80%2Fannounce'
          '&tr=$duplicateFallback';

      final trackers = LocalTorrentService.trackerUrlsForMagnet(raw);

      expect(trackers, contains('udp://tracker.example:80/announce'));
      for (final fallback in LocalTorrentService.fallbackTrackers) {
        expect(trackers, contains(fallback));
      }
      expect(
        trackers
            .where(
              (tracker) =>
                  tracker.toLowerCase() ==
                  LocalTorrentService.fallbackTrackers.first.toLowerCase(),
            )
            .length,
        1,
      );
    });
  });
}
