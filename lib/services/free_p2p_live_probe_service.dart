import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'local_torrent_service.dart';
import 'source_provider_service.dart';

class FreeP2pLiveProbeService {
  FreeP2pLiveProbeService({this.mediaDuration, FreeP2pProbeRunner? probeRunner})
      : _probeRunner = probeRunner;

  final Duration? mediaDuration;

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

  final Map<String, ({DateTime at, LocalTorrentProbeResult result})> _cache =
      <String, ({DateTime at, LocalTorrentProbeResult result})>{};

  /// Evidence used for ordering. It is a snapshot of [_cache] taken only at
  /// checkpoints (end of a probe stage), so rows do not reorder while the
  /// user is selecting. Status chips read the live [_cache] instead.
  Map<String, ({DateTime at, LocalTorrentProbeResult result})> _rankEvidence =
      <String, ({DateTime at, LocalTorrentProbeResult result})>{};

  /// Probe-runner override. Production probes go through the local torrent
  /// engine; tests inject deterministic results.
  final FreeP2pProbeRunner? _probeRunner;

  Future<void>? _running;

  /// Set once a source is handed to playback. A background check never
  /// starts another probe batch after that, so no new torrent sessions
  /// compete with the stream the user chose.
  bool _handedToPlayback = false;

  /// Whether a background check may start another batch.
  bool get acceptsNewProbes => !_handedToPlayback;

  /// Candidates of the current bounded check that have no result yet; shown
  /// as CHECKING.
  final Set<String> _pending = <String>{};

  /// Candidates whose probe is running right now (de-duplication lock).
  final Set<String> _active = <String>{};
  List<String>? _frozenOrder;

  static const Duration _evidenceTtl = Duration(minutes: 3);

  /// First bounded batch: strongest static candidates plus raw-seeder,
  /// raw-peer and provider-diversity alternatives.
  static const int initialShortlistSize = 6;

  /// Second bounded batch, probed only when the first batch confirmed no
  /// playable source.
  static const int expansionBatchSize = 3;

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

  Future<LocalTorrentProbeResult> _runProbe(SourceResult source) {
    final runner = _probeRunner;
    if (runner != null) return runner(source);
    return LocalTorrentService.instance.probe(source, retainSession: true);
  }

  bool get isRunning => _running != null;

  bool _fresh(DateTime at) => DateTime.now().difference(at) <= _evidenceTtl;

  bool get hasAnyResult => _cache.values.any((entry) => _fresh(entry.at));

  bool get hasPlayableResult => _cache.values.any(
        (entry) => _fresh(entry.at) && entry.result.confirmedLive,
      );

