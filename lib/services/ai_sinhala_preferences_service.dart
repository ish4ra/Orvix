import 'package:shared_preferences/shared_preferences.dart';

class AiSinhalaPreferencesService {
  AiSinhalaPreferencesService._();

  static const _enabledKey = 'orvix_ai_sinhala_enabled_v2';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }
}
