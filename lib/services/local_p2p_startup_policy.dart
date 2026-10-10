import 'dart:async';

/// Startup rules for a local Free P2P torrent stream on Android (Mobile and
/// TV), shared by the MPV and ExoPlayer screens.
///
/// A torrent that has not delivered video yet is still connecting, not
/// failed: swarms regularly need minutes before the first frame. Elapsed
/// time alone therefore never fails the stream, the source or the player
/// engine. Only evidence that playback cannot continue does: the player gave
/// up on the stream, the local torrent engine stopped answering, or the
/// player reported an error that a slow torrent cannot cause (for example an
/// unsupported codec).
class LocalP2pStartupPolicy {
  LocalP2pStartupPolicy._();

  /// After this long without video the player shows a calm "still
  /// connecting" note. It is not a failure and nothing is recorded.
  static const Duration slowNoticeAfter = Duration(seconds: 30);

  /// How often a waiting player checks for real terminal evidence.
  static const Duration terminalCheckInterval = Duration(seconds: 5);

  /// Consecutive checks that must agree before a stream counts as dead, so
  /// one racy reading never ends a stream that is still loading.
  static const int terminalConfirmations = 2;

  /// Whether [url] is a local Free P2P torrent stream played on Android.
  static bool appliesTo({required bool isAndroid, required String url}) {
    if (!isAndroid) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port == 11470 &&
        uri.pathSegments.length >= 2 &&
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(uri.pathSegments.first) &&
        int.tryParse(uri.pathSegments[1]) != null;
  }

  /// Whether a Media3 error code (PlaybackException.errorCodeName) means the
  /// stream cannot play. Network and timeout codes are what a slow torrent
  /// produces and are not terminal on a local Free P2P stream.
  static bool exoErrorCodeIsTerminal(String? code) {
    final value = code?.toUpperCase() ?? '';
    if (value.isEmpty) return false;
    const transient = <String>[
      'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
      'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT',
      'ERROR_CODE_IO_UNSPECIFIED',
      'ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE',
      'ERROR_CODE_TIMEOUT',
      'ERROR_CODE_UNSPECIFIED',
      'ERROR_CODE_REMOTE_ERROR',
      'ERROR_CODE_BEHIND_LIVE_WINDOW',
    ];
    return !transient.contains(value);
  }

  /// Whether an ExoPlayer error can only mean the stream cannot play, as
  /// opposed to the slow-torrent read timeouts ExoPlayer raises while the
  /// local engine is still waiting for pieces.
  static bool exoErrorIsTerminal(String description) {
    final value = description.toLowerCase();
    const terminal = <String>[
      'renderer error',
      'mediacodec',
      'decoder',
      'format_supported',
      'no_unsupported',
      'unsupported',
      'unrecognizedinputformat',
      'none of the available extractors',
      'parserexception',
      'response code: 404',
      'response code: 403',
      'response code: 410',
      'response code: 416',
      'cleartext',
    ];
    return terminal.any(value.contains);
  }
}

/// Watches a local Free P2P stream that has not started yet. It shows the
/// "still connecting" note after [LocalP2pStartupPolicy.slowNoticeAfter],
/// treats player errors as transient while the player is still loading, and
/// reports a terminal failure only after
/// [LocalP2pStartupPolicy.terminalConfirmations] consecutive checks find
/// that the player gave up or the torrent engine stopped answering.
class LocalP2pStartupMonitor {
  LocalP2pStartupMonitor({
    required this.playerGaveUp,
    required this.engineAnswering,
    required this.started,
    required this.onSlow,
    required this.onTerminal,
    this.onStage,
    this.slowNoticeAfter = LocalP2pStartupPolicy.slowNoticeAfter,
    this.checkEvery = LocalP2pStartupPolicy.terminalCheckInterval,
  });

  /// True once the player stopped loading the stream (MPV back to idle).
  final Future<bool> Function() playerGaveUp;
  final Future<bool> Function() engineAnswering;
  final bool Function() started;
  final void Function() onSlow;
  final void Function(String reason) onTerminal;
  final void Function(String stage, String result, Map<String, Object?> detail)?
      onStage;
  final Duration slowNoticeAfter;
  final Duration checkEvery;

