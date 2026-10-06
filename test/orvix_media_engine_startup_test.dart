import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/orvix_media_engine_service.dart';

void main() {
  group('OrvixMediaEngineService.ensureRunning startup lifecycle', () {
    final service = OrvixMediaEngineService.instance;
    tearDown(() => service.debugStartEngineOverride = null);

    test('a single failed startup is one awaited failure, nothing uncaught',
        () async {
      // No engine listens locally and this host has no bundled engine, so the
      // real startup path fails. Any extra uncaught error fails this test.
      await expectLater(
        service.ensureRunning(),
        throwsA(
          isA<OrvixMediaEngineException>().having(
            (e) => e.message,
            'message',
            'The standalone Orvix media engine is missing from this installation. Reinstall the latest Orvix build.',
          ),
        ),
      );
    });

    test('concurrent callers share one failed startup and each receive it',
        () async {
      var starts = 0;
      final gate = Completer<void>();
      service.debugStartEngineOverride = () {
        starts++;
        return gate.future;
      };

      final first = service.ensureRunning();
      while (starts == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final second = service.ensureRunning();
      // Let the second caller's heartbeat (700 ms timeout) finish so it joins
      // the in-flight startup instead of racing it.
      await Future<void>.delayed(const Duration(seconds: 1));

      final matcher = throwsA(
        isA<OrvixMediaEngineException>()
            .having((e) => e.message, 'message', 'engine failed'),
      );
      final outcomes = [
        expectLater(first, matcher),
        expectLater(second, matcher),
      ];
      gate.completeError(const OrvixMediaEngineException('engine failed'));
      await Future.wait(outcomes);
      expect(starts, 1);
    });

    test('a failed startup is reset so the next call retries', () async {
      var starts = 0;
      service.debugStartEngineOverride = () async {
        starts++;
        if (starts == 1) {
          throw const OrvixMediaEngineException('engine failed');
        }
      };

      await expectLater(
        service.ensureRunning(),
        throwsA(isA<OrvixMediaEngineException>()),
      );
      await service.ensureRunning();
      expect(starts, 2);
    });
  });
}
