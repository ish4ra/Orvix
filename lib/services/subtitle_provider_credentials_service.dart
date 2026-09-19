import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SubtitleProviderCredentialsService {
  SubtitleProviderCredentialsService._();

  static const _storage = FlutterSecureStorage();
  static const _subDlApiKey = 'orvix_subdl_api_key_v1';

  static Future<String?> subDlApiKey() async {
    final value = (await _storage.read(key: _subDlApiKey))?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static Future<bool> hasSubDlApiKey() async => (await subDlApiKey()) != null;

  static Future<void> setSubDlApiKey(String value) async {
    final clean = value.trim();
    if (clean.isEmpty) {
      await _storage.delete(key: _subDlApiKey);
      return;
    }
    await _storage.write(key: _subDlApiKey, value: clean);
  }

  static Future<void> clearSubDlApiKey() async {
    await _storage.delete(key: _subDlApiKey);
  }
}
