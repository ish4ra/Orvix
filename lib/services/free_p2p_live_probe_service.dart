import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;

import 'free_p2p_playback_trace.dart';
import 'local_torrent_service.dart';
import 'source_provider_service.dart';

class FreeP2pLiveProbeService {
  FreeP2pLiveProbeService({
    this.mediaDuration,
    FreeP2pProbeRunner? probeRunner,
    FreeP2pProbeEngine? engine,
    List<SourceSortCriterion>? priority,
    DateTime Function()? clock,
    FreeP2pPlaybackTrace? playbackTrace,
    FreeP2pLiveEvidence? evidence,
  })  : _cache = evidence?._entries ??
            <String, ({DateTime at, LocalTorrentProbeResult result})>{},
        _now = clock ?? DateTime.now,
        _playbackTrace = playbackTrace ?? FreeP2pPlaybackTrace.instance,
        _engine = engine ??
            (probeRunner != null
                ? _RunnerProbeEngine(probeRunner)
                : const LocalFreeP2pProbeEngine()),
        _priority = List.unmodifiable(
          priority ?? SourceProviderService.defaultPriority,
        ) {
    // Evidence an earlier check of this title left behind orders the rows
    // from the first frame.
    _checkpoint();
  }

  final Duration? mediaDuration;

  /// Time source for evidence freshness; tests inject a fixed clock.
  final DateTime Function() _now;

  /// Records what happens to a source after it is handed to playback.
  final FreeP2pPlaybackTrace _playbackTrace;