  Timer? _slowTimer;
  Timer? _checkTimer;
  bool _checking = false;
  bool _done = false;
  bool _slowShown = false;
  int _gaveUpReadings = 0;
  int _engineDownReadings = 0;
  int _transientErrors = 0;
  String? _lastError;
  final Stopwatch _watch = Stopwatch();

  bool get active => !_done;
  bool get slowShown => _slowShown;
  int get transientErrors => _transientErrors;

  void begin() {
    if (_done || _watch.isRunning) return;
    _watch.start();
    _slowTimer = Timer(slowNoticeAfter, () {
      if (_done || started()) return stop();
      _showSlow();
      _ensureChecks();
    });
  }

  /// A player error before the first frame. It is never reported at once:
  /// the periodic check decides whether the player is still loading.
  void playerError(String message) {
    if (_done || started()) return;
    _transientErrors++;
    _lastError = message.trim();
    if (_transientErrors <= 3) {
      onStage?.call('playerError', 'transient', <String, Object?>{
        'count': _transientErrors,
        'atS': _watch.elapsed.inSeconds,
      });
    }
    _showSlow();
    _ensureChecks();
  }

  void _showSlow() {
    if (_slowShown) return;
    _slowShown = true;
    onStage?.call('playerStart', 'slow', <String, Object?>{
      'atS': _watch.elapsed.inSeconds,
    });
    onSlow();
  }

  void _ensureChecks() {
    _checkTimer ??= Timer.periodic(checkEvery, (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    if (_done || _checking) return;
    if (started()) return stop();
    _checking = true;
    try {
      final gaveUp = await playerGaveUp();
      final engineUp = await engineAnswering();
      if (_done || started()) return stop();
      _gaveUpReadings = gaveUp ? _gaveUpReadings + 1 : 0;
      _engineDownReadings = engineUp ? 0 : _engineDownReadings + 1;
      final confirmations = LocalP2pStartupPolicy.terminalConfirmations;
      if (_gaveUpReadings >= confirmations ||
          _engineDownReadings >= confirmations) {
        final reason = _engineDownReadings >= confirmations
            ? 'The local torrent engine stopped answering before playback '
                'started.'
            : (_lastError?.isNotEmpty == true
                ? 'Playback engine: $_lastError'
                : 'The player stopped loading this stream before playback '
                    'started.');
        onStage?.call('playerStart', 'terminal', <String, Object?>{
          'atS': _watch.elapsed.inSeconds,
          'playerGaveUp': _gaveUpReadings >= confirmations,
          'engineAnswering': engineUp,
        });
        _finish();
        onTerminal(reason);
      }
    } finally {
      _checking = false;
    }
  }

  void _finish() {
    _done = true;
    _slowTimer?.cancel();
    _checkTimer?.cancel();
    _watch.stop();
  }

  /// Playback started, the player closed, or a terminal failure was shown.
  void stop() {
    if (_done) return;
    _finish();
  }
}

/// ExoPlayer on a local Free P2P stream: ExoPlayer gives up on a stream that
/// sends no bytes for a while (its read timeouts and load retries end
/// preparation after roughly half a minute). For a torrent that is still
/// connecting that is not a failure, so the same stream is opened again in
/// the same ExoPlayer screen. A retry is refused when the error cannot be
/// caused by slowness, when the engine stopped answering, or when attempts
/// keep failing immediately (a stream that fails fast is not slow).
class ExoP2pRetryPolicy {
  ExoP2pRetryPolicy({
    this.rapidFailure = const Duration(seconds: 4),
    this.maxRapidFailures = 3,
  });

  final Duration rapidFailure;
  final int maxRapidFailures;
  int _rapid = 0;
  int attempts = 0;

  /// Whether to reopen the same stream after an attempt that ended with
  /// [description]. [attemptWasLong] is true when the attempt lasted at
  /// least [rapidFailure] (it waited on a silent stream).
  bool shouldRetry({
    required String description,
    required bool attemptWasLong,
    required bool engineAnswering,
  }) {
    attempts++;
    if (!engineAnswering) return false;
    if (LocalP2pStartupPolicy.exoErrorIsTerminal(description)) return false;
    _rapid = attemptWasLong ? 0 : _rapid + 1;
    return _rapid < maxRapidFailures;
  }
}
