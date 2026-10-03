import 'package:shared_preferences/shared_preferences.dart';

class AiSinhalaPreferencesService {
  AiSinhalaPreferencesService._();

  // AI Sinhala is opt-in. Fresh installs and users who have never made an
  // explicit choice must start disabled on every platform. Use a new key so
  // older Windows migration behavior cannot silently enable the feature.
  // beta.46 uses a fresh opt-in key so an accidental enabled v4 value from
  // earlier betas cannot silently turn the feature on after updating.
  static const _enabledKey = 'orvix_ai_sinhala_enabled_v5';
  static const _syncPrefix = 'orvix_ai_sinhala_sync_v1_';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_enabledKey)) {
      return prefs.getBool(_enabledKey) ?? false;
    }

    // Do not inherit the old v2/v3 auto-enable migration. A user must
    // explicitly turn AI Sinhala on in Settings.
    await prefs.setBool(_enabledKey, false);
    return false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  static Future<int> syncOffsetMs(String subtitleKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_syncKey(subtitleKey)) ?? 0;
  }

  static Future<void> setSyncOffsetMs(
      String subtitleKey, int milliseconds) async {
    final prefs = await SharedPreferences.getInstance();
    final value = milliseconds.clamp(-120000, 120000).toInt();
    if (value == 0) {
      await prefs.remove(_syncKey(subtitleKey));
    } else {
      await prefs.setInt(_syncKey(subtitleKey), value);
    }
  }

  static String _syncKey(String subtitleKey) {
    final safe = subtitleKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return '$_syncPrefix$safe';
  }
}