  static Duration? parseMediaRuntime(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return null;

    final colon = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(value);
    if (colon != null) {
      final hours = int.tryParse(colon.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(colon.group(2) ?? '') ?? 0;
      final total = hours * 60 + minutes;
      return total > 0 ? Duration(minutes: total) : null;
    }

    final hourMatch = RegExp(r'(\d+)\s*(?:h|hr|hrs|hour|hours)\b').firstMatch(value);
    final minuteMatch =
        RegExp(r'(\d+)\s*(?:m|min|mins|minute|minutes)\b').firstMatch(value);
    final hours = int.tryParse(hourMatch?.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(minuteMatch?.group(1) ?? '') ?? 0;
    if (hours > 0 || minutes > 0) {
      return Duration(hours: hours, minutes: minutes);
    }

    final plainMinutes = int.tryParse(
      RegExp(r'\b(\d{1,3})\b').firstMatch(value)?.group(1) ?? '',
    );
    return plainMinutes != null && plainMinutes > 0
        ? Duration(minutes: plainMinutes)
        : null;
  }

  /// Live-check results by row. Shared with other sessions of the same
  /// title when a [FreeP2pLiveEvidence] is given.
  final Map<String, ({DateTime at, LocalTorrentProbeResult result})> _cache;

  /// Evidence used for ordering. It is a snapshot of [_cache] taken only at
  /// checkpoints (end of a probe stage or background batch), so rows do not
  /// reorder on every single probe. Status chips read the live [_cache].
  Map<String, ({DateTime at, LocalTorrentProbeResult result})> _rankEvidence =
      <String, ({DateTime at, LocalTorrentProbeResult result})>{};

  /// Torrent-engine operations. Production probes go through the local
  /// torrent engine; tests inject deterministic results.
  final FreeP2pProbeEngine _engine;

  /// The user's Source Priority. It orders the My Priority display inside
  /// each live-health group and decides which unchecked rows are checked
  /// next; it never decides what plays automatically ([playbackOrder]).
  List<SourceSortCriterion> _priority;

  /// How the picker orders rows inside the health groups. Display only:
  /// probing, Quick Play and Normal Play never read it.
  SourceDisplayMode _displayMode = SourceDisplayMode.myPriority;

  Future<void>? _running;

  /// Check generation. [clear] starts a new one; results of probes started
  /// in an older generation are discarded.
  int _epoch = 0;
  int _runningEpoch = 0;

  /// Picker-only: keep classifying further rows after the first stages.
  bool _continueInBackground = false;

  /// Set once the picker closed or handed a source to playback: no further
  /// batch starts, and a probe finishing afterwards does not keep a warm
  /// session (except for the source handed to playback).
  bool _closed = false;

  /// Engine session ([_sessionKey]) of the source handed to playback.
  String? _handoffSession;

  void Function()? _onUpdate;

  /// Candidates of the current bounded check that have no result yet; shown
  /// as CHECKING.
  final Set<String> _pending = <String>{};

  /// Candidates whose probe is running right now (de-duplication lock).
  final Set<String> _active = <String>{};
  List<String>? _frozenOrder;

  /// Torrents ([_sessionKey]) whose playback failed before any file was
  /// served (metadata, engine rejection, transport): every row of them is
  /// excluded from automatic playback in this session.
  final Set<String> _failedTorrents = <String>{};

  /// Rows ([_key]) whose stream opened but whose player never started.
  final Set<String> _failedFiles = <String>{};

  static const Duration _evidenceTtl = Duration(minutes: 3);

  /// First bounded batch: the rows the user's Source Priority puts first,
  /// plus static-playability, raw-seeder, raw-peer and provider-diversity
  /// alternatives.
  static const int initialShortlistSize = 6;

  /// Second bounded batch, probed only when the first batch confirmed no
  /// playable source.
  static const int expansionBatchSize = 3;

  /// Source picker only: further rows are checked one small batch at a time
  /// while the picker stays open. Normal Play never runs these.
  static const int backgroundBatchSize = 3;

  /// Most torrents one picker check classifies, counting evidence it already
  /// had (for example from Normal Play). Re-check starts a new budget.
  static const int pickerProbeLimit = 18;

  /// Simultaneous probes. Each probe holds one short-lived torrent session;
  /// three keeps the UI responsive without many competing downloads.
  static const int probeConcurrency = 3;

  /// Normal Play does not start another probe round after this much time.
  static const Duration autoPickRoundBudget = Duration(seconds: 20);

  static final RegExp _btih =
      RegExp(r'xt=urn:btih:([a-z0-9]+)', caseSensitive: false);

  String _key(SourceResult source) {
    final file = source.torrentFileIndex?.toString() ??
        source.fileNameHint?.trim().toLowerCase() ??
        'auto';
    if (source.isMagnet) {
      final hash = _btih.firstMatch(source.resource)?.group(1)?.toLowerCase();
      // The same torrent returned by two providers shares one probe result.
      if (hash != null && hash.isNotEmpty) return 'bt:$hash|$file';
    }
    return '${source.resource}|$file';
  }

  /// The torrent engine keeps one session per info hash, whichever file or
  /// provider a row routes to. Releasing a probe's warm session releases the
  /// torrent, so the playback handoff is protected per torrent, not per row.
  String _sessionKey(SourceResult source) {
    if (source.isMagnet) {
      final hash = _btih.firstMatch(source.resource)?.group(1)?.toLowerCase();
      if (hash != null && hash.isNotEmpty) return 'bt:$hash';
    }
    return source.resource;
  }

  /// Records that playback of [source] did not start. With
  /// [wholeTorrent] (the torrent itself failed: metadata, engine rejection,
  /// transport) every row of the same torrent is excluded; otherwise only
  /// rows that may route to the same file. Automatic playback (Normal Play,
  /// fallback, Quick Play) never picks an excluded row again in this
  /// session; it stays manually selectable and reads START FAILED.
  void markStartFailed(SourceResult source, {required bool wholeTorrent}) {
    if (wholeTorrent && source.isMagnet) {
      _failedTorrents.add(_sessionKey(source));
    } else {
      _failedFiles.add(_key(source));
    }
    _checkpoint();
  }

  /// Whether playback of [source], or of a row that is effectively the same
  /// torrent file, already failed to start in this session.
  bool isStartFailed(SourceResult source) =>
      _startFailedKey(_key(source));

  bool _startFailedKey(String key) {
    if (_failedFiles.contains(key)) return true;
    if (!key.startsWith('bt:')) return false;
    final split = key.indexOf('|');
    if (split < 0) return false;
    final session = key.substring(0, split);
    if (_failedTorrents.contains(session)) return true;
    // A row without explicit file routing lets the engine guess the file,
    // so it cannot be told apart from a failed file of the same torrent
    // (and the other way round).
    final auto = '$session|auto';
    if (key == auto) {
      return _failedFiles.any((failed) => failed.startsWith('$session|'));
    }
    return _failedFiles.contains(auto);
  }

  /// Whether a start failure of [a] would also exclude [b]: the same row,
  /// the same torrent file from another provider, or a row of the same
  /// torrent whose file the engine has to guess.
  bool sameStartTarget(SourceResult a, SourceResult b) {
    final keyA = _key(a);
    final keyB = _key(b);
    if (keyA == keyB) return true;
    if (!a.isMagnet || !b.isMagnet) return false;
    if (_sessionKey(a) != _sessionKey(b)) return false;
    return keyA.endsWith('|auto') || keyB.endsWith('|auto');
  }

  /// Evidence a start-failed row ranks with: below every live row, with the
  /// other failures. Its probe result stays visible in its metrics.
  static const LocalTorrentProbeResult _startFailedEvidence =
      LocalTorrentProbeResult(
    playableNow: false,
    bytesReceived: 0,
    elapsed: Duration.zero,
    firstByteLatency: null,
    peers: 0,
    connections: 0,
    downloadSpeedBytesPerSecond: 0,
    sampleWindowsPassed: 0,
    outcome: LocalTorrentProbeStatus.createError,
  );

  List<SourceSortCriterion> get priority => _priority;

  /// Applies a changed Source Priority. A frozen order is dropped, so an open
  /// picker reorders as soon as the setting is saved. Returns whether the
  /// priority changed.
  bool setPriority(List<SourceSortCriterion> priority) {
    if (listEquals(priority, _priority)) return false;
    _priority = List.unmodifiable(priority);
    _frozenOrder = null;
    return true;
  }

  SourceDisplayMode get displayMode => _displayMode;

  /// Applies a changed picker display mode. Like a priority change it is an
  /// explicit ordering choice, so a frozen order is dropped. Returns whether
  /// the mode changed.
  bool setDisplayMode(SourceDisplayMode mode) {
    if (mode == _displayMode) return false;
    _displayMode = mode;
    _frozenOrder = null;
    return true;
  }

  bool get isRunning => _running != null;

  /// Whether rows keep the order the user last chose from.
  bool get isFrozen => _frozenOrder != null;

  bool _fresh(DateTime at) => _now().difference(at) <= _evidenceTtl;

  bool get hasAnyResult => _cache.values.any((entry) => _fresh(entry.at));

  bool get hasPlayableResult => _cache.entries.any(
        (entry) =>
            _fresh(entry.value.at) &&
            entry.value.result.confirmedLive &&
            !_startFailedKey(entry.key),
      );

  /// Probing finished, produced results, and none of them proved playable.
  bool get noLiveConfirmed =>
      !isRunning && hasAnyResult && !hasPlayableResult;

  /// Probes currently in flight.
  int get activeProbeCount => _active.length;

  LocalTorrentProbeResult? resultFor(SourceResult source) {
    final key = _key(source);
    final cached = _cache[key];
    if (cached == null) return null;
    if (!_fresh(cached.at)) {
      _cache.remove(key);
      return null;
    }
    return cached.result;
  }

  LocalTorrentProbeResult? _evidenceFor(SourceResult source) {
    if (isStartFailed(source)) return _startFailedEvidence;
    final entry = _rankEvidence[_key(source)];
    if (entry == null || !_fresh(entry.at)) return null;
    return entry.result;
  }

  void _checkpoint() {
    _rankEvidence = Map.of(_cache);
  }

  void _notify() => _onUpdate?.call();

  /// Shared health presentation for mobile, desktop and Android TV rows.
  /// Returns null for a torrent that has not been probed and is not being
  /// probed right now.
  FreeP2pHealth? healthFor(SourceResult source) {
    if (!source.isMagnet) return null;
    if (isStartFailed(source)) {
      return FreeP2pHealth.startFailed(resultFor(source));
    }
    final result = resultFor(source);
    if (result == null) {
      return _pending.contains(_key(source))
          ? FreeP2pHealth.checking
          : null;
    }
    return FreeP2pHealth.fromResult(
      result,
      result.statusFor(source, mediaDuration: mediaDuration),
    );
  }

  /// Row health for display: like [healthFor], but a torrent that has not
  /// been probed reads NOT CHECKED instead of having no state. Unchecked is
  /// never shown as a failure.
  FreeP2pHealth? displayHealthFor(SourceResult source) {
    if (!source.isMagnet) return null;
    return healthFor(source) ?? FreeP2pHealth.notChecked;
  }

  /// Whether [source] failed the live check the current order is based on:
  /// no usable media arrived (NO PEERS, STALLED, SOURCE ERROR). METADATA SLOW
  /// and ENGINE ERROR are unresolved, not failures, and unchecked rows are
  /// never failures.
  bool failedLiveCheck(SourceResult source) =>
      source.isMagnet && evidenceTier(_evidenceFor(source)) == 0;

  /// Index where the trailing group of rows that failed the live check
  /// starts, or `ordered.length` when there is none. Every row from this
  /// index on is a confirmed failure, so pickers label them as one group.
  int failedGroupStart(List<SourceResult> ordered) {
    var start = ordered.length;
    while (start > 0 && failedLiveCheck(ordered[start - 1])) {
      start--;
    }
    return start;
  }

  /// Health-group section headers for a displayed list, keyed by the row
  /// index each group starts at. Uses the same evidence as the order. A pin
  /// promoted to the first row gets no header (its chip says Pinned). Empty
  /// until some torrent has been classified, so an unchecked list stays
  /// plain.
  Map<int, FreeP2pGroupHeader> groupHeaders(
    List<SourceResult> ordered, {
    bool Function(SourceResult source)? isPinned,
  }) {
    if (!ordered.any((s) => s.isMagnet && _evidenceFor(s) != null)) {
      return const <int, FreeP2pGroupHeader>{};
    }
    FreeP2pGroup group(SourceResult s) {
      if (!s.isMagnet) return FreeP2pGroup.direct;
      return switch (evidenceTier(_evidenceFor(s))) {
        3 => FreeP2pGroup.live,
        2 => FreeP2pGroup.notChecked,
        1 => FreeP2pGroup.metadataSlow,
        _ => FreeP2pGroup.failed,
      };
    }

    final headers = <int, FreeP2pGroupHeader>{};
    FreeP2pGroup? previous;
    for (var i = 0; i < ordered.length; i++) {
      if (i == 0 && isPinned != null && isPinned(ordered[0])) continue;
      final g = group(ordered[i]);
      if (g == previous) continue;
      previous = g;
      var end = i + 1;
      while (end < ordered.length && group(ordered[end]) == g) {
        end++;
      }
      headers[i] = FreeP2pGroupHeader(g, end - i);
    }
    return headers;
  }

  /// The first [limit] rows of [ordered] (0 = all). When the limit would
  /// hide every confirmed-live torrent, the best hidden one is kept as an
  /// extra row, so a limit filled by a pin or direct links cannot hide them.
  List<SourceResult> applyResultLimit(List<SourceResult> ordered, int limit) {
    if (limit <= 0 || ordered.length <= limit) return ordered;
    bool liveTorrent(SourceResult s) => s.isMagnet && quickPlayAllowed(s);
    final shown = ordered.take(limit).toList();
    if (!shown.any(liveTorrent)) {
      final hidden = ordered.skip(limit).where(liveTorrent).firstOrNull;
      if (hidden != null) shown.add(hidden);
    }
    return shown;
  }

  /// Whether Free P2P Quick Play may launch [source]: a direct HTTP source,
  /// or a torrent confirmed live by this session's probe. Pins get no
  /// exception; an unconfirmed pinned torrent stays manually selectable.
  bool quickPlayAllowed(SourceResult source) =>
      !isStartFailed(source) &&
      (!source.isMagnet || healthFor(source)?.isLive == true);

  /// Torrents of [results] confirmed live right now, counted once per row
  /// identity and never counting a start-failed row.
  int confirmedLiveCount(Iterable<SourceResult> results) {
    final keys = <String>{};
    for (final source in results) {
      if (source.isMagnet && quickPlayAllowed(source)) keys.add(_key(source));
    }
    return keys.length;
  }

  /// Whether every torrent of [results] checked so far failed only because
  /// the local engine did not start (and at least one was checked).
  bool engineLooksDown(Iterable<SourceResult> results) {
    var checked = 0;
    for (final source in results) {
      if (!source.isMagnet) continue;
      final result = resultFor(source);
      if (result == null) continue;
      if (result.status != LocalTorrentProbeStatus.engineUnavailable) {
        return false;
      }
      checked++;
    }
    return checked > 0;
  }

  /// Torrent rows of [results] with fresh live-check evidence.
  int classifiedCount(Iterable<SourceResult> results) => _freshCount(results);

  /// Why an automatic choice picked [chosen] from [results]: its live
  /// health, how many verified alternatives existed and what decided the
  /// order. Provider seeders are reported as such, never as evidence.
  Map<String, Object?> choiceSummary(
    SourceResult chosen,
    Iterable<SourceResult> results, {
    bool pinned = false,
  }) {
    final health = healthFor(chosen);
    return <String, Object?>{
      'health': chosen.isMagnet ? health?.state.name : 'directHttp',
      'confirmedLive': confirmedLiveCount(results),
      'startFailedExcluded': results
          .where((source) => isStartFailed(source))
          .map(_key)
          .toSet()
          .length,
      'pinned': pinned,
      'orderedBy': chosen.isMagnet
          ? 'liveHealth>sourcePriority>firstByte>throughput>livePeers'
          : 'directHttpFirst',
    };
  }

  /// Counts for a concise live-check summary line.
  FreeP2pCheckSummary summary(Iterable<SourceResult> results) {
    var live = 0, failed = 0, unresolved = 0, checking = 0, notChecked = 0;
    final seen = <String>{};
    for (final source in results) {
      if (!source.isMagnet || !seen.add(_key(source))) continue;
      final health = healthFor(source);
      if (health == null) {
        notChecked++;
      } else if (health.state == FreeP2pHealthState.checking) {
        checking++;
      } else if (health.isLive) {
        live++;
      } else if (health.state == FreeP2pHealthState.metadataSlow ||
          health.state == FreeP2pHealthState.engineError) {
        unresolved++;
      } else {
        failed++;
      }
    }
    return FreeP2pCheckSummary(
      live: live,
      failed: failed,
      unresolved: unresolved,
      checking: checking,
      notChecked: notChecked,
    );
  }

  /// Picker display order: live health groups first, then the
  /// [displayMode] inside each group (Recommended: measured live evidence and
  /// the static playability estimate; My Priority: the user's Source
  /// Priority; Smooth: practical playback compatibility). Keeps a frozen
  /// order. See [compareFreeP2p]. Playback uses [playbackOrder] instead.
  List<SourceResult> rank(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    final frozen = _frozenOrder;
    if (frozen != null) {
      final base = sources.sortForFreeStreaming(results);
      final frozenIndex = <String, int>{
        for (var i = 0; i < frozen.length; i++) frozen[i]: i,
      };
      final stable = [...base];
      stable.sort((a, b) => (frozenIndex[_key(a)] ?? 999999)
          .compareTo(frozenIndex[_key(b)] ?? 999999));
      return stable;
    }
    return switch (_displayMode) {
      SourceDisplayMode.myPriority => _order(results, sources, _priority),
      SourceDisplayMode.recommended => _order(results, sources, null),
      SourceDisplayMode.smooth =>
        _order(results, sources, null, within: sources.compareSmoothPlayback),
    };
  }

  /// The order Normal Play and Quick Play choose from: health groups, then
  /// the measured live evidence (first byte, throughput against the file's
  /// bitrate, live peers, compatibility; quality only breaks ties), then the
  /// static Free order. The user's Source Priority orders the My Priority
  /// display only: ranking the largest, highest-quality release first is
  /// not a safe automatic choice on a P2P stream. Independent of the picker
  /// display mode and of any frozen order; it decides only among sources,
  /// never whether an unconfirmed torrent may auto-play ([quickPlayAllowed]).
  List<SourceResult> playbackOrder(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) =>
      _order(results, sources, null);

  /// Free P2P Quick Play source among [candidates]: the first source in
  /// [playbackOrder] (a confirmed-live pin first) that [quickPlayAllowed].
  /// Null when nothing is eligible yet; an unchecked or failed pin never
  /// blocks a confirmed-live alternative.
  SourceResult? quickPlayCandidate(
    Iterable<SourceResult> candidates,
    SourceProviderService sources, {
    bool Function(SourceResult source)? isPinned,
  }) {
    var ordered = playbackOrder(candidates, sources);
    if (isPinned != null) ordered = applyPinnedPreference(ordered, isPinned);
    for (final source in ordered) {
      if (quickPlayAllowed(source)) return source;
    }
    return null;
  }

  List<SourceResult> _order(
    Iterable<SourceResult> results,
    SourceProviderService sources,
    List<SourceSortCriterion>? priority, {
    int Function(SourceResult a, SourceResult b)? within,
  }) {
    final base = sources.sortForFreeStreaming(results);
    final baseIndex = <SourceResult, int>{
      for (var i = 0; i < base.length; i++) base[i]: i,
    };
    final out = [...base];
    out.sort((a, b) {
      final live = compareFreeP2p(
        a,
        _evidenceFor(a),
        b,
        _evidenceFor(b),
        sources: sources,
        mediaDuration: mediaDuration,
        priority: priority,
        within: within,
      );
      if (live != 0) return live;
      return (baseIndex[a] ?? 999999).compareTo(baseIndex[b] ?? 999999);
    });
    return out;
  }

  /// Evidence tier. Higher is better:
  /// confirmed live > not probed / no torrent evidence > metadata unresolved
  /// > confirmed failure.
  static int evidenceTier(LocalTorrentProbeResult? result) {
    if (result == null) return 2;
    if (result.confirmedLive) return 3;
    return switch (result.status) {
      // An engine that could not start says nothing about this torrent.
      LocalTorrentProbeStatus.engineUnavailable => 2,
      LocalTorrentProbeStatus.metadataTimeout => 1,
      _ => 0,
    };
  }

  static int _failureRank(LocalTorrentProbeStatus status) => switch (status) {
        LocalTorrentProbeStatus.stalled => 3,
        LocalTorrentProbeStatus.noPeers => 2,
        LocalTorrentProbeStatus.createError => 1,
        _ => 0,
      };

  static int _statusBand(LocalTorrentProbeStatus status) => switch (status) {
        LocalTorrentProbeStatus.readyNow => 3,
        LocalTorrentProbeStatus.live => 2,
        LocalTorrentProbeStatus.slow => 1,
        _ => 0,
      };

  static int _latencyBand(Duration? latency) {
    final ms = latency?.inMilliseconds;
    if (ms == null) return 0;
    if (ms <= 500) return 4;
    if (ms <= 1200) return 3;
    if (ms <= 2500) return 2;
    return 1;
  }

  static int _throughputBand(
    LocalTorrentProbeResult result,
    SourceResult source,
    Duration? mediaDuration,
  ) {
    final headroom = result.headroomFor(source, mediaDuration: mediaDuration);
    if (headroom != null) {
      if (headroom >= 2.0) return 4;
      if (headroom >= 1.4) return 3;
      if (headroom >= 1.0) return 2;
      if (headroom >= .75) return 1;
      return 0;
    }
    final speed = result.downloadSpeedBytesPerSecond;
    if (speed >= 3 * 1024 * 1024) return 4;
    if (speed >= 1500 * 1024) return 3;
    if (speed >= 700 * 1024) return 2;
    if (speed >= 300 * 1024) return 1;
    return 0;
  }

  static int _connectionBand(LocalTorrentProbeResult result) {
    final value = result.connections > result.peers
        ? result.connections
        : result.peers;
    if (value >= 10) return 3;
    if (value >= 3) return 2;
    if (value >= 1) return 1;
    return 0;
  }

  /// Free P2P comparison between two sources given their live evidence.
  /// Returns 0 when nothing separates them; callers then fall back to the
  /// static Free order (history, provider seeds, exact file, size).
  ///
  /// Health groups, never overridden by a preference:
  /// 1. direct HTTP before torrents (no swarm startup)
  /// 2. evidence tier: confirmed live > unprobed > metadata unresolved >
  ///    confirmed failure
  /// 3. among live: status band (ready now > live > slow, which includes the
  ///    file's bitrate need); among failures: closest to working (stalled >
  ///    no peers > error)
  ///
  /// Inside a health group, [within] decides when given, otherwise
  /// [priority] (the user's Source Priority); with neither, the measured
  /// live evidence and then the caller's static order decide.
  /// Provider seeders there are the reported snapshot, not live evidence.
  /// Live sources that still tie are ordered by first-byte latency,
  /// throughput, live connections, playback history, exact file routing,
  /// compatibility and finally quality.
  static int compareFreeP2p(
    SourceResult a,
    LocalTorrentProbeResult? pa,
    SourceResult b,
    LocalTorrentProbeResult? pb, {
    required SourceProviderService sources,
    Duration? mediaDuration,
    List<SourceSortCriterion>? priority,
    int Function(SourceResult a, SourceResult b)? within,
  }) {
    int byPriority() => within != null
        ? within(a, b)
        : priority == null
            ? 0
            : sources.compareByPriority(a, b, priority);

    if (a.isMagnet != b.isMagnet) return a.isMagnet ? 1 : -1;
    if (!a.isMagnet) return byPriority();

    final tierA = evidenceTier(pa);
    final tierB = evidenceTier(pb);
    if (tierA != tierB) return tierB.compareTo(tierA);

    if (tierA == 3 && pa != null && pb != null) {
      int cmp(int x, int y) => y.compareTo(x);
      var c = cmp(
        _statusBand(pa.statusFor(a, mediaDuration: mediaDuration)),
        _statusBand(pb.statusFor(b, mediaDuration: mediaDuration)),
      );
      if (c != 0) return c;
      c = byPriority();
      if (c != 0) return c;
      c = cmp(_latencyBand(pa.firstByteLatency),
          _latencyBand(pb.firstByteLatency));
      if (c != 0) return c;
      c = cmp(_throughputBand(pa, a, mediaDuration),
          _throughputBand(pb, b, mediaDuration));
      if (c != 0) return c;
      c = cmp(_connectionBand(pa), _connectionBand(pb));
      if (c != 0) return c;
      c = cmp(sources.playbackHistoryRank(a), sources.playbackHistoryRank(b));
      if (c != 0) return c;
      c = cmp(_exactFile(a), _exactFile(b));
      if (c != 0) return c;
      c = cmp(a.compatibilityFriendly ? 1 : 0, b.compatibilityFriendly ? 1 : 0);
      if (c != 0) return c;
      // Late tie-break only: two similarly healthy live sources.
      return cmp(a.qualityRank, b.qualityRank);
    }

    if (tierA == 0 && pa != null && pb != null) {
      final c = _failureRank(pb.status).compareTo(_failureRank(pa.status));
      if (c != 0) return c;
    }
    return byPriority();
  }

  static int _exactFile(SourceResult source) =>
      source.torrentFileIndex != null ||
              source.fileNameHint?.trim().isNotEmpty == true
          ? 1
          : 0;

  /// Moves a pinned source to the top unless, in Free P2P mode, it was just
  /// probed and failed to show playable data while another torrent is
  /// confirmed live. The pin itself is kept; the row simply sits in its live
  /// rank so a healthy source is not forced below a failed preference.
  List<SourceResult> applyPinnedPreference(
    List<SourceResult> ordered,
    bool Function(SourceResult source) isPinned,
  ) {
    final out = [...ordered];
    final pinnedIndex = out.indexWhere(isPinned);
    if (pinnedIndex <= 0) return out;
    final pinned = out[pinnedIndex];
    final evidence = _evidenceFor(pinned);
    final pinFailed =
        pinned.isMagnet && evidence != null && !evidence.confirmedLive &&
            evidence.status != LocalTorrentProbeStatus.engineUnavailable;
    final liveAlternative = out.any(
      (source) =>
          !identical(source, pinned) &&
          source.isMagnet &&
          _evidenceFor(source)?.confirmedLive == true,
    );
    if (pinFailed && liveAlternative) return out;
    out.removeAt(pinnedIndex);
    out.insert(0, pinned);
    return out;
  }

  Future<void> _probeBatch(
    List<SourceResult> batch, {
    required int epoch,
    bool retain = true,
  }) async {
    await Future.wait(
      batch.map((source) async {
        final key = _key(source);
        if (resultFor(source) != null || !_active.add(key)) {
          _pending.remove(key);
          return;
        }
        try {
          final result = await _engine.probe(source, retainSession: retain);
          final stale = epoch != _epoch;
          if (!stale) {
            _cache[key] = (at: _now(), result: result);
            _log(source, result);
          }
          // A probe that outlived its check (Re-check, or the picker closed)
          // must not leave a warm session behind. The torrent handed to
          // playback keeps its own, even when this row routes to another
          // file of it.
          if (retain &&
              result.confirmedLive &&
              (stale || _closed) &&
              _sessionKey(source) != _handoffSession) {
            await _engine.releaseRetained(source);
          }
        } finally {
          _active.remove(key);
          _pending.remove(key);
        }
      }),
    );
  }

  void _log(SourceResult source, LocalTorrentProbeResult result) {
    // Logcat/console diagnostics only: categorical and numeric fields plus
    // provider metadata. Never the magnet, trackers or any credential.
    debugPrint('[orvix-p2p] ${jsonEncode(diagnosticsFor(source, result))}');
  }

  /// Non-sensitive diagnostic record for one probed source.
  Map<String, Object?> diagnosticsFor(
    SourceResult source,
    LocalTorrentProbeResult result,
  ) {
    final torrent = _playbackTrace.torrentLabel(source);
    return <String, Object?>{
      'provider': source.provider,
      if (torrent != null) 'torrent': torrent,
      if (source.quality != null) 'quality': source.quality,
      if (source.sizeBytes != null) 'sizeMb': source.sizeBytes! ~/ (1024 * 1024),
      if (source.seeders != null) 'providerSeeders': source.seeders,
      if (source.peers != null) 'providerPeers': source.peers,
      ...result.toDiagnostics(),
      'health': result.statusFor(source, mediaDuration: mediaDuration).name,
    };
  }

  /// Copyable live-check report for a user's bug report: the live check of
  /// these results plus the recent playback attempts. Contains provider
  /// metadata, hosts, states and measured numbers only.
  String diagnosticReport(Iterable<SourceResult> results) {
    final lines = <String>[];
    final seen = <String>{};
    for (final source in results) {
      if (!source.isMagnet || !seen.add(_key(source))) continue;
      final result = resultFor(source);
      if (result == null) continue;
      lines.add(jsonEncode(diagnosticsFor(source, result)));
    }
    final s = summary(results);
    return <String>[
      'Orvix Free P2P live check',
      FreeP2pPlaybackTrace.deviceLine(),
      'live=${s.live} failed=${s.failed} unresolved=${s.unresolved} '
          'checking=${s.checking} notChecked=${s.notChecked}',
      'providerSeeders/providerPeers: reported by the provider, not verified. '
          'livePeers/liveConnections/firstByteMs/speedBps: measured on this '
          'device. Rows without a line were not checked.',
      ...lines,
      ..._playbackTrace.reportLines(),
    ].join('\n');
  }

  int _freshCount(Iterable<SourceResult> results) {
    final keys = <String>{};
    for (final source in results) {
      if (source.isMagnet && resultFor(source) != null) keys.add(_key(source));
    }
    return keys.length;
  }

  /// Picker live check. Stage one probes a bounded shortlist, stage two one
  /// expansion batch when nothing is confirmed live. With
  /// [continueInBackground] (an open picker) further rows are then checked
  /// one small batch at a time, in the order the user's Source Priority and
  /// the diversity samples choose, until [pickerProbeLimit] torrents are
  /// classified, the picker closes, or a Re-check starts. At most
  /// [probeConcurrency] probes run at once. An unchecked pinned torrent
  /// ([preferred]) leads the first batch and takes one of its slots.
  Future<void> probeTopCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function()? onUpdate,
    bool continueInBackground = false,
    SourceResult? preferred,
  }) {
    _onUpdate = onUpdate;
    _continueInBackground = continueInBackground;
    final existing = _running;
    if (existing != null) {
      if (_runningEpoch == _epoch) return existing;
      // A cleared check is still finishing its in-flight probes. Start the
      // fresh check once they settle, so no torrent is probed twice at once.
      return () async {
        try {
          await existing;
        } catch (_) {}
        return probeTopCandidates(
          results,
          sources,
          onUpdate: onUpdate,
          continueInBackground: continueInBackground,
          preferred: preferred,
        );
      }();
    }

    final epoch = _epoch;
    _runningEpoch = epoch;
    // New evidence is about to arrive: never keep showing an old frozen order.
    _frozenOrder = null;
    _closed = false;
    _handoffSession = null;
    final completer = Completer<void>();
    _running = completer.future;
    final all = results.toList(growable: false);
    var budget = pickerProbeLimit - _freshCount(all);
    bool open() => epoch == _epoch && !_closed;

    final pin = preferred != null &&
            preferred.isMagnet &&
            resultFor(preferred) == null &&
            all.any((source) => _key(source) == _key(preferred))
        ? preferred
        : null;

    List<SourceResult> next(int size) {
      final count = size < budget ? size : budget;
      if (count <= 0) return const <SourceResult>[];
      final List<SourceResult> picked;
      if (pin != null && resultFor(pin) == null && !_active.contains(_key(pin))) {
        picked = [
          pin,
          ..._selectCandidates(all, sources, count - 1, {_key(pin)}),
        ];
      } else {
        picked = _selectCandidates(all, sources, count, const <String>{});
      }
      budget -= picked.length;
      return picked;
    }

    unawaited(() async {
      try {
        // Status chips update as each batch finishes; ordering changes at
        // the stage checkpoint.
        await _runStage(next(initialShortlistSize), epoch: epoch);
        if (epoch == _epoch) _checkpoint();
        _notify();

        if (open() && !hasPlayableResult) {
          await _runStage(next(expansionBatchSize), epoch: epoch);
          if (epoch == _epoch) _checkpoint();
          _notify();
        }

        // Open picker: keep classifying more rows, one bounded batch at a
        // time. These probes keep no warm session; a source chosen from them
        // starts its own torrent session.
        while (open() && _continueInBackground && budget > 0) {
          final batch = next(backgroundBatchSize);
          if (batch.isEmpty) break;
          await _runStage(batch, epoch: epoch, retain: false);
          if (epoch == _epoch) _checkpoint();
          _notify();
        }
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        _pending.clear();
        _running = null;
        _notify();
      }
    }());
    return completer.future;
  }

