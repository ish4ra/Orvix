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
    String? releaseHint,
    bool aiSinhalaEnabled = false,
  }) {
    if (!isAndroid) return PlayerEngineKind.mpv;

    switch (preference) {
      case PlayerEnginePreference.exoPlayer:
        return PlayerEngineKind.exoPlayer;
      case PlayerEnginePreference.mpv:
        return PlayerEngineKind.mpv;
      case PlayerEnginePreference.auto:
        break;
    }

    // AI Sinhala and advanced track handling currently live in the MPV player.
    if (aiSinhalaEnabled) return PlayerEngineKind.mpv;

    final uri = Uri.tryParse(url);
    final localP2p = uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port == 11470;

    // Stremio Android uses ExoPlayer/Media3 as its default Android-native
    // playback backend, and Nuvio hands its local torrent HTTP URL to
    // ExoPlayer as well. Orvix already has automatic Exo -> MPV recovery, so
    // prefer Exo for the local P2P transport in Auto mode instead of forcing
    // MPV before the first attempt. Manual MPV still overrides this rule.
    if (localP2p) return PlayerEngineKind.exoPlayer;

    final hint = '${releaseHint ?? ''} ${uri?.path ?? ''}'.toLowerCase();
    final complex = RegExp(
      r'\b(?:hi10p|10bit|10-bit|av1|av01|dovi|dolby[ ._-]?vision|'
      r'truehd|dts-hd|dts:x|flac)\b',
    ).hasMatch(hint);
    final containerPrefersMpv = RegExp(
      r'\.(?:mkv|avi|m2ts|ts|wmv)(?:\?|$)',
    ).hasMatch(uri?.path.toLowerCase() ?? '') ||
        RegExp(r'\b(?:mkv|matroska)\b').hasMatch(hint);
    if (complex || containerPrefersMpv) return PlayerEngineKind.mpv;

    final scheme = uri?.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return PlayerEngineKind.exoPlayer;
    }

    return PlayerEngineKind.mpv;
  }
}
