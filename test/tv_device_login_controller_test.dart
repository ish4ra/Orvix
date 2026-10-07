import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/orvix_account_backend.dart';
import 'package:orvix/services/orvix_account_service.dart';
import 'package:orvix/services/tv_device_login_service.dart';

/// A scriptable TV login backend. Each start hands out a new device code;
/// poll/exchange answers come from per-device queues, so tests can tell a
/// replaced login from the current one.
class _FakeTvBackend implements OrvixAccountBackend {
  final calls = <String>[];
  int starts = 0;
  final startErrors = <Object>[];
  final polls = <String, List<Object?>>{};
  final pollGates = <String, Completer<void>>{};
  final exchangeAnswers = <Object>[];
  Completer<void>? exchangeGate;
  final sessionErrors = <Object>[];
  OrvixAccountUser? user;
  String? sessionToken;
  bool signedOut = false;
  Object? approveAnswer = true;

  @override
  OrvixAccountUser? get currentUser => user;

  @override
  Future<OrvixTvLoginStart> startTvLogin({
    required String deviceNonce,
    required String deviceName,
  }) async {
    calls.add('start');
    if (startErrors.isNotEmpty) throw startErrors.removeAt(0);
    starts++;
    return OrvixTvLoginStart(
      deviceCode: 'device-$starts',
      userCode: 'CODE0$starts',
      verificationUrl:
          'https://orvix.test/functions/v1/tv-login-link?code=CODE0$starts',
      pollIntervalSeconds: 3,
    );
  }