  Future<void> _runStage(
    List<SourceResult> candidates, {
    required int epoch,
    bool retain = true,
  }) async {
    if (candidates.isEmpty) return;
    _markChecking(candidates);
    _notify();
    for (var start = 0;
        start < candidates.length;
        start += probeConcurrency) {
      if (epoch != _epoch || _closed) {
        for (final source in candidates.skip(start)) {
          _pending.remove(_key(source));
        }
        return;
      }
      final end = (start + probeConcurrency).clamp(0, candidates.length);
      await _probeBatch(
        candidates.sublist(start, end),
        epoch: epoch,
        retain: retain,
      );
      _notify();
    }
  }

  /// Marks candidates as checking before their batch starts, so the picker
  /// shows which rows are part of the current bounded check.
  void _markChecking(List<SourceResult> candidates) {
    for (final source in candidates) {
      if (resultFor(source) == null) _pending.add(_key(source));
    }
  }

  /// Picks up to [count] unchecked torrent candidates not in [exclude]. Most
  /// follow the user's Source Priority (the order the picker shows); the
  /// rest deliberately sample the static Free P2P playability estimate, the
  /// best raw provider-seeder and provider-peer alternatives and an
  /// unrepresented provider, so neither a preference nor stale metadata can
  /// trap probing in one bucket.
  List<SourceResult> _selectCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources,
    int count,
    Set<String> exclude,
  ) {
    if (count <= 0) return const <SourceResult>[];
    final keys = <String>{};
    final staticOrder = <SourceResult>[];
    for (final source in sources.sortForFreeStreaming(results)) {
      if (!source.isMagnet) continue;
      final key = _key(source);
      if (exclude.contains(key) ||
          _active.contains(key) ||
          resultFor(source) != null) {
        continue;
      }
      // The same torrent from two providers is probed once.
      if (keys.add(key)) staticOrder.add(source);
    }
    final staticIndex = <SourceResult, int>{
      for (var i = 0; i < staticOrder.length; i++) staticOrder[i]: i,
    };
    int byStatic(SourceResult a, SourceResult b) =>
        staticIndex[a]!.compareTo(staticIndex[b]!);
    final userOrder = [...staticOrder]..sort((a, b) {
        final c = sources.compareByPriority(a, b, _priority);
        return c != 0 ? c : byStatic(a, b);
      });
    if (userOrder.length <= count) return userOrder;

    final selected = <SourceResult>[];
    final chosen = <String>{};

    void takeFrom(List<SourceResult> order, int target) {
      for (final source in order) {
        if (selected.length >= target || selected.length >= count) break;
        if (chosen.add(_key(source))) selected.add(source);
      }
    }

    takeFrom(userOrder, count > 3 ? count - 3 : 1);
    takeFrom(staticOrder, selected.length + 1);

    final bySeeders = [...staticOrder]..sort((a, b) {
        final c = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
        return c != 0 ? c : byStatic(a, b);
      });
    takeFrom(bySeeders, selected.length + 1);

    final byPeers = [...staticOrder]..sort((a, b) {
        final c = (b.peers ?? -1).compareTo(a.peers ?? -1);
        return c != 0 ? c : byStatic(a, b);
      });
    takeFrom(byPeers, selected.length + 1);

    final providers = selected.map((source) => source.provider).toSet();
    takeFrom(
      userOrder
          .where((source) => !providers.contains(source.provider))
          .toList(growable: false),
      selected.length + 1,
    );

    takeFrom(userOrder, count);
    return selected;
  }

  /// Normal Play auto-pick. Returns a direct HTTP source immediately when the
  /// static order puts one first. Otherwise probes a bounded, staged
  /// shortlist and returns only a torrent that proved it can deliver media
  /// bytes now. Returns null when no torrent was confirmed live, so the
  /// caller opens the source picker instead of launching a failed source.
  ///
  /// [preferred] is the user's pinned source. A direct HTTP pin is returned
  /// at once. A pinned torrent is probed first and auto-picked only when it
  /// is confirmed live; otherwise the best confirmed-live alternative (or
  /// null) is returned exactly as without a pin.
  Future<SourceResult?> probeBestCandidate(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function(int completed, int total)? onUpdate,
    SourceResult? preferred,
  }) async {
    if (preferred != null && !preferred.isMagnet) return preferred;
    final pin = preferred;
    final base = sources.sortForFreeStreaming(results);
    if (base.isEmpty) return null;
    final epoch = _epoch;

    bool pinConfirmedLive() =>
        pin != null && _evidenceFor(pin)?.confirmedLive == true;

    // Direct HTTP sources already have a usable transport and the static Free
    // score deliberately puts them ahead of torrents. Do not delay them with a
    // torrent-only probe; only a pinned torrent is checked before falling back
    // to the direct source.
    if (!base.first.isMagnet) {
      if (pin != null) {
        _markChecking([pin]);
        await _probeBatch([pin], epoch: epoch);
        onUpdate?.call(1, 1);
        _checkpoint();
        if (pinConfirmedLive()) return pin;
      }
      return base.first;
    }

    // Fresh evidence from an earlier check of this title already confirms
    // the pin or a source that is ready now: no new check is needed.
    _checkpoint();
    if (pinConfirmedLive()) return pin;
    if (pin == null) {
      final known = playbackOrder(base, sources).first;
      final evidence = _evidenceFor(known);
      if (known.isMagnet &&
          evidence != null &&
          evidence.statusFor(known, mediaDuration: mediaDuration) ==
              LocalTorrentProbeStatus.readyNow) {
        return known;
      }
    }

    final watch = Stopwatch()..start();
    final probed = <String>{};
    final stages = <int>[initialShortlistSize, expansionBatchSize];
    var completed = 0;
    var total = 0;

    for (var stage = 0; stage < stages.length; stage++) {
      if (stage > 0 && hasPlayableResult) break;
      final List<SourceResult> candidates;
      if (stage == 0 && pin != null) {
        // The pin leads the first batch and takes one of its slots, so the
        // check stays bounded.
        probed.add(_key(pin));
        candidates = [
          pin,
          ..._selectCandidates(base, sources, stages[stage] - 1, probed),
        ];
      } else {
        candidates = _selectCandidates(base, sources, stages[stage], probed);
      }
      if (candidates.isEmpty) break;
      probed.addAll(candidates.map(_key));
      total += candidates.length;

      for (var start = 0;
          start < candidates.length;
          start += probeConcurrency) {
        if (watch.elapsed >= autoPickRoundBudget) break;
        final end = (start + probeConcurrency).clamp(0, candidates.length);
        final batch = candidates.sublist(start, end);
        _markChecking(batch);
        await _probeBatch(batch, epoch: epoch);
        completed += batch.length;
        onUpdate?.call(completed, total);
        _checkpoint();

        // A confirmed-live pin is the user's preference: play it.
        if (pinConfirmedLive()) return pin;

        final best = playbackOrder(base, sources).first;
        final live = _evidenceFor(best);
        // Stop as soon as one candidate has strong two-window evidence that
        // also covers this file's bitrate need.
        if (best.isMagnet &&
            live != null &&
            live.statusFor(best, mediaDuration: mediaDuration) ==
                LocalTorrentProbeStatus.readyNow) {
          return best;
        }
      }
      if (watch.elapsed >= autoPickRoundBudget) break;
    }

    _checkpoint();
    final best = playbackOrder(base, sources).first;
    if (!best.isMagnet) return best;
    // Never auto-launch a torrent that did not prove it can play right now.
    return _evidenceFor(best)?.confirmedLive == true ? best : null;
  }

  /// Keeps the current order while the user plays a source, so the reopened
  /// picker shows the list they chose from. A new check run, a Source
  /// Priority change or [clear] drops it.
  void freezeRanking(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    if (_frozenOrder != null) return;
    _frozenOrder = rank(results, sources).map(_key).toList(growable: false);
  }

  /// Hands [source] to playback: no further probe batch starts, and every
  /// other warm probe session is detached. [selection] says how it was
  /// chosen (normalPlay, quickPlay or manual) for the playback report, which
  /// also records the live-check state the source had at this moment.
  Future<FreeP2pPlaybackAttempt> prepareForPlayback(
    SourceResult source, {
    String selection = 'manual',
    Map<String, Object?>? choice,
  }) async {
    _closed = true;
    _continueInBackground = false;
    _handoffSession = _sessionKey(source);
    final cached = source.isMagnet ? _cache[_key(source)] : null;
    final fresh = cached != null && _fresh(cached.at);
    final attempt = _playbackTrace.begin(
      source,
      selection: selection,
      choice: choice,
      liveCheck: source.isMagnet
          ? displayHealthFor(source)!.state.name
          : 'directHttp',
      liveEvidence: fresh
          ? <String, Object?>{
              ...cached.result.toDiagnostics(),
              'health': cached.result
                  .statusFor(source, mediaDuration: mediaDuration)
                  .name,
              'ageSec': _now().difference(cached.at).inSeconds,
            }
          : null,
    );
    await _engine.prepareForPlayback(source);
    return attempt;
  }

  /// Stops the check (no further batch starts) and detaches every warm probe
  /// session that is not playing.
  Future<void> release() async {
    _closed = true;
    _continueInBackground = false;
    await _engine.releaseAll();
  }

  /// Drops all evidence so the next check starts fresh (Re-check). A check
  /// still in flight stops scheduling probes and its late results are
  /// discarded.
  void clear() {
    _epoch++;
    unawaited(release());
    _cache.clear();
    _rankEvidence = <String, ({DateTime at, LocalTorrentProbeResult result})>{};
    _pending.clear();
    _frozenOrder = null;
  }

  /// Re-check: discards this session's evidence and starts a fresh bounded
  /// check that uses the current Source Priority.
  Future<void> recheck(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function()? onUpdate,
    bool continueInBackground = false,
    SourceResult? preferred,
  }) {
    clear();
    return probeTopCandidates(
      results,
      sources,
      onUpdate: onUpdate,
      continueInBackground: continueInBackground,
      preferred: preferred,
    );
  }
}

