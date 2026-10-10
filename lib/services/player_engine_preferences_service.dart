import 'package:shared_preferences/shared_preferences.dart';

enum PlayerEnginePreference {
  auto,
  exoPlayer,
  mpv,
}

enum PlayerEngineKind {
  exoPlayer,
  mpv,
}

class PlayerEnginePreferencesService {
  PlayerEnginePreferencesService._();

  static const _key = 'orvix_player_engine_v1';

  static Future<PlayerEnginePreference> get() async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_key));
  }

  static Future<void> set(PlayerEnginePreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }

  static PlayerEnginePreference _decode(String? raw) {
    for (final value in PlayerEnginePreference.values) {
      if (value.name == raw) return value;
    }
    return PlayerEnginePreference.auto;
  }
}

class PlayerEngineRouter {
  PlayerEngineRouter._();

  static PlayerEngineKind choose({
    required PlayerEnginePreference preference,
    required bool isAndroid,
    required String url,
    bool isAndroidTv = false,
    String? releaseHint,
    bool aiSinhalaEnabled = false,
  }) {
    if (!isAndroid) return PlayerEngineKind.mpv;

    // AI Sinhala's progressive native-cue path is implemented once in the MPV
    // player and is shared by Android mobile, Android TV, Windows and macOS.
    // When AI Sinhala is enabled it must win over a stale/manual ExoPlayer
    // preference; otherwise Android would silently bypass the same subtitle
    // engine used on the other platforms.
    if (aiSinhalaEnabled) return PlayerEngineKind.mpv;

    switch (preference) {
      case PlayerEnginePreference.exoPlayer:
        return PlayerEngineKind.exoPlayer;
      case PlayerEnginePreference.mpv:
        return PlayerEngineKind.mpv;
      case PlayerEnginePreference.auto:
        break;
    }

    // Auto, and every install without a saved choice, uses ExoPlayer on
    // Android Mobile and Android TV. Orvix's ExoPlayer screen renders embedded
    // and external/OpenSubtitles subtitles itself. AI Sinhala (above) and an
    // explicit MPV choice keep MPV.
    return PlayerEngineKind.exoPlayer;
  }
}
