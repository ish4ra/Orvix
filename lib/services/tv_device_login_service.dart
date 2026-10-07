import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'orvix_account_backend.dart';
import 'orvix_account_service.dart';

/// Where the Android TV QR login is.
enum TvDeviceLoginPhase {
  idle,

  /// Asking the server for a code.
  preparing,

  /// Showing the QR code and waiting for the phone.
  waiting,

  /// Still showing the QR code; the last poll failed and is being retried.
  connectionIssue,

  /// The phone approved; the TV is getting its session.
  signingIn,

  /// Signed in; merging cloud data into this TV.
  syncing,

  /// Signed in and synced.
  signedIn,

  /// Signed in, but the cloud sync failed. The TV stays signed in.
  syncFailed,

  /// The code expired before it was approved.
  expired,

  /// The code was used, cancelled or refused; a new code is needed.
  rejected,

  /// Could not start or finish the login.
  failed,
}

class TvDeviceLoginState {
  const TvDeviceLoginState({
    this.phase = TvDeviceLoginPhase.idle,
    this.userCode,
    this.verificationUrl,
    this.message,
  });

  final TvDeviceLoginPhase phase;
  final String? userCode;
  final String? verificationUrl;
  final String? message;

  /// The QR code and user code are valid and should be shown.
  bool get showsCode =>
      verificationUrl != null &&
      (phase == TvDeviceLoginPhase.waiting ||
          phase == TvDeviceLoginPhase.connectionIssue);

  /// Work is running that the user should not interrupt with a new code.
  bool get busy =>
      phase == TvDeviceLoginPhase.preparing ||
      phase == TvDeviceLoginPhase.signingIn ||
      phase == TvDeviceLoginPhase.syncing;

  /// The login ended without signing in; a new code is needed.
  bool get needsNewCode =>
      phase == TvDeviceLoginPhase.expired ||
      phase == TvDeviceLoginPhase.rejected ||
      phase == TvDeviceLoginPhase.failed;

  bool get signedIn =>
      phase == TvDeviceLoginPhase.signedIn ||
      phase == TvDeviceLoginPhase.syncFailed;
}

/// Retry limits and timings. Tests shorten them.
class TvDeviceLoginPolicy {
  const TvDeviceLoginPolicy({
    this.startAttempts = 3,
    this.maxConsecutivePollFailures = 8,
    this.exchangeAttempts = 5,
    this.sessionAttempts = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(seconds: 15),
    this.codeLifetime = const Duration(minutes: 10),
    this.syncTimeout = const Duration(seconds: 25),
  });

  final int startAttempts;
  final int maxConsecutivePollFailures;
  final int exchangeAttempts;
  final int sessionAttempts;
  final Duration retryDelay;
  final Duration maxRetryDelay;
  final Duration codeLifetime;
  final Duration syncTimeout;

  Duration backoff(int failure) {
    final factor = 1 << failure.clamp(0, 6);
    final delay = retryDelay * factor;
    return delay > maxRetryDelay ? maxRetryDelay : delay;
  }
}

/// Runs one Android TV QR login at a time.
///
/// Every [start] begins a new generation. Work from an older generation (a
/// replaced QR code, a cancelled login, a disposed screen) stops at its next
/// step and never changes [state] or signs the TV in, so an old QR code can
/// never sign the TV in after a newer one is shown.
class TvDeviceLoginController extends ChangeNotifier {
  TvDeviceLoginController({
    OrvixTvLoginBackend? backend,
    Future<void> Function()? syncAfterSignIn,
    Future<void> Function(Duration duration)? delay,
    DateTime Function()? now,
    this.policy = const TvDeviceLoginPolicy(),
    this.deviceName = 'Orvix Android TV',
  })  : _backendOverride = backend,
        _sync = syncAfterSignIn ?? OrvixAccountService.mergeCloudIntoLocal,
        _delayOverride = delay,
        _now = now ?? DateTime.now;

  final OrvixTvLoginBackend? _backendOverride;
  final Future<void> Function() _sync;
  final Future<void> Function(Duration duration)? _delayOverride;
  Timer? _waitTimer;
  Completer<void>? _wait;
  final DateTime Function() _now;
  final TvDeviceLoginPolicy policy;
  final String deviceName;

  static final Random _random = Random.secure();

  OrvixTvLoginBackend get _backend =>
      _backendOverride ?? OrvixAccountService.backend;