/// Live-check results one screen keeps across its check sessions, so
/// reopening the source list or pressing Play again on the same title does
/// not probe the same torrents again while their evidence is fresh (three
/// minutes). Re-check clears it. Warm torrent sessions are never shared.
class FreeP2pLiveEvidence {
  final Map<String, ({DateTime at, LocalTorrentProbeResult result})> _entries =
      <String, ({DateTime at, LocalTorrentProbeResult result})>{};
}

/// Torrent-engine operations behind the Free P2P live check.
abstract class FreeP2pProbeEngine {
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  });

  /// Detaches [source]'s warm probe session, if it kept one.
  Future<void> releaseRetained(SourceResult source);

  /// Keeps only [source]'s warm probe session for the playback handoff.
  Future<void> prepareForPlayback(SourceResult source);

  /// Detaches every warm probe session that is not playing.
  Future<void> releaseAll();
}

/// The local torrent engine (production).
class LocalFreeP2pProbeEngine implements FreeP2pProbeEngine {
  const LocalFreeP2pProbeEngine();

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) =>
      LocalTorrentService.instance.probe(source, retainSession: retainSession);

  @override
  Future<void> releaseRetained(SourceResult source) =>
      LocalTorrentService.instance.releaseRetainedProbe(source);

  @override
  Future<void> prepareForPlayback(SourceResult source) =>
      LocalTorrentService.instance.prepareRetainedProbeForPlayback(source);

  @override
  Future<void> releaseAll() =>
      LocalTorrentService.instance.releaseRetainedProbeSessions();
}