  /// Probing finished, produced results, and none of them proved playable.
  bool get noLiveConfirmed =>
      !isRunning && hasAnyResult && !hasPlayableResult;

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
    final entry = _rankEvidence[_key(source)];
    if (entry == null || !_fresh(entry.at)) return null;
    return entry.result;
  }

  void _checkpoint() {
    _rankEvidence = Map.of(_cache);
  }

  /// Shared health presentation for mobile, desktop and Android TV rows.
  /// Returns null for a torrent that has not been probed and is not being
  /// probed right now.
  FreeP2pHealth? healthFor(SourceResult source) {
    if (!source.isMagnet) return null;
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

  /// Whether Free P2P Quick Play may launch [source]: a direct HTTP source,
  /// or a torrent confirmed live by this session's probe. Pins get no
  /// exception; an unconfirmed pinned torrent stays manually selectable.
  bool quickPlayAllowed(SourceResult source) =>
      !source.isMagnet || healthFor(source)?.isLive == true;

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

  /// Free P2P order: live playability dominates. See [compareFreeP2p].
  List<SourceResult> rank(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    final base = sources.sortForFreeStreaming(results);
    final frozen = _frozenOrder;
    if (frozen != null) {
      final frozenIndex = <String, int>{
        for (var i = 0; i < frozen.length; i++) frozen[i]: i,
      };
      final stable = [...base];
      stable.sort((a, b) => (frozenIndex[_key(a)] ?? 999999)
          .compareTo(frozenIndex[_key(b)] ?? 999999));
      return stable;
    }

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
  /// Returns 0 when live evidence does not separate them; callers then fall
  /// back to the static Free order (history, provider seeds, exact file,
  /// size). Resolution never participates outside the final live tie-break.
  ///
  /// Priority:
  /// 1. direct HTTP before torrents (no swarm startup)
  /// 2. evidence tier: confirmed live > unprobed > metadata unresolved >
  ///    confirmed failure
  /// 3. among live: status band (ready now > live > slow), first-byte
  ///    latency band, throughput/bitrate-headroom band, live connection band
  /// 4. among live with comparable bands: recent playback history, exact file
  ///    routing, compatibility, then resolution/quality as the last tie-break
  /// 5. among failures: closest to working (stalled > no peers > error)
  static int compareFreeP2p(
    SourceResult a,
    LocalTorrentProbeResult? pa,
    SourceResult b,
    LocalTorrentProbeResult? pb, {
    required SourceProviderService sources,
    Duration? mediaDuration,
  }) {
    if (a.isMagnet != b.isMagnet) return a.isMagnet ? 1 : -1;
    if (!a.isMagnet) return 0;

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
      return _failureRank(pb.status).compareTo(_failureRank(pa.status));
    }
    return 0;
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

  Future<void> _probeBatch(List<SourceResult> batch) async {
    await Future.wait(
      batch.map((source) async {
        final key = _key(source);
        if (_handedToPlayback ||
            resultFor(source) != null ||
            !_active.add(key)) {
          _pending.remove(key);
          return;
        }
        try {
          final result = await _runProbe(source);
          _cache[key] = (at: DateTime.now(), result: result);
          _log(source, result);
          // A probe that finished after playback took over must not keep a
          // warm session next to the chosen stream.
          if (_handedToPlayback && !_isSelected(source)) {
            unawaited(_releaseLateProbe(source));
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
    final hash = _btih.firstMatch(source.resource)?.group(1)?.toLowerCase();
    return <String, Object?>{
      'provider': source.provider,
      if (hash != null && hash.length >= 8) 'hash8': hash.substring(0, 8),
      if (source.quality != null) 'quality': source.quality,
      if (source.sizeBytes != null) 'sizeMb': source.sizeBytes! ~/ (1024 * 1024),
      if (source.seeders != null) 'providerSeeders': source.seeders,
      if (source.peers != null) 'providerPeers': source.peers,
      ...result.toDiagnostics(),
      'health': result.statusFor(source, mediaDuration: mediaDuration).name,
    };
  }

  /// Copyable live-check report for a user's bug report. Contains provider
  /// metadata and probe numbers only.
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
      'live=${s.live} failed=${s.failed} unresolved=${s.unresolved} '
          'checking=${s.checking} notChecked=${s.notChecked}',
      ...lines,
    ].join('\n');
  }

  Future<void> probeTopCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function()? onUpdate,
  }) {
    final existing = _running;
    if (existing != null) return existing;
    if (!acceptsNewProbes) return Future<void>.value();

    final completer = Completer<void>();
    _running = completer.future;
    final all = results.toList(growable: false);
    unawaited(() async {
      try {
        final probed = <String>{};
        final initial =
            _selectCandidates(all, sources, initialShortlistSize, probed);
        probed.addAll(initial.map(_key));
        _markChecking(initial);
        onUpdate?.call();
        // Status chips update as each batch finishes; ordering changes only
        // at the stage checkpoint below.
        for (var start = 0;
            start < initial.length && acceptsNewProbes;
            start += probeConcurrency) {
          final end = (start + probeConcurrency).clamp(0, initial.length);
          await _probeBatch(initial.sublist(start, end));
          onUpdate?.call();
        }
        _checkpoint();
        onUpdate?.call();

        if (!hasPlayableResult && acceptsNewProbes) {
          final expansion =
              _selectCandidates(all, sources, expansionBatchSize, probed);
          if (expansion.isNotEmpty) {
            _markChecking(expansion);
            onUpdate?.call();
            for (var start = 0;
                start < expansion.length && acceptsNewProbes;
                start += probeConcurrency) {
              final end =
                  (start + probeConcurrency).clamp(0, expansion.length);
              await _probeBatch(expansion.sublist(start, end));
              onUpdate?.call();
            }
            _checkpoint();
          }
        }
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        _pending.clear();
        _running = null;
        onUpdate?.call();
      }
    }());
    return completer.future;
  }

  /// Marks candidates as checking before their batch starts, so the picker
  /// shows which rows are part of the current bounded check.
  void _markChecking(List<SourceResult> candidates) {
    for (final source in candidates) {
      if (resultFor(source) == null) _pending.add(_key(source));
    }
  }

  /// Picks up to [count] torrent candidates not yet in [exclude]. Most come
  /// from the static Free order; the rest deliberately sample the best raw
  /// provider-seeder and provider-peer alternatives and an unrepresented
  /// provider, so stale static metadata cannot trap probing in one bucket.
  List<SourceResult> _selectCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources,
    int count,
    Set<String> exclude,
  ) {
    final base = sources
        .sortForFreeStreaming(results)
        .where((source) => source.isMagnet && !exclude.contains(_key(source)))
        .toList(growable: false);
    if (base.length <= count) {
      final seen = <String>{};
      return base.where((source) => seen.add(_key(source))).toList();
    }

    final selected = <SourceResult>[];
    final seen = <String>{};

    void add(SourceResult source) {
      if (selected.length < count && seen.add(_key(source))) {
        selected.add(source);
      }
    }

    final staticTake = count > 3 ? count - 3 : 1;
    for (final source in base) {
      if (selected.length >= staticTake) break;
      add(source);
    }

    final bySeeders = [...base]
      ..sort((a, b) => (b.seeders ?? -1).compareTo(a.seeders ?? -1));
    final seederTarget = selected.length + 1;
    for (final source in bySeeders) {
      if (selected.length >= seederTarget) break;
      add(source);
    }

    final byPeers = [...base]
      ..sort((a, b) => (b.peers ?? -1).compareTo(a.peers ?? -1));
    final peerTarget = selected.length + 1;
    for (final source in byPeers) {
      if (selected.length >= peerTarget) break;
      add(source);
    }

    final providers = selected.map((source) => source.provider).toSet();
    for (final source in base) {
      if (selected.length >= count) break;
      if (!providers.contains(source.provider)) {
        add(source);
        break;
      }
    }

    for (final source in base) {
      if (selected.length >= count) break;
      add(source);
    }
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

    bool pinConfirmedLive() =>
        pin != null && _evidenceFor(pin)?.confirmedLive == true;

    // Direct HTTP sources already have a usable transport and the static Free
    // score deliberately puts them ahead of torrents. Do not delay them with a
    // torrent-only probe; only a pinned torrent is checked before falling back
    // to the direct source.
    if (!base.first.isMagnet) {
      if (pin != null) {
        _markChecking([pin]);
        await _probeBatch([pin]);
        onUpdate?.call(1, 1);
        _checkpoint();
        if (pinConfirmedLive()) return pin;
      }
      return base.first;
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
        await _probeBatch(batch);
        completed += batch.length;
        onUpdate?.call(completed, total);
        _checkpoint();

        // A confirmed-live pin is the user's preference: play it.
        if (pinConfirmedLive()) return pin;

        final best = rank(base, sources).first;
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
    final best = rank(base, sources).first;
    if (!best.isMagnet) return best;
    // Never auto-launch a torrent that did not prove it can play right now.
    return _evidenceFor(best)?.confirmedLive == true ? best : null;
  }

  void freezeRanking(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    if (_frozenOrder != null) return;
    _frozenOrder = rank(results, sources).map(_key).toList(growable: false);
  }

  SourceResult? _selected;

  bool _isSelected(SourceResult source) {
    final selected = _selected;
    return selected != null &&
        (identical(selected, source) ||
            LocalTorrentService.sameTorrent(selected, source));
  }

  Future<void> _releaseLateProbe(SourceResult source) async {
    final runner = _probeRunner;
    if (runner != null) return;
    await LocalTorrentService.instance.releaseRetainedProbe(source);
  }

  /// Hands [source] to playback: no further probe batch starts in this
  /// session, and every warm probe session except the chosen torrent is
  /// detached. Unchecked or slow sources are handed over exactly like
  /// checked ones; a live check is never required to play.
  Future<void> prepareForPlayback(SourceResult source) async {
    _handedToPlayback = true;
    _selected = source;
    if (_probeRunner != null) return;
    await LocalTorrentService.instance.prepareRetainedProbeForPlayback(source);
  }

  Future<void> release() async {
    await LocalTorrentService.instance.releaseRetainedProbeSessions();
  }

  /// The player closed and the source list is shown again: a later Re-check
  /// or background check may probe again. Evidence is kept.
  void resumeAfterPlayback() {
    _handedToPlayback = false;
    _selected = null;
  }

  /// Drops all evidence so the next probe run starts fresh (Re-check).
  void clear() {
    _handedToPlayback = false;
    _selected = null;
    unawaited(release());
    _cache.clear();
    _rankEvidence = <String, ({DateTime at, LocalTorrentProbeResult result})>{};
    _pending.clear();
    _frozenOrder = null;
  }
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
  metadataSlow,
  noPeers,
  stalled,
  engineError,
  sourceError,
}

class FreeP2pHealth {
  const FreeP2pHealth._(this.state, this.label, {this.result});

  static const checking =
      FreeP2pHealth._(FreeP2pHealthState.checking, 'CHECKING');

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
      case FreeP2pHealthState.stalled:
        return r.peers > 0 || r.connections > 0
            ? '${r.peers > r.connections ? r.peers : r.connections} peers, no usable data'
            : 'no usable data';
      default:
        return null;
    }
  }
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
