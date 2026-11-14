import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/orvix_backend_config.dart';

// A test build may only ever talk to its own Supabase project, and a normal
// build may only ever talk to production. These tests lock both directions.

const _testRef = 'abcdefghijklmnopqrst';
const _testUrl = 'https://$_testRef.supabase.co';
const _testKey = 'sb_publishable_test_key_0123456789';

String _legacyKey(String role, String ref) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'role': role, 'ref': ref})}.sig';
}

OrvixBackend _resolve({
  bool testBuild = true,
  String url = _testUrl,
  String key = _testKey,
}) =>
    OrvixBackendConfig.resolve(
      testBuild: testBuild,
      urlOverride: url,
      keyOverride: key,
    );

void main() {
  final throwsConfigError = throwsA(isA<OrvixBackendConfigError>());

  test('a normal build uses production and is not a test build', () {
    final backend = _resolve(testBuild: false, url: '', key: '');
    expect(backend.url, OrvixBackendConfig.productionUrl);
    expect(backend.publishableKey, OrvixBackendConfig.productionPublishableKey);
    expect(backend.isTest, isFalse);
    expect(OrvixBackendConfig.isTestBuild, isFalse);
    expect(OrvixBackendConfig.current.url, OrvixBackendConfig.productionUrl);
  });

  test('a normal build refuses any override', () {
    expect(() => _resolve(testBuild: false), throwsConfigError);
    expect(() => _resolve(testBuild: false, key: ''), throwsConfigError);
    expect(() => _resolve(testBuild: false, url: ''), throwsConfigError);
  });

  test('a test build uses exactly the project it was given', () {
    final backend = _resolve(url: '$_testUrl/');
    expect(backend.url, _testUrl);
    expect(backend.publishableKey, _testKey);
    expect(backend.isTest, isTrue);
  });

  test('a test build needs both values', () {
    expect(() => _resolve(url: ''), throwsConfigError);
    expect(() => _resolve(key: ''), throwsConfigError);
    expect(() => _resolve(url: '', key: ''), throwsConfigError);
  });

  test('a test build can never reach production', () {
    expect(
      () => _resolve(url: OrvixBackendConfig.productionUrl),
      throwsConfigError,
    );
    expect(
      () => _resolve(key: OrvixBackendConfig.productionPublishableKey),
      throwsConfigError,
    );
  });

  test('only hosted https project addresses are accepted', () {
    for (final url in [
      'http://$_testRef.supabase.co',
      'https://$_testRef.supabase.co.example.com',
      'https://example.com',
      'https://$_testRef.supabase.co/functions/v1',
      '$_testRef.supabase.co',
    ]) {
      expect(() => _resolve(url: url), throwsConfigError, reason: url);
    }
  });

  test('secret and service-role keys are refused', () {
    expect(
        () => _resolve(key: 'sb_secret_abcdefghijklmnop'), throwsConfigError);
    expect(
      () => _resolve(key: _legacyKey('service_role', _testRef)),
      throwsConfigError,
    );
    expect(() => _resolve(key: 'not-a-key'), throwsConfigError);
    expect(() => _resolve(key: 'sb_publishable_'), throwsConfigError);
  });

  test('a legacy anon key must belong to the same project', () {
    expect(_resolve(key: _legacyKey('anon', _testRef)).isTest, isTrue);
    expect(
      () => _resolve(key: _legacyKey('anon', 'zzzzzzzzzzzzzzzzzzzz')),
      throwsConfigError,
    );
  });

  group('source', () {
    final productionRef =
        OrvixBackendConfig.projectRef(OrvixBackendConfig.productionUrl)!;

    // Files that still name the production project directly. Each one must
    // switch itself off in a test build.
    const guarded = {
      'lib/services/ai_audio_stt_service.dart',
      'lib/services/ai_sinhala_subtitle_service.dart',
      'lib/services/subdl_transcript_service.dart',
    };

    test('only known, guarded files name the production project', () {
      final naming = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) => file.readAsStringSync().contains(productionRef))
          .map((file) => file.path.replaceAll(r'\', '/'))
          .toSet();
      expect(naming, {...guarded, 'lib/services/orvix_backend_config.dart'});
      for (final path in guarded) {
        expect(
          File(path).readAsStringSync(),
          contains('OrvixBackendConfig.isTestBuild'),
          reason: path,
        );
      }
    });

    test('the app starts Supabase from the build configuration', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('OrvixBackendConfig.current'));
      expect(main, contains('url: backend.url'));
      expect(main, contains('publishableKey: backend.publishableKey'));
    });

    test('a test build never looks for app updates', () {
      final updater =
          File('lib/services/app_update_service.dart').readAsStringSync();
      expect(
        updater,
        contains('platform() => OrvixBackendConfig.isTestBuild'),
      );
    });
  });
}