/// Deterministic probe results from a runner; session handling stays on the
/// local engine.
class _RunnerProbeEngine extends LocalFreeP2pProbeEngine {
  const _RunnerProbeEngine(this.runner);

  final FreeP2pProbeRunner runner;

  @override
  Future<LocalTorrentProbeResult> probe(
    SourceResult source, {
    required bool retainSession,
  }) =>
      runner(source);
}

typedef FreeP2pProbeRunner = Future<LocalTorrentProbeResult> Function(
  SourceResult source,
);

/// Shared Free P2P health states for source rows on every platform.
enum FreeP2pHealthState {
  readyNow,
  live,
  slow,
  checking,

  /// Not probed in this session: says nothing about the swarm.
  notChecked,
  metadataSlow,
  noPeers,
  stalled,
  engineError,
  sourceError,

  /// Confirmed live by the check, but playback of it did not start.
  startFailed,
}

class FreeP2pHealth {
  const FreeP2pHealth._(this.state, this.label, {this.result});

  static const checking =
      FreeP2pHealth._(FreeP2pHealthState.checking, 'CHECKING');

  static const notChecked =
      FreeP2pHealth._(FreeP2pHealthState.notChecked, 'NOT CHECKED');

  /// Playback of this source did not start in this session. Keeps the probe
  /// result, so the row still shows what the live check measured.
  factory FreeP2pHealth.startFailed(LocalTorrentProbeResult? result) =>
      FreeP2pHealth._(
        FreeP2pHealthState.startFailed,
        'START FAILED',
        result: result,
      );

