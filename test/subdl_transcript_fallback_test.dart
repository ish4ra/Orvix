import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SubDL is built in through the Orvix backend', () {
    final online =
        File('lib/services/online_subtitle_service.dart').readAsStringSync();
    final backend =
        File('lib/services/subdl_transcript_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final settings = File('lib/screens/settings_screen.dart').readAsStringSync();

    expect(online, contains('SubDlTranscriptService.searchEnglish('));
    expect(online, contains("provider: 'SubDL'"));
    expect(player, contains('includeTranscriptFallbacks: true'));
    expect(
      backend,
      contains('/functions/v1/subdl-transcript'),
    );
    expect(
      settings,
      contains('does not require users to configure subtitle API keys'),
    );
    expect(settings, isNot(contains('SubDL API key')));
    expect(settings, isNot(contains('Test & save')));
  });

  test('SubDL private API key is not embedded in the client', () {
    final backend =
        File('lib/services/subdl_transcript_service.dart').readAsStringSync();
    final edge =
        File('supabase/functions/subdl-transcript/index.ts').readAsStringSync();

    expect(backend, isNot(contains('SUBDL_API_KEY')));
    expect(backend, isNot(contains('api.subdl.com')));
    expect(edge, contains('Deno.env.get("SUBDL_API_KEY")'));
    expect(edge, contains('https://api.subdl.com'));
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
}
