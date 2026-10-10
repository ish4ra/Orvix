import 'free_p2p_live_probe_service.dart';
import 'free_p2p_playback_trace.dart';
import 'source_provider_service.dart';

/// How one automatic playback attempt ended, as the caller observed it.
enum FreeP2pAttemptEnd {
  /// The player reported that playback started. Later buffering, a later
  /// error or the user closing the player never starts another source.
  started,

  /// The torrent itself did not start: metadata timeout, engine rejection or
  /// a failed request while the engine was answering. Every row of the same
  /// torrent is excluded from the next choice.
  sourceFailed,

  /// The stream opened but the player reported a startup failure and left
  /// for the next source. Rows that may route to the same file are
  /// excluded.
  playerFailed,

  /// The local torrent engine is not answering; another torrent would fail
  /// the same way, so no fallback is tried.
  engineFailure,

  /// The user backed out, closed the player before it started, or closed a
  /// player that showed its startup error. Never followed by a fallback.
  stoppedByUser,
}

/// Why a one-click run stopped.
enum FreeP2pAutoPlayStop {
  started,
  stoppedByUser,

  /// No source was verified playable by the bounded live check.
  noVerifiedSource,

  /// Verified sources were tried and none started, or the attempt or time
  /// budget ran out.
  exhausted,
  engineFailure,
}

class FreeP2pAutoPlayResult {
  const FreeP2pAutoPlayResult(this.stop, {this.started, this.tried = 0});

  final FreeP2pAutoPlayStop stop;

  /// The source that started, when [stop] is [FreeP2pAutoPlayStop.started].
  final SourceResult? started;

  /// Automatic attempts made.
  final int tried;
}

/// Starts playback signature: the source to play and whether a verified
/// next source exists, so the player may leave by itself on a startup
/// failure instead of waiting for the user.
typedef FreeP2pAttempt = Future<FreeP2pAttemptEnd> Function(
  SourceResult source, {
  required bool fallbackAvailable,
});

/// One press of Play in Free P2P mode (no cloud/debrid route): find the best
/// source verified by the bounded live check, play it, and when it does not
/// start, move to the next verified source.
///
/// Safety and bounds:
/// - Only sources [FreeP2pLiveProbeService.quickPlayAllowed] accepts are
///   launched: direct HTTP, or a torrent confirmed live by this session's
///   probe with fresh evidence. Unchecked, failed, expired and start-failed
///   torrents are never auto-launched, whatever their reported seeders.
/// - The choice follows [FreeP2pLiveProbeService.playbackOrder]: measured
///   health band first (ready now > live > slow, which already weighs
///   throughput against the file's bitrate need), then first byte,
///   throughput, live peers and compatibility. Neither the Source Priority
///   nor the display mode changes it.
/// - At most [maxAttempts] sources per press (the first plus two
///   fallbacks). A torrent or file that failed is never tried again in the
///   same run.
/// - No fallback starts after [fallbackStartDeadline] from Play; one
///   resolve can take up to 45 s of metadata wait plus up to 30 s of player
///   startup, so this keeps the worst case near four minutes.
/// - The first live check is Normal Play's own bounded check (6 + 3
///   torrents, 20 s). When no verified source is left after a failure, one
///   more round of the same size runs, so a press never classifies more than
///   [FreeP2pLiveProbeService.pickerProbeLimit] torrents.
class FreeP2pAutoPlay {
  FreeP2pAutoPlay({
    required this.probe,
    required this.sources,
    FreeP2pPlaybackTrace? trace,
    DateTime Function()? clock,
    this.maxAttempts = defaultMaxAttempts,
    this.fallbackStartDeadline = defaultFallbackStartDeadline,
  })  : _trace = trace ?? FreeP2pPlaybackTrace.instance,
        _clock = clock ?? DateTime.now;

  static const int defaultMaxAttempts = 3;
  static const Duration defaultFallbackStartDeadline = Duration(minutes: 2);

  final FreeP2pLiveProbeService probe;
  final SourceProviderService sources;
  final int maxAttempts;
  final Duration fallbackStartDeadline;
  final FreeP2pPlaybackTrace _trace;
  final DateTime Function() _clock;