  factory FreeP2pHealth.fromResult(
    LocalTorrentProbeResult result,
    LocalTorrentProbeStatus status,
  ) {
    final state = switch (status) {
      LocalTorrentProbeStatus.readyNow => FreeP2pHealthState.readyNow,
      LocalTorrentProbeStatus.live => FreeP2pHealthState.live,
      LocalTorrentProbeStatus.slow => FreeP2pHealthState.slow,
      LocalTorrentProbeStatus.metadataTimeout =>
        FreeP2pHealthState.metadataSlow,
      LocalTorrentProbeStatus.noPeers => FreeP2pHealthState.noPeers,
      LocalTorrentProbeStatus.stalled => FreeP2pHealthState.stalled,
      LocalTorrentProbeStatus.engineUnavailable =>
        FreeP2pHealthState.engineError,
      LocalTorrentProbeStatus.createError => FreeP2pHealthState.sourceError,
    };
    return FreeP2pHealth._(
      state,
      LocalTorrentProbeResult.labelForStatus(status),
      result: result,
    );
  }

  final FreeP2pHealthState state;
  final String label;
  final LocalTorrentProbeResult? result;

  bool get isLive =>
      state == FreeP2pHealthState.readyNow ||
      state == FreeP2pHealthState.live ||
      state == FreeP2pHealthState.slow;

