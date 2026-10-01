import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AiTranslationCredentialsService {
  AiTranslationCredentialsService._();

  static const _storage = FlutterSecureStorage();
  static const _geminiKey = 'orvix_ai_gemini_api_key_v1';

  static Future<String?> geminiApiKey() async {
    final value = (await _storage.read(key: _geminiKey))?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<bool> hasGeminiApiKey() async =>
      (await geminiApiKey()) != null;

  static Future<void> setGeminiApiKey(String value) async {
    final clean = value.trim();
    if (clean.isEmpty) {
      await _storage.delete(key: _geminiKey);
      return;
    }
    await _storage.write(key: _geminiKey, value: clean);
  }

  static Future<void> clearGeminiApiKey() =>
      _storage.delete(key: _geminiKey);
}
