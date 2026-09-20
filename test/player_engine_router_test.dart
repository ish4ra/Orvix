import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/player_engine_preferences_service.dart';

void main() {
  test('Auto uses ExoPlayer first for local P2P stream-server URLs', () {
    final engine = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.auto,
      isAndroid: true,
      url: 'http://127.0.0.1:11470/abc/-1',
      releaseHint: 'Prison.Break.S01E01.1080p.WEB-DL.x264.mkv',
    );

    expect(engine, PlayerEngineKind.exoPlayer);
  });

  test('Auto uses ExoPlayer for ordinary Android HTTP streams', () {
    final engine = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.auto,
      isAndroid: true,
      url: 'https://cdn.example.com/video/master.m3u8',
      releaseHint: 'Episode 1',
    );

    expect(engine, PlayerEngineKind.exoPlayer);
  });

  test('Auto uses MPV for complex release hints', () {
    final engine = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.auto,
      isAndroid: true,
      url: 'https://cdn.example.com/movie.mkv',
      releaseHint: '2160p.DV.TrueHD.DTS-HD',
    );

    expect(engine, PlayerEngineKind.mpv);
  });

  test('Auto keeps MKV on MPV for advanced tracks and subtitles', () {
    final engine = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.auto,
      isAndroid: true,
      url: 'https://cdn.example.com/movie.mkv',
      releaseHint: 'Movie.1080p.WEB-DL.x264.mkv',
    );

    expect(engine, PlayerEngineKind.mpv);
  });

  test('Manual engine preference overrides Auto rules on Android', () {
    final forcedExo = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.exoPlayer,
      isAndroid: true,
      url: 'http://127.0.0.1:11470/abc/-1',
    );
    final forcedMpv = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.mpv,
      isAndroid: true,
      url: 'https://cdn.example.com/master.m3u8',
    );

    expect(forcedExo, PlayerEngineKind.exoPlayer);
    expect(forcedMpv, PlayerEngineKind.mpv);
  });

  test('Non-Android always routes to MPV', () {
    final engine = PlayerEngineRouter.choose(
      preference: PlayerEnginePreference.exoPlayer,
      isAndroid: false,
      url: 'https://cdn.example.com/master.m3u8',
    );

    expect(engine, PlayerEngineKind.mpv);
  });
}
