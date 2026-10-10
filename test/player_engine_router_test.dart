import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/player_engine_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Android default player', () {
    for (final tv in [false, true]) {
      final surface = tv ? 'Android TV' : 'Android Mobile';
      test('$surface: Auto uses ExoPlayer for local P2P and HTTP', () {
        for (final url in [
          'http://127.0.0.1:11470/${'a' * 40}/0',
          'https://cdn.example.com/video/master.m3u8',
          'https://cdn.example.com/movie.mkv',
        ]) {
          expect(
            PlayerEngineRouter.choose(
              preference: PlayerEnginePreference.auto,
              isAndroid: true,
              isAndroidTv: tv,
              url: url,
              releaseHint: 'Prison.Break.S01E01.1080p.WEB-DL.x264.mkv',
            ),
            PlayerEngineKind.exoPlayer,
            reason: url,
          );
        }
      });
    }

    test('an install without a saved choice reads as Auto (ExoPlayer)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preference = await PlayerEnginePreferencesService.get();
      expect(preference, PlayerEnginePreference.auto);
      expect(
        PlayerEngineRouter.choose(
          preference: preference,
          isAndroid: true,
          url: 'https://cdn.example.com/movie.mkv',
        ),
        PlayerEngineKind.exoPlayer,
      );
    });

    test('a saved MPV choice is respected and never migrated', () async {
      SharedPreferences.setMockInitialValues({
        'orvix_player_engine_v1': 'mpv',
      });
      final preference = await PlayerEnginePreferencesService.get();
      expect(preference, PlayerEnginePreference.mpv);
      for (final tv in [false, true]) {
        expect(
          PlayerEngineRouter.choose(
            preference: preference,
            isAndroid: true,
            isAndroidTv: tv,
            url: 'http://127.0.0.1:11470/${'a' * 40}/0',
          ),
          PlayerEngineKind.mpv,
        );
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('orvix_player_engine_v1'), 'mpv');
    });

    test('a saved ExoPlayer choice is respected', () async {
      SharedPreferences.setMockInitialValues({
        'orvix_player_engine_v1': 'exoPlayer',
      });
      final preference = await PlayerEnginePreferencesService.get();
      expect(preference, PlayerEnginePreference.exoPlayer);
      expect(
        PlayerEngineRouter.choose(
          preference: preference,
          isAndroid: true,
          url: 'https://cdn.example.com/video.mp4',
        ),
        PlayerEngineKind.exoPlayer,
      );
    });
  });

  test('AI Sinhala keeps MPV on Android Mobile and TV, whatever the choice',
      () {
    for (final preference in PlayerEnginePreference.values) {
      for (final tv in [false, true]) {
        expect(
          PlayerEngineRouter.choose(
            preference: preference,
            isAndroid: true,
            isAndroidTv: tv,
            url: 'https://cdn.example.com/video.mp4',
            aiSinhalaEnabled: true,
          ),
          PlayerEngineKind.mpv,
          reason: '$preference tv=$tv',
        );
      }
    }
  });

  test('Windows and macOS always route to MPV (unchanged)', () {
    for (final preference in PlayerEnginePreference.values) {
      expect(
        PlayerEngineRouter.choose(
          preference: preference,
          isAndroid: false,
          url: 'https://cdn.example.com/master.m3u8',
        ),
        PlayerEngineKind.mpv,
      );
    }
  });
}