  Future<FreeP2pAutoPlayResult> run(
    List<SourceResult> results, {
    required FreeP2pAttempt attempt,
    SourceResult? preferred,
    bool Function(SourceResult source)? isPinned,
    void Function(String status)? onStatus,
    void Function(int completed, int total)? onProbeProgress,
  }) async {
    final startedAt = _clock();
    Duration elapsed() => _clock().difference(startedAt);
    final record = _trace.beginRun();
    var extraRoundUsed = false;
    var tried = 0;

    List<SourceResult> viable() => results
        .where((source) => !probe.isStartFailed(source))
        .toList(growable: false);

    Future<SourceResult?> checkRound(String purpose) async {
      final roundStart = _clock();
      final pin = preferred != null && !probe.isStartFailed(preferred)
          ? preferred
          : null;
      final found = await probe.probeBestCandidate(
        viable(),
        sources,
        preferred: pin,
        onUpdate: onProbeProgress,
      );
      record.probeRound(
        purpose,
        classified: probe.classifiedCount(results),
        confirmedLive: probe.confirmedLiveCount(results),
        took: _clock().difference(roundStart),
      );
      // Belt and braces: the round only returns direct HTTP or a torrent
      // confirmed live, and never a start-failed row.
      if (found == null || !probe.quickPlayAllowed(found)) return null;
      return found;
    }

    FreeP2pAutoPlayResult stop(
      FreeP2pAutoPlayStop reason, {
      SourceResult? started,
      String? detail,
    }) {
      record.finish(reason.name, detail: detail);
      return FreeP2pAutoPlayResult(reason, started: started, tried: tried);
    }

    onStatus?.call('Checking the healthiest live P2P sources…');
    var candidate = await checkRound('firstChoice');

    while (true) {
      if (candidate == null) {
        if (tried == 0 && probe.engineLooksDown(results)) {
          return stop(FreeP2pAutoPlayStop.engineFailure);
        }
        return tried == 0
            ? stop(FreeP2pAutoPlayStop.noVerifiedSource)
            : stop(FreeP2pAutoPlayStop.exhausted, detail: 'noVerifiedLeft');
      }
      tried++;
      final number = tried;
      final pinned = isPinned?.call(candidate) ?? false;
      final traced = await probe.prepareForPlayback(
        candidate,
        selection: number == 1 ? 'oneClick' : 'fallback',
        choice: <String, Object?>{
          ...probe.choiceSummary(candidate, results, pinned: pinned),
          'autoAttempt': number,
          'maxAttempts': maxAttempts,
        },
      );
      record.attemptStarted(traced, number: number);

      // Let the player leave by itself on a startup failure only when a
      // verified next source exists right now and the budget allows one.
      final fallbackAvailable = number < maxAttempts &&
          elapsed() < fallbackStartDeadline &&
          _nextVerified(results, excluding: candidate, isPinned: isPinned) !=
              null;

      onStatus?.call(number == 1
          ? 'Starting the best verified source…'
          : 'Trying the next verified source ($number/$maxAttempts)…');
      final attemptStart = _clock();
      final end =
          await attempt(candidate, fallbackAvailable: fallbackAvailable);
      record.attemptEnded(
        _trace.latest(candidate),
        number: number,
        end: end.name,
        took: _clock().difference(attemptStart),
      );

      switch (end) {
        case FreeP2pAttemptEnd.started:
          return stop(FreeP2pAutoPlayStop.started, started: candidate);
        case FreeP2pAttemptEnd.stoppedByUser:
          return stop(FreeP2pAutoPlayStop.stoppedByUser);
        case FreeP2pAttemptEnd.engineFailure:
          return stop(FreeP2pAutoPlayStop.engineFailure);
        case FreeP2pAttemptEnd.sourceFailed:
        case FreeP2pAttemptEnd.playerFailed:
          probe.markStartFailed(
            candidate,
            wholeTorrent: end == FreeP2pAttemptEnd.sourceFailed,
          );
      }

      if (tried >= maxAttempts) {
        return stop(FreeP2pAutoPlayStop.exhausted, detail: 'attemptLimit');
      }
      if (elapsed() >= fallbackStartDeadline) {
        return stop(FreeP2pAutoPlayStop.exhausted, detail: 'timeBudget');
      }

      candidate = _nextVerified(results, isPinned: isPinned);
      if (candidate == null &&
          !extraRoundUsed &&
          probe.classifiedCount(results) <
              FreeP2pLiveProbeService.pickerProbeLimit) {
        extraRoundUsed = true;
        onStatus?.call('That source did not start. Checking more sources…');
        candidate = await checkRound('fallback');
      }
    }
  }

  /// The best remaining source that may auto-play, never [excluding] or a
  /// start-failed row.
  SourceResult? _nextVerified(
    List<SourceResult> results, {
    SourceResult? excluding,
    bool Function(SourceResult source)? isPinned,
  }) {
    final remaining = results.where(
      (source) =>
          excluding == null || !probe.sameStartTarget(source, excluding),
    );
    return probe.quickPlayCandidate(remaining, sources, isPinned: isPinned);
  }
}

/// Maps how a traced attempt ended to the fallback decision. A player
/// startup failure only counts as a failed source when the player left by
/// itself for the next source; a user who closes a player that shows its
/// error has decided to stop.
FreeP2pAttemptEnd classifyFreeP2pAttempt(
  FreeP2pPlaybackOutcome? outcome, {
  required bool playerLeftForFallback,
}) {
  switch (outcome) {
    case FreeP2pPlaybackOutcome.playing:
      return FreeP2pAttemptEnd.started;
    case FreeP2pPlaybackOutcome.engineFailure:
      return FreeP2pAttemptEnd.engineFailure;
    case FreeP2pPlaybackOutcome.metadataTimeout:
    case FreeP2pPlaybackOutcome.sourceError:
    case FreeP2pPlaybackOutcome.failed:
      return FreeP2pAttemptEnd.sourceFailed;
    case FreeP2pPlaybackOutcome.playerFailure:
      return playerLeftForFallback
          ? FreeP2pAttemptEnd.playerFailed
          : FreeP2pAttemptEnd.stoppedByUser;
    case FreeP2pPlaybackOutcome.cancelled:
    case FreeP2pPlaybackOutcome.closedBeforeStart:
    case FreeP2pPlaybackOutcome.inProgress:
    case null:
      return FreeP2pAttemptEnd.stoppedByUser;
  }
}
