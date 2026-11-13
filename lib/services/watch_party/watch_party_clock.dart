/// Estimates the server clock from request round trips, so every member of
/// a room reads playback positions against the same clock.
///
/// Each sample is "the server said [serverMs] somewhere between my send and
/// receive times". The midpoint is the best guess and the error is at most
/// half the round trip, so the sample with the shortest round trip wins.
/// Local time comes from a monotonic source: changing the device clock does
/// not move the estimate.
class WatchPartyClock {
  WatchPartyClock({int Function()? localNowMs})
      : _localNowMs = localNowMs ?? _monotonicNow;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _monotonicNow() => _stopwatch.elapsedMilliseconds;

  /// Round trips slower than this say too little about the server clock.
  static const maxUsableRoundTripMs = 4000;

  /// Old samples are dropped so slow drift between the clocks is followed.
  static const maxSamples = 8;

  final int Function() _localNowMs;
  final List<({int offsetMs, int roundTripMs})> _samples = [];

  int get localNowMs => _localNowMs();

  bool get isSynced => _samples.isNotEmpty;

  void addSample({
    required int sentAtLocalMs,
    required int receivedAtLocalMs,
    required int serverMs,
  }) {
    final roundTrip = receivedAtLocalMs - sentAtLocalMs;
    if (roundTrip < 0 || roundTrip > maxUsableRoundTripMs) return;
    final midpoint = sentAtLocalMs + roundTrip ~/ 2;
    _samples.add((offsetMs: serverMs - midpoint, roundTripMs: roundTrip));
    if (_samples.length > maxSamples) _samples.removeAt(0);
  }

  ({int offsetMs, int roundTripMs})? get _best {
    ({int offsetMs, int roundTripMs})? best;
    for (final sample in _samples) {
      if (best == null || sample.roundTripMs < best.roundTripMs) best = sample;
    }
    return best;
  }

  /// Server time now, or null before the first usable sample.
  int? get serverNowMs {
    final best = _best;
    return best == null ? null : _localNowMs() + best.offsetMs;
  }

  /// Worst-case error of [serverNowMs].
  int? get uncertaintyMs {
    final best = _best;
    return best == null ? null : (best.roundTripMs + 1) ~/ 2;
  }
}