  @override
  Future<String?> pollTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('poll:$deviceCode');
    final gate = pollGates[deviceCode];
    if (gate != null) await gate.future;
    final queue = polls[deviceCode] ?? <Object?>[];
    final answer = queue.isEmpty ? 'pending' : queue.removeAt(0);
    if (answer is Exception || answer is Error) throw answer!;
    return answer as String?;
  }

  @override
  Future<void> cancelTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('cancel:$deviceCode');
  }

  @override
  Future<String> exchangeTvLogin({
    required String deviceCode,
    required String deviceNonce,
  }) async {
    calls.add('exchange:$deviceCode');
    final gate = exchangeGate;
    if (gate != null) await gate.future;
    final answer =
        exchangeAnswers.isEmpty ? 'token' : exchangeAnswers.removeAt(0);
    if (answer is String) return answer;
    throw answer;
  }

  @override
  Future<void> signInWithTvLoginToken(String token) async {
    calls.add('setSession');
    if (sessionErrors.isNotEmpty) throw sessionErrors.removeAt(0);
    sessionToken = token;
    user = const OrvixAccountUser(id: 'tv-user');
  }

  @override
  Future<bool> approveTvLogin(String userCode) async {
    calls.add('approve:$userCode');
    final answer = approveAnswer;
    if (answer is bool) return answer;
    throw answer!;
  }

  @override
  Future<void> signOut() async {
    signedOut = true;
    user = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeTvBackend backend;
  late List<Duration> delays;
  late DateTime clock;
  late int syncs;
  Object? syncError;

  TvDeviceLoginController controller({
    TvDeviceLoginPolicy policy = const TvDeviceLoginPolicy(),
    Future<void> Function(Duration)? delay,
  }) {
    final login = TvDeviceLoginController(
      backend: backend,
      policy: policy,
      now: () => clock,
      delay: delay ??
          (duration) async {
            delays.add(duration);
            clock = clock.add(duration);
          },
      syncAfterSignIn: () async {
        syncs++;
        if (syncError != null) throw syncError!;
      },
    );
    addTearDown(() {
      try {
        login.dispose();
      } catch (_) {}
    });
    return login;
  }

  List<TvDeviceLoginPhase> record(TvDeviceLoginController login) {
    final phases = <TvDeviceLoginPhase>[];
    login.addListener(() => phases.add(login.state.phase));
    return phases;
  }

  setUp(() {
    backend = _FakeTvBackend();
    delays = [];
    clock = DateTime(2026, 10, 7, 12);
    syncs = 0;
    syncError = null;
    OrvixAccountService.backend = backend;
  });

  test('start, pending, approved, exchange, session and sync', () async {
    backend.polls['device-1'] = ['pending', 'pending', 'approved'];
    final login = controller();
    final phases = record(login);

    await login.start();

    expect(phases, [
      TvDeviceLoginPhase.preparing,
      TvDeviceLoginPhase.waiting,
      TvDeviceLoginPhase.signingIn,
      TvDeviceLoginPhase.syncing,
      TvDeviceLoginPhase.signedIn,
    ]);
    expect(backend.calls, [
      'start',
      'poll:device-1',
      'poll:device-1',
      'poll:device-1',
      'exchange:device-1',
      'setSession',
    ]);
    expect(backend.sessionToken, 'token');
    expect(syncs, 1);
    expect(delays, everyElement(const Duration(seconds: 3)));
  });

  test('a code that is never approved expires', () async {
    final login = controller(
      policy: const TvDeviceLoginPolicy(codeLifetime: Duration(seconds: 10)),
    );
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.expired);
    expect(backend.calls.where((c) => c.startsWith('poll')).length, 3);
    expect(backend.calls, isNot(contains('exchange:device-1')));
  });

  test('server-side expiry, a missing login and a used code end the login',
      () async {
    for (final (answer, phase) in [
      ('expired', TvDeviceLoginPhase.expired),
      (null, TvDeviceLoginPhase.expired),
      ('consumed', TvDeviceLoginPhase.rejected),
      ('cancelled', TvDeviceLoginPhase.rejected),
    ]) {
      backend = _FakeTvBackend();
      backend.polls['device-1'] = [answer];
      final login = controller();
      await login.start();
      expect(login.state.phase, phase, reason: '$answer');
      expect(login.state.needsNewCode, isTrue);
      expect(backend.sessionToken, isNull);
    }
  });

  test('only one polling loop runs and Refresh invalidates the old code',
      () async {
    backend.pollGates['device-1'] = Completer<void>();
    backend.polls['device-1'] = ['approved'];
    backend.polls['device-2'] = ['pending', 'approved'];
    final login = controller();

    final first = login.start();
    await pumpEventQueue();
    expect(login.state.userCode, 'CODE01');

    // Refresh while the first loop is waiting on a poll.
    final second = login.start();
    expect(backend.calls, contains('cancel:device-1'));
    backend.pollGates['device-1']!.complete();
    await Future.wait([first, second]);

    // The old code reported "approved" late, but only the new one signed in.
    expect(backend.calls, isNot(contains('exchange:device-1')));
    expect(backend.calls, contains('exchange:device-2'));
    expect(login.state.phase, TvDeviceLoginPhase.signedIn);
    expect(
      backend.calls.where((c) => c == 'poll:device-1').length,
      1,
      reason: 'the replaced loop must stop polling',
    );
  });

  test('Cancel during the exchange blocks a late success', () async {
    backend.polls['device-1'] = ['approved'];
    backend.exchangeGate = Completer<void>();
    final login = controller();
    final run = login.start();
    await pumpEventQueue();
    expect(login.state.phase, TvDeviceLoginPhase.signingIn);

    login.cancel();
    expect(login.state.phase, TvDeviceLoginPhase.idle);
    backend.exchangeGate!.complete();
    await run;

    expect(backend.calls, isNot(contains('setSession')));
    expect(backend.user, isNull);
    expect(login.state.phase, TvDeviceLoginPhase.idle);
  });

  test('a disposed screen never receives late updates', () async {
    backend.pollGates['device-1'] = Completer<void>();
    backend.polls['device-1'] = ['approved'];
    final login = TvDeviceLoginController(
      backend: backend,
      delay: (_) async {},
      syncAfterSignIn: () async => syncs++,
    );
    var notifications = 0;
    login.addListener(() => notifications++);
    final run = login.start();
    await pumpEventQueue();
    final before = notifications;

    login.dispose();
    expect(backend.calls, contains('cancel:device-1'));
    backend.pollGates['device-1']!.complete();
    await run;

    expect(notifications, before);
    expect(backend.calls, isNot(contains('exchange:device-1')));
    expect(syncs, 0);
  });

  test('temporary poll failures show a connection issue and recover', () async {
    backend.polls['device-1'] = [
      const SocketException('offline'),
      const SocketException('offline'),
      'pending',
      'approved',
    ];
    final login = controller();
    final phases = record(login);
    await login.start();

    expect(phases, [
      TvDeviceLoginPhase.preparing,
      TvDeviceLoginPhase.waiting,
      TvDeviceLoginPhase.connectionIssue,
      TvDeviceLoginPhase.connectionIssue,
      TvDeviceLoginPhase.waiting,
      TvDeviceLoginPhase.signingIn,
      TvDeviceLoginPhase.syncing,
      TvDeviceLoginPhase.signedIn,
    ]);
    // Retries back off instead of hammering the server.
    expect(delays.sublist(1, 3),
        [const Duration(seconds: 2), const Duration(seconds: 4)]);
  });

  test('a lasting connection loss fails instead of polling forever', () async {
    backend.polls['device-1'] =
        List<Object?>.generate(20, (_) => const SocketException('offline'));
    final login = controller(
      policy: const TvDeviceLoginPolicy(maxConsecutivePollFailures: 3),
    );
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.failed);
    expect(backend.calls.where((c) => c.startsWith('poll')).length, 4);
  });

  test('a temporary start failure is retried', () async {
    backend.startErrors.add(const SocketException('offline'));
    backend.polls['device-1'] = ['approved'];
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.signedIn);
    expect(backend.calls.where((c) => c == 'start').length, 2);
  });

  test('start gives up after its retries', () async {
    backend.startErrors.addAll(List.filled(3, const SocketException('x')));
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.failed);
    expect(login.state.message, isNot(contains('Socket')));
  });

  test('temporary exchange errors are retried; the approval is kept', () async {
    backend.polls['device-1'] = ['approved'];
    backend.exchangeAnswers.addAll([
      const OrvixTvLoginException(OrvixTvLoginErrorKind.unavailable),
      const OrvixTvLoginException(OrvixTvLoginErrorKind.busy),
      const SocketException('reset'),
      'token',
    ]);
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.signedIn);
    expect(backend.calls.where((c) => c.startsWith('exchange')).length, 4);
  });

  test('a refused exchange stops without retrying', () async {
    backend.polls['device-1'] = ['approved'];
    backend.exchangeAnswers
        .add(const OrvixTvLoginException(OrvixTvLoginErrorKind.rejected));
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.rejected);
    expect(backend.calls.where((c) => c.startsWith('exchange')).length, 1);
    expect(backend.calls, isNot(contains('setSession')));
  });

  test('a misconfigured server fails clearly without retrying', () async {
    backend.polls['device-1'] = ['approved'];
    backend.exchangeAnswers
        .add(const OrvixTvLoginException(OrvixTvLoginErrorKind.configuration));
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.failed);
    expect(backend.calls.where((c) => c.startsWith('exchange')).length, 1);
  });

  test('exchange retries are bounded', () async {
    backend.polls['device-1'] = ['approved'];
    backend.exchangeAnswers.addAll(List.filled(
        10, const OrvixTvLoginException(OrvixTvLoginErrorKind.unavailable)));
    final login = controller(
      policy: const TvDeviceLoginPolicy(exchangeAttempts: 3),
    );
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.failed);
    expect(backend.calls.where((c) => c.startsWith('exchange')).length, 3);
  });

  test('a temporary setSession failure is retried', () async {
    backend.polls['device-1'] = ['approved'];
    backend.sessionErrors.add(const SocketException('offline'));
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.signedIn);
    expect(backend.calls.where((c) => c == 'setSession').length, 2);
  });

  test('a sync failure keeps the TV signed in', () async {
    backend.polls['device-1'] = ['approved'];
    syncError = StateError('sync down');
    final login = controller();
    await login.start();
    expect(login.state.phase, TvDeviceLoginPhase.syncFailed);
    expect(login.state.signedIn, isTrue);
    expect(backend.signedOut, isFalse);
    expect(backend.user?.id, 'tv-user');
    expect(login.state.message, contains('Sync now'));
  });

  group('phone side', () {
    test('QR values and typed codes are normalized', () {
      const link = 'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/'
          'tv-login-link?code=abc123';
      expect(TvDeviceLoginService.normalizeCode(link), 'ABC123');
      expect(TvDeviceLoginService.normalizeCode('ABC123'), 'ABC123');
      expect(TvDeviceLoginService.normalizeCode(' ABC-123 '), 'ABC123');
      expect(TvDeviceLoginService.normalizeCode('abc 123'), 'ABC123');
      expect(TvDeviceLoginService.normalizeCode('abc123'), 'ABC123');
    });

    test('invalid QR values and unrelated links are rejected', () {
      for (final value in [
        '',
        'ABC12',
        'ABC1234',
        'ABC_123',
        'ABC!23',
        'https://example.com/?code=ABC123',
        'http://orvix.test/functions/v1/tv-login-link?code=ABC123',
        'https://orvix.test/functions/v1/tv-login-link',
        'https://orvix.test/functions/v1/tv-login-link?code=AB',
        'WIFI:S:home;T:WPA;P:secret;;',
        'mailto:a@example.com',
      ]) {
        expect(TvDeviceLoginService.normalizeCode(value), isNull,
            reason: value);
      }
    });

    test('duplicate camera detections approve only once', () {
      final gate = TvQrScanGate();
      expect(gate.accept('https://example.com/other'), isNull);
      expect(gate.accepted, isFalse, reason: 'an invalid QR must not lock');
      expect(gate.accept('ABC-123'), 'ABC123');
      expect(gate.accept('ABC-123'), isNull);
      expect(gate.accept('XYZ789'), isNull);
    });

    test('approval outcomes are classified', () async {
      backend.user = const OrvixAccountUser(id: 'phone-user');
      expect(await TvDeviceLoginService.approveScanned('abc-123'),
          TvApprovalResult.approved);
      expect(backend.calls.last, 'approve:ABC123');

      backend.approveAnswer = false;
      expect(await TvDeviceLoginService.approveScanned('ABC123'),
          TvApprovalResult.expiredOrUsed);

      backend.approveAnswer =
          const OrvixTvLoginException(OrvixTvLoginErrorKind.rateLimited);
      expect(await TvDeviceLoginService.approveScanned('ABC123'),
          TvApprovalResult.rateLimited);

      backend.approveAnswer =
          const OrvixAuthException('offline', kind: OrvixAuthErrorKind.network);
      expect(await TvDeviceLoginService.approveScanned('ABC123'),
          TvApprovalResult.network);

      backend.approveAnswer = const SocketException('offline');
      expect(await TvDeviceLoginService.approveScanned('ABC123'),
          TvApprovalResult.network);

      final before = backend.calls.length;
      expect(await TvDeviceLoginService.approveScanned('https://evil.test/x'),
          TvApprovalResult.invalidCode);
      expect(backend.calls.length, before, reason: 'nothing sent');

      backend.user = null;
      expect(await TvDeviceLoginService.approveScanned('ABC123'),
          TvApprovalResult.notSignedIn);
      expect(backend.calls.length, before);
    });

    test('approval messages never contain the code', () {
      for (final result in TvApprovalResult.values) {
        expect(TvDeviceLoginService.approvalMessage(result),
            isNot(contains('ABC')));
      }
    });
  });
}
