import 'package:shared_preferences/shared_preferences.dart';

import 'platform_profile.dart';

enum PlayerEnginePreference {
  auto,
  exoPlayer,
  mpv,
}

enum PlayerEngineKind {
  exoPlayer,
  mpv,
}

/// The Android product a player preference belongs to. Android Mobile and
/// Android TV are separate builds with separate defaults, so their saved
/// choices are stored and routed independently.
enum AndroidPlayerSurface { mobile, tv }

/// What "Auto" means on each Android product.
///
/// Android TV: ExoPlayer (Media3). MPV lags on the owner's TV, so the TV
/// player is built around ExoPlayer; MPV stays a manual choice.
///
/// Android Mobile: MPV, for now. ExoPlayer on phones is opt-in until the
/// owner confirms on real devices that it plays the usual sources (Free P2P,
/// debrid and cloud), subtitles, audio tracks, aspect modes and landscape
/// fullscreen. Moving phones to ExoPlayer is the single, separately
/// reviewed change of [mobileAuto] to [PlayerEngineKind.exoPlayer]; manual
/// MPV stays available afterwards. See docs/android-exoplayer.md.
class AndroidPlayerDefaults {
  AndroidPlayerDefaults._();

  static const PlayerEngineKind tvAuto = PlayerEngineKind.exoPlayer;
  static const PlayerEngineKind mobileAuto = PlayerEngineKind.mpv;

  static PlayerEngineKind autoFor(AndroidPlayerSurface surface) =>
      surface == AndroidPlayerSurface.tv ? tvAuto : mobileAuto;
}

class PlayerEnginePreferencesService {
  PlayerEnginePreferencesService._();

  /// The single choice stored by v0.7.9 and earlier, shared by Mobile and
  /// TV. It is still read (never deleted or rewritten) when a product has
  /// no choice of its own, so an existing explicit choice keeps working.
  static const legacyKey = 'orvix_player_engine_v1';
  static const mobileKey = 'orvix_player_engine_android_mobile_v2';
  static const tvKey = 'orvix_player_engine_android_tv_v2';

  static String keyFor(AndroidPlayerSurface surface) =>
      surface == AndroidPlayerSurface.tv ? tvKey : mobileKey;

  /// The saved choice for [surface] (the current product when omitted).
  static Future<PlayerEnginePreference> get({
    AndroidPlayerSurface? surface,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final scoped = prefs.getString(keyFor(surface ?? _currentSurface()));
    if (scoped != null) return _decode(scoped);
    return _decode(prefs.getString(legacyKey));
  }

  /// Saves the choice for [surface] only. The other Android product keeps
  /// its own choice.
  static Future<void> set(
    PlayerEnginePreference value, {
    AndroidPlayerSurface? surface,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyFor(surface ?? _currentSurface()), value.name);
  }

  static AndroidPlayerSurface _currentSurface() => PlatformProfile.isAndroidTv
      ? AndroidPlayerSurface.tv
      : AndroidPlayerSurface.mobile;

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
        return AndroidPlayerDefaults.autoFor(
          isAndroidTv ? AndroidPlayerSurface.tv : AndroidPlayerSurface.mobile,
        );
    }
  }
}
