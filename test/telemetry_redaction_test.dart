import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/telemetry_redaction.dart';

/// The same cases run against the orvix-telemetry Edge Function's copy of
/// these rules (supabase/functions/orvix-telemetry/redact_test.ts).
const _casesPath = 'supabase/functions/orvix-telemetry/redaction_cases.json';

void main() {
  final cases = (jsonDecode(File(_casesPath).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  group('telemetry redaction', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        expect(redactTelemetryText(c['input'] as String), c['expected']);
      });
    }

    test('is stable when applied twice', () {
      for (final c in cases) {
        final once = redactTelemetryText(c['input'] as String);
        expect(redactTelemetryText(once), once, reason: c['name'] as String);
      }
    });

    test('event properties: secret keys are dropped, strings redacted', () {
      final out = redactTelemetryProperties({
        'provider_token': 'fake-token',
        'apiKey': 12345,
        'source': 'https://addon.example.test/torbox=fakeKey/manifest.json',
        'count': 3,
        'ok': true,
      });
      expect(out, {
        'provider_token': '[redacted]',
        'apiKey': '[redacted]',
        'source': 'https://addon.example.test/[redacted]',
        'count': 3,
        'ok': true,
      });
    });
  });

  group('telemetry wiring', () {
    final service =
        File('lib/services/orvix_telemetry_service.dart').readAsStringSync();
    final edge =
        File('supabase/functions/orvix-telemetry/index.ts').readAsStringSync();

    test('the client redacts error text, stacks and properties', () {
      expect(service, contains("'message': redactTelemetryText(message)"));
      expect(service,
          contains("'stack': redactTelemetryText(stack.toString())"));
      expect(service, contains("'error_type': redactTelemetryText(errorType)"));
      expect(service,
          contains("'properties': redactTelemetryProperties(properties)"));
    });

    test('the Edge Function redacts again before storing', () {
      expect(edge, contains('from "./redact.ts"'));
      expect(edge, contains('redactedText(body.message, 1200)'));
      expect(edge, contains('redactedText(body.stack, 6000)'));
      expect(edge, contains('redactedText(body.error_type, 120)'));
      expect(edge, contains('redactProperties(safeProperties(body.properties))'));
    });
  });
}
