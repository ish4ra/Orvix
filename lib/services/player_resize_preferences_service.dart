import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlayerResizeMode {
  fit,
  fill,
  zoom,
}

extension PlayerResizeModeLabel on PlayerResizeMode {
  String get label => switch (this) {
        PlayerResizeMode.fit => 'Fit',
        PlayerResizeMode.fill => 'Fill',
        PlayerResizeMode.zoom => 'Zoom',
      };

  PlayerResizeMode get next => switch (this) {
        PlayerResizeMode.fit => PlayerResizeMode.fill,
        PlayerResizeMode.fill => PlayerResizeMode.zoom,
        PlayerResizeMode.zoom => PlayerResizeMode.fit,
      };

  BoxFit get boxFit => switch (this) {
        PlayerResizeMode.fit => BoxFit.contain,
        PlayerResizeMode.fill => BoxFit.fill,
        PlayerResizeMode.zoom => BoxFit.cover,
      };
}

class PlayerResizePreferencesService {
  PlayerResizePreferencesService._();

  static const _key = 'orvix_player_resize_mode_v1';

  static Future<PlayerResizeMode> load({
    PlayerResizeMode fallback = PlayerResizeMode.fit,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    return PlayerResizeMode.values.firstWhere(
      (mode) => mode.name == stored,
      orElse: () => fallback,
    );
  }

  static Future<void> save(PlayerResizeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