  /// Real measured numbers worth showing next to the label. Live rows show
  /// speed, first byte and live peers; failed rows show only what explains
  /// the failure.
  String? get metrics {
    final r = result;
    if (r == null) return null;
    if (isLive) {
      final parts = <String>[
        r.speedLabel,
        if (r.firstByteLatency != null)
          '${r.firstByteLatency!.inMilliseconds} ms first byte',
        if (r.peers > 0) '${r.peers} live peers',
      ];
      return parts.join(' • ');
    }
    switch (state) {
      case FreeP2pHealthState.metadataSlow:
        final seconds = ((r.metadataElapsed?.inMilliseconds ?? 0) / 1000)
            .toStringAsFixed(0);
        final peers = r.discoveredPeers ?? r.peers;
        return 'no metadata in ${seconds}s'
            '${peers > 0 ? ' • $peers peers seen' : ''}';
      case FreeP2pHealthState.startFailed:
        return 'playback did not start • still selectable';
      case FreeP2pHealthState.stalled:
        return r.peers > 0 || r.connections > 0
            ? '${r.peers > r.connections ? r.peers : r.connections} peers, no usable data'
            : 'no usable data';
      default:
        return null;
    }
  }
}

/// Live-health groups of the Free P2P order, best first.
enum FreeP2pGroup { direct, live, notChecked, metadataSlow, failed }

