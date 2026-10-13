import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/player_engine_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Player engine routing on Android: Android TV and Android Mobile have
// separate defaults and separately stored choices. TV Auto is ExoPlayer;
// Mobile Auto stays MPV until the owner approves the phone migration.

const _urls = [
  'http://127.0.0.1:11470/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/0',
  'https://cdn.example.com/video/master.m3u8',
  'https://cdn.example.com/movie.mkv',
  'http://127.0.0.1:40123/media/abc/Movie.2024.mkv',
];

PlayerEngineKind _route(
  PlayerEnginePreference preference, {
  required bool tv,
  String url = 'https://cdn.example.com/movie.mkv',
  bool ai = false,
}) =>
    PlayerEngineRouter.choose(
      preference: preference,
      isAndroid: true,
      isAndroidTv: tv,
      url: url,
      releaseHint: 'Prison.Break.S01E01.1080p.WEB-DL.x264.mkv',
      aiSinhalaEnabled: ai,
    );

void main() {
  tearDown(() => PlatformProfile.debugAndroidTvOverride = null);

  group('Auto', () {
    test('Android TV: Auto plays every source kind in ExoPlayer', () {
      for (final url in _urls) {
        expect(
          _route(PlayerEnginePreference.auto, tv: true, url: url),
          PlayerEngineKind.exoPlayer,
          reason: url,
        );
      }
    });

    test('Android Mobile: Auto stays on MPV for now', () {
      for (final url in _urls) {
        expect(
          _route(PlayerEnginePreference.auto, tv: false, url: url),
          PlayerEngineKind.mpv,
          reason: url,
        );
      }
    });

    test('the defaults are independent per product', () {
      expect(AndroidPlayerDefaults.tvAuto, PlayerEngineKind.exoPlayer);
      expect(AndroidPlayerDefaults.mobileAuto, PlayerEngineKind.mpv,
          reason: 'phones move to ExoPlayer only in a separate, '
              'owner-approved change');
      expect(
        AndroidPlayerDefaults.autoFor(AndroidPlayerSurface.tv),
        AndroidPlayerDefaults.tvAuto,
      );
      expect(
        AndroidPlayerDefaults.autoFor(AndroidPlayerSurface.mobile),
        AndroidPlayerDefaults.mobileAuto,
      );
    });

    test(
        'future phone migration: Auto follows mobileAuto alone, so flipping '
        'that one constant moves phones without touching TV or manual choices',
        () {
      // Auto on Mobile is exactly AndroidPlayerDefaults.mobileAuto…
      expect(
        _route(PlayerEnginePreference.auto, tv: false),
        AndroidPlayerDefaults.mobileAuto,
      );
      // …while explicit choices never depend on it.
      for (final tv in [false, true]) {
        expect(_route(PlayerEnginePreference.mpv, tv: tv),
            PlayerEngineKind.mpv);
        expect(_route(PlayerEnginePreference.exoPlayer, tv: tv),
            PlayerEngineKind.exoPlayer);
      }
    });
  });

  group('explicit choices', () {
    for (final tv in [false, true]) {
      final surface = tv ? 'Android TV' : 'Android Mobile';
      test('$surface: MPV and ExoPlayer choices are respected', () {
        for (final url in _urls) {
          expect(_route(PlayerEnginePreference.mpv, tv: tv, url: url),
              PlayerEngineKind.mpv);
          expect(_route(PlayerEnginePreference.exoPlayer, tv: tv, url: url),
              PlayerEngineKind.exoPlayer);
        }
      });
    }
  });

  test('AI Sinhala keeps MPV on Android Mobile and TV, whatever the choice',
      () {
    for (final preference in PlayerEnginePreference.values) {
      for (final tv in [false, true]) {
        expect(
          _route(preference, tv: tv, ai: true),
          PlayerEngineKind.mpv,
          reason: '$preference tv=$tv',
        );
      }
    }
  });

  test('Windows, macOS and iOS always route to MPV (unchanged)', () {
    for (final preference in PlayerEnginePreference.values) {
      for (final tv in [false, true]) {
        expect(
          PlayerEngineRouter.choose(
            preference: preference,
            isAndroid: false,
            isAndroidTv: tv,
            url: 'https://cdn.example.com/master.m3u8',
          ),
          PlayerEngineKind.mpv,
        );
      }
    }
  });

  group('stored preferences', () {
    test('an install without a saved choice reads as Auto', () async {
      SharedPreferences.setMockInitialValues({});
      for (final surface in AndroidPlayerSurface.values) {
        expect(
          await PlayerEnginePreferencesService.get(surface: surface),
          PlayerEnginePreference.auto,
        );
      }
    });

    test(
        'a v0.7.9 choice (shared key) keeps working on both products and is '
        'never rewritten or deleted', () async {
      for (final saved in ['mpv', 'exoPlayer', 'auto']) {
        SharedPreferences.setMockInitialValues({
          PlayerEnginePreferencesService.legacyKey: saved,
        });
        for (final surface in AndroidPlayerSurface.values) {
          expect(
            (await PlayerEnginePreferencesService.get(surface: surface)).name,
            saved,
          );
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(PlayerEnginePreferencesService.legacyKey), saved);
        expect(prefs.getString(PlayerEnginePreferencesService.tvKey), isNull);
        expect(prefs.getString(PlayerEnginePreferencesService.mobileKey),
            isNull);
      }
    });

    test('a saved MPV choice on TV keeps MPV even though TV Auto is ExoPlayer',
        () async {
      SharedPreferences.setMockInitialValues({
        PlayerEnginePreferencesService.legacyKey: 'mpv',
      });
      final preference = await PlayerEnginePreferencesService.get(
        surface: AndroidPlayerSurface.tv,
      );
      expect(_route(preference, tv: true), PlayerEngineKind.mpv);
    });

    test('choosing on one product never changes the other', () async {
      SharedPreferences.setMockInitialValues({});
      await PlayerEnginePreferencesService.set(
        PlayerEnginePreference.mpv,
        surface: AndroidPlayerSurface.tv,
      );
      await PlayerEnginePreferencesService.set(
        PlayerEnginePreference.exoPlayer,
        surface: AndroidPlayerSurface.mobile,
      );
      expect(
        await PlayerEnginePreferencesService.get(
            surface: AndroidPlayerSurface.tv),
        PlayerEnginePreference.mpv,
      );
      expect(
        await PlayerEnginePreferencesService.get(
            surface: AndroidPlayerSurface.mobile),
        PlayerEnginePreference.exoPlayer,
      );
    });

    test('a product choice takes precedence over the old shared choice',
        () async {
      SharedPreferences.setMockInitialValues({
        PlayerEnginePreferencesService.legacyKey: 'mpv',
        PlayerEnginePreferencesService.tvKey: 'auto',
      });
      expect(
        await PlayerEnginePreferencesService.get(
            surface: AndroidPlayerSurface.tv),
        PlayerEnginePreference.auto,
      );
      expect(
        await PlayerEnginePreferencesService.get(
            surface: AndroidPlayerSurface.mobile),
        PlayerEnginePreference.mpv,
      );
    });

    test('without a surface, the running product is used', () async {
      SharedPreferences.setMockInitialValues({});
      PlatformProfile.debugAndroidTvOverride = true;
      await PlayerEnginePreferencesService.set(PlayerEnginePreference.mpv);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PlayerEnginePreferencesService.tvKey), 'mpv');
      expect(prefs.getString(PlayerEnginePreferencesService.mobileKey), isNull);

      PlatformProfile.debugAndroidTvOverride = false;
      expect(await PlayerEnginePreferencesService.get(),
          PlayerEnginePreference.auto);
    });

    test('an unknown stored value reads as Auto', () async {
      SharedPreferences.setMockInitialValues({
        PlayerEnginePreferencesService.mobileKey: 'vlc',
      });
      expect(
        await PlayerEnginePreferencesService.get(
            surface: AndroidPlayerSurface.mobile),
        PlayerEnginePreference.auto,
      );
    });
  });
}
