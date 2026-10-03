import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orvix/services/ai_sinhala_preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('AI Sinhala starts disabled on a fresh install', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await AiSinhalaPreferencesService.isEnabled(), isFalse);
  });
  test('beta.45 v4 enabled value is not inherited by beta.46', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'orvix_ai_sinhala_enabled_v4': true});
    expect(await AiSinhalaPreferencesService.isEnabled(), isFalse);
  });
  test('explicit beta.46 choice persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AiSinhalaPreferencesService.setEnabled(true);
    expect(await AiSinhalaPreferencesService.isEnabled(), isTrue);
    await AiSinhalaPreferencesService.setEnabled(false);
    expect(await AiSinhalaPreferencesService.isEnabled(), isFalse);
  });
}