  TvDeviceLoginState _state = const TvDeviceLoginState();
  int _generation = 0;
  bool _disposed = false;
  ({String deviceCode, String nonce})? _shownLogin;

  TvDeviceLoginState get state => _state;

  /// The current generation; it changes on every [start], [cancel] and
  /// [dispose].
  int get generation => _generation;

  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  /// Shows a new code, replacing (and cancelling) the current one. Completes
  /// when this login ends or is replaced.
  Future<void> start() {
    final generation = _invalidate();
    return _run(generation);
  }

  /// Stops the current login. The code shown so far stops working.
  void cancel() {
    _invalidate();
    _emit(const TvDeviceLoginState(), _generation);
  }

  @override
  void dispose() {
    _invalidate();
    _disposed = true;
    super.dispose();
  }

  /// Waits between polls and retries. Ends early when the login is replaced,
  /// cancelled or disposed, so no timer outlives it.
  Future<void> _delay(Duration duration) {
    final override = _delayOverride;
    if (override != null) return override(duration);
    _endWait();
    final wait = _wait = Completer<void>();
    _waitTimer = Timer(duration, _endWait);
    return wait.future;
  }

  void _endWait() {
    _waitTimer?.cancel();
    _waitTimer = null;
    final wait = _wait;
    _wait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  int _invalidate() {
    _endWait();
    final shown = _shownLogin;
    _shownLogin = null;
    // Only a code that is still waiting is cancelled; once the phone approved
    // it, the exchange owns it.
    if (shown != null &&
        (_state.phase == TvDeviceLoginPhase.waiting ||
            _state.phase == TvDeviceLoginPhase.connectionIssue)) {
      unawaited(_backend
          .cancelTvLogin(deviceCode: shown.deviceCode, deviceNonce: shown.nonce)
          .then((_) {}, onError: (_) {}));
    }
    return ++_generation;
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _emit(TvDeviceLoginState state, int generation) {
    if (_stale(generation)) return;
    _state = state;
    notifyListeners();
  }

  Future<void> _run(int generation) async {
    _emit(const TvDeviceLoginState(phase: TvDeviceLoginPhase.preparing),
        generation);
    final nonce = _uuidV4();

    OrvixTvLoginStart? start;
    for (var attempt = 0; start == null; attempt++) {
      try {
        start = await _backend.startTvLogin(
          deviceNonce: nonce,
          deviceName: deviceName,
        );
      } catch (_) {
        if (_stale(generation)) return;
        if (attempt + 1 >= policy.startAttempts) {
          _emit(
            const TvDeviceLoginState(
              phase: TvDeviceLoginPhase.failed,
              message:
                  'Could not reach Orvix to create a sign-in code. Check the TV\'s connection and try again.',
            ),
            generation,
          );
          return;
        }
        await _delay(policy.backoff(attempt));
        if (_stale(generation)) return;
      }
    }
    if (_stale(generation)) {
      unawaited(_backend
          .cancelTvLogin(deviceCode: start.deviceCode, deviceNonce: nonce)
          .then((_) {}, onError: (_) {}));
      return;
    }

    final code = start.userCode;
    final url = start.verificationUrl;
    _shownLogin = (deviceCode: start.deviceCode, nonce: nonce);
    final waiting = TvDeviceLoginState(
      phase: TvDeviceLoginPhase.waiting,
      userCode: code,
      verificationUrl: url,
    );
    _emit(waiting, generation);

    final expiresAt = _now().add(policy.codeLifetime);
    final interval =
        Duration(seconds: start.pollIntervalSeconds.clamp(2, 10).toInt());
    var failures = 0;
    while (true) {
      await _delay(failures == 0 ? interval : policy.backoff(failures - 1));
      if (_stale(generation)) return;
      if (!_now().isBefore(expiresAt)) {
        _expire(generation);
        return;
      }

      final String? status;
      try {
        status = await _backend.pollTvLogin(
          deviceCode: start.deviceCode,
          deviceNonce: nonce,
        );
      } catch (_) {
        if (_stale(generation)) return;
        failures++;
        if (failures > policy.maxConsecutivePollFailures) {
          _emit(
            const TvDeviceLoginState(
              phase: TvDeviceLoginPhase.failed,
              message:
                  'Lost the connection to Orvix. Check the TV\'s connection and try again.',
            ),
            generation,
          );
          return;
        }
        _emit(
          TvDeviceLoginState(
            phase: TvDeviceLoginPhase.connectionIssue,
            userCode: code,
            verificationUrl: url,
            message: 'Connection problem. Retrying…',
          ),
          generation,
        );
        continue;
      }
      if (_stale(generation)) return;
      if (failures > 0) {
        failures = 0;
        _emit(waiting, generation);
      }

      if (status == 'pending') continue;
      if (status == 'approved') break;
      if (status == null || status == 'expired') {
        _expire(generation);
      } else {
        _reject(generation);
      }
      return;
    }

    _emit(
      TvDeviceLoginState(
        phase: TvDeviceLoginPhase.signingIn,
        userCode: code,
        message: 'Approved on your phone. Signing in…',
      ),
      generation,
    );

    String? token;
    for (var attempt = 0; token == null; attempt++) {
      try {
        token = await _backend.exchangeTvLogin(
          deviceCode: start.deviceCode,
          deviceNonce: nonce,
        );
      } on OrvixTvLoginException catch (error) {
        if (_stale(generation)) return;
        if (!error.retryable) {
          if (error.kind == OrvixTvLoginErrorKind.configuration) {
            _emit(
              const TvDeviceLoginState(
                phase: TvDeviceLoginPhase.failed,
                message:
                    'Orvix could not finish the TV sign-in right now. Try again later.',
              ),
              generation,
            );
          } else {
            _reject(generation);
          }
          return;
        }
        if (!await _retryOrFail(attempt, policy.exchangeAttempts, generation)) {
          return;
        }
      } catch (_) {
        if (_stale(generation)) return;
        if (!await _retryOrFail(attempt, policy.exchangeAttempts, generation)) {
          return;
        }
      }
    }
    // A cancel, a newer code or a disposed screen wins over a late success.
    if (_stale(generation)) return;

    for (var attempt = 0;; attempt++) {
      try {
        await _backend.signInWithTvLoginToken(token);
        break;
      } catch (_) {
        if (_stale(generation)) return;
        if (!await _retryOrFail(attempt, policy.sessionAttempts, generation)) {
          return;
        }
      }
    }
    _shownLogin = null;
    if (_stale(generation)) return;

    _emit(
      const TvDeviceLoginState(
        phase: TvDeviceLoginPhase.syncing,
        message: 'Signed in. Syncing your Orvix data…',
      ),
      generation,
    );
    try {
      await _sync().timeout(policy.syncTimeout);
      _emit(
        const TvDeviceLoginState(phase: TvDeviceLoginPhase.signedIn),
        generation,
      );
    } catch (_) {
      // Signing in worked; only the sync failed. Never sign the TV out here.
      _emit(
        const TvDeviceLoginState(
          phase: TvDeviceLoginPhase.syncFailed,
          message:
              'Signed in, but your cloud data did not sync. Choose Sync now to try again.',
        ),
        generation,
      );
    }
  }

  /// Waits before the next attempt, or reports failure after the last one.
  Future<bool> _retryOrFail(int attempt, int attempts, int generation) async {
    if (attempt + 1 >= attempts) {
      _emit(
        const TvDeviceLoginState(
          phase: TvDeviceLoginPhase.failed,
          message:
              'Approved, but the TV could not finish signing in. Generate a new code and try again.',
        ),
        generation,
      );
      return false;
    }
    await _delay(policy.backoff(attempt));
    return !_stale(generation);
  }

  void _expire(int generation) {
    _shownLogin = null;
    _emit(
      const TvDeviceLoginState(
        phase: TvDeviceLoginPhase.expired,
        message: 'This code expired. Generate a new code to sign in.',
      ),
      generation,
    );
  }

  void _reject(int generation) {
    _shownLogin = null;
    _emit(
      const TvDeviceLoginState(
        phase: TvDeviceLoginPhase.rejected,
        message: 'This code can no longer be used. Generate a new code.',
      ),
      generation,
    );
  }
}

/// How approving a TV code from the phone ended.
enum TvApprovalResult {
  approved,

  /// The scanned or typed value is not an Orvix TV code.
  invalidCode,

  /// The code is valid in form but expired, was used or was replaced.
  expiredOrUsed,
  rateLimited,
  notSignedIn,

  /// The phone could not reach Orvix.
  network,
  failed,
}

/// Accepts the first valid Orvix TV code from a camera stream and ignores
/// repeats, so one scan approves at most once.
class TvQrScanGate {
  bool _accepted = false;

  bool get accepted => _accepted;

  /// The normalized code the first time a valid value is seen; null for
  /// anything invalid and for everything after the first valid value.
  String? accept(String raw) {
    if (_accepted) return null;
    final code = TvDeviceLoginService.normalizeCode(raw);
    if (code == null) return null;
    _accepted = true;
    return code;
  }

  void reset() => _accepted = false;
}

class TvDeviceLoginService {
  TvDeviceLoginService._();

  static OrvixTvLoginBackend get _backend => OrvixAccountService.backend;

  static final RegExp _plainCode = RegExp(r'^[A-Za-z0-9 -]+$');
  static final RegExp _validCode = RegExp(r'^[A-Z0-9]{6}$');

  /// The six-character code in a scanned QR value or a typed code, or null.
  ///
  /// Accepts the Orvix QR link (`https://…/tv-login-link?code=ABC123`) and
  /// plain codes such as `ABC123`, `abc123` or `ABC-123`. Any other link or
  /// text is rejected.
  static String? normalizeCode(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 512) return null;
    final uri = Uri.tryParse(value);
    String candidate;
    if (uri != null && uri.hasScheme) {
      if (uri.scheme != 'https' || !uri.path.endsWith('/tv-login-link')) {
        return null;
      }
      candidate = uri.queryParameters['code'] ?? '';
    } else {
      candidate = value;
    }
    if (!_plainCode.hasMatch(candidate)) return null;
    final code = candidate.replaceAll(RegExp('[ -]'), '').toUpperCase();
    return _validCode.hasMatch(code) ? code : null;
  }

  /// Approves a TV's QR/user code from a signed-in phone. Refused while the
  /// account is being deleted.
  static Future<bool> approve(String userCode) async {
    if (OrvixAccountService.isDeletingAccount) {
      throw StateError('The account is being deleted.');
    }
    return _backend.approveTvLogin(userCode);
  }

  /// Normalizes [raw] and approves it, classifying every outcome for the UI.
  /// Never logs the code.
  static Future<TvApprovalResult> approveScanned(String raw) async {
    final code = normalizeCode(raw);
    if (code == null) return TvApprovalResult.invalidCode;
    if (OrvixAccountService.currentUser == null) {
      return TvApprovalResult.notSignedIn;
    }
    try {
      return await approve(code)
          ? TvApprovalResult.approved
          : TvApprovalResult.expiredOrUsed;
    } on OrvixTvLoginException catch (error) {
      return error.kind == OrvixTvLoginErrorKind.rateLimited
          ? TvApprovalResult.rateLimited
          : TvApprovalResult.failed;
    } on OrvixAuthException catch (error) {
      if (error.kind == OrvixAuthErrorKind.network) {
        return TvApprovalResult.network;
      }
      if (error.kind == OrvixAuthErrorKind.sessionMissing) {
        return TvApprovalResult.notSignedIn;
      }
      return TvApprovalResult.failed;
    } on StateError {
      return TvApprovalResult.failed;
    } catch (error) {
      return _looksLikeNetwork(error)
          ? TvApprovalResult.network
          : TvApprovalResult.failed;
    }
  }

  static bool _looksLikeNetwork(Object error) {
    final type = error.runtimeType.toString();
    return error is TimeoutException ||
        type.contains('SocketException') ||
        type.contains('ClientException') ||
        type.contains('HandshakeException');
  }

  /// The message the phone shows for [result].
  static String approvalMessage(TvApprovalResult result) => switch (result) {
        TvApprovalResult.approved =>
          'TV approved. Orvix on your TV will sign in automatically.',
        TvApprovalResult.invalidCode =>
          'That is not an Orvix TV code. Scan the QR code shown by Orvix on your TV.',
        TvApprovalResult.expiredOrUsed =>
          'That TV code expired, was already used or was replaced. Refresh the code on the TV and scan it again.',
        TvApprovalResult.rateLimited =>
          'Too many TV code attempts. Wait a few minutes and try again.',
        TvApprovalResult.notSignedIn =>
          'Sign in to your Orvix account first, then scan the TV QR code.',
        TvApprovalResult.network =>
          'Could not reach Orvix. Check your connection and try again.',
        TvApprovalResult.failed =>
          'Could not approve the TV. Refresh its QR code and try again.',
      };

  /// Shown on the TV as the code, e.g. ABC-123.
  static String displayCode(String code) =>
      code.length == 6 ? '${code.substring(0, 3)}-${code.substring(3)}' : code;
}
