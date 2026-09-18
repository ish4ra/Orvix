import 'package:shared_preferences/shared_preferences.dart';

class SubtitlePreferencesService {
  SubtitlePreferencesService._();

  static const _fontSizeKey = 'orvix_subtitle_font_size_v1';
  static const _backgroundKey = 'orvix_subtitle_background_v1';
  static const _backgroundOpacityKey = 'orvix_subtitle_background_opacity_v1';
  static const _bottomOffsetKey = 'orvix_subtitle_bottom_offset_v1';
  static const _preferredLanguageKey = 'orvix_subtitle_preferred_language_v1';

  static const double defaultFontSize = 32;
  static const bool defaultBackground = true;
  static const double defaultBackgroundOpacity = .70;
  static const double defaultBottomOffset = 24;
  static const String defaultPreferredLanguage = 'eng';

  static Future<double> fontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_fontSizeKey) ?? defaultFontSize)
        .clamp(18.0, 72.0)
        .toDouble();
  }

  static Future<void> setFontSize(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, value.clamp(18.0, 72.0).toDouble());
  }

  static Future<bool> backgroundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backgroundKey) ?? defaultBackground;
  }

  static Future<void> setBackgroundEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundKey, value);
  }

  static Future<double> backgroundOpacity() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_backgroundOpacityKey) ?? defaultBackgroundOpacity)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  static Future<void> setBackgroundOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _backgroundOpacityKey,
      value.clamp(0.0, 1.0).toDouble(),
    );
  }

  static Future<double> bottomOffset() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_bottomOffsetKey) ?? defaultBottomOffset)
        .clamp(8.0, 220.0)
        .toDouble();
  }

  static Future<void> setBottomOffset(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _bottomOffsetKey,
      value.clamp(8.0, 220.0).toDouble(),
    );
  }

  static Future<String> preferredLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_preferredLanguageKey)?.trim();
    return value == null || value.isEmpty ? defaultPreferredLanguage : value;
  }

  static Future<void> setPreferredLanguage(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = value.trim().toLowerCase();
    await prefs.setString(
      _preferredLanguageKey,
      clean.isEmpty ? defaultPreferredLanguage : clean,
    );
  }

  static Future<void> resetAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fontSizeKey);
    await prefs.remove(_backgroundKey);
    await prefs.remove(_backgroundOpacityKey);
    await prefs.remove(_bottomOffsetKey);
  }
}
