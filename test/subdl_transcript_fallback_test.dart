import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SubDL is opt-in and used only for AI transcript fallback', () {
    final online =
        File('lib/services/online_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final settings = File('lib/screens/settings_screen.dart').readAsStringSync();

    expect(online, contains('bool includeTranscriptFallbacks = false'));
    expect(online, contains('SubtitleProviderCredentialsService.subDlApiKey()'));
    expect(online, contains("'/api/v1/subtitles'"));
    expect(online, contains("'unpack': '1'"));
    expect(online, contains("provider: 'SubDL'"));
    expect(player, contains('includeTranscriptFallbacks: true'));
    expect(
      settings,
      contains('SubDL transcript fallback'),
    );
  });

  test('SubDL archives are unpacked only into text subtitle formats', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('ZipDecoder().decodeBytes(bytes, verify: true)'));
    expect(service, contains("name.endsWith('.srt')"));
    expect(service, contains("name.endsWith('.vtt')"));
    expect(service, contains("name.endsWith('.ass')"));
    expect(service, contains("name.endsWith('.ssa')"));
    expect(service, contains("name.startsWith('__macosx/')"));
  });

  test('SubDL key is stored in secure storage instead of source code', () {
    final credentials = File(
      'lib/services/subtitle_provider_credentials_service.dart',
    ).readAsStringSync();

    expect(credentials, contains('FlutterSecureStorage'));
    expect(credentials, contains('orvix_subdl_api_key_v1'));
    expect(credentials, isNot(contains('api.subdl.com')));
  });
}