/// Section header shown above the first row of a health group.
class FreeP2pGroupHeader {
  const FreeP2pGroupHeader(this.group, this.count);

  final FreeP2pGroup group;
  final int count;

  String get label => switch (group) {
        FreeP2pGroup.direct => 'Direct links ($count)',
        FreeP2pGroup.live => 'Confirmed live ($count)',
        FreeP2pGroup.notChecked =>
          'Not checked yet ($count) • reported seeders only',
        FreeP2pGroup.metadataSlow => 'Metadata slow ($count) • may still start',
        FreeP2pGroup.failed =>
          'Failed the live check ($count) • still selectable',
      };
}

class FreeP2pCheckSummary {
  const FreeP2pCheckSummary({
    required this.live,
    required this.failed,
    required this.unresolved,
    required this.checking,
    required this.notChecked,
  });

  final int live;
  final int failed;
  final int unresolved;
  final int checking;
  final int notChecked;

  /// Concise picker line, or null before any check has started.
  String? get text {
    if (live + failed + unresolved + checking == 0) return null;
    final parts = <String>[
      if (checking > 0) 'checking $checking',
      if (live > 0) '$live live',
      if (failed > 0) '$failed no usable data',
      if (unresolved > 0) '$unresolved unresolved',
      if (notChecked > 0) '$notChecked not checked',
    ];
    return 'Live check: ${parts.join(' · ')}';
  }
}
