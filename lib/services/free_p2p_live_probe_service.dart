import 'dart:async';

import 'local_torrent_service.dart';
import 'source_provider_service.dart';

class FreeP2pLiveProbeService {
  FreeP2pLiveProbeService({this.mediaDuration});

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
  Future<void>? _running;
  bool _rankingReady = false;
  List<String>? _frozenOrder;

  String _key(SourceResult source) =>
      '${source.resource}|${source.torrentFileIndex ?? source.fileNameHint ?? 'auto'}';

  bool get isRunning => _running != null;

  bool get hasAnyResult => _cache.values.any(
        (entry) =>
            DateTime.now().difference(entry.at) <= const Duration(minutes: 3),
      );

  bool get hasPlayableResult => _cache.values.any(
        (entry) =>
            DateTime.now().difference(entry.at) <= const Duration(minutes: 3) &&
            entry.result.playableNow,
      );

  LocalTorrentProbeResult? resultFor(SourceResult source) {
    final key = _key(source);
    final cached = _cache[key];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.at) > const Duration(minutes: 3)) {
      _cache.remove(key);
      return null;
    }
    return cached.result;
  }

  List<SourceResult> rank(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    final base = sources.sortForFreeStreaming(results);
    final baseIndex = <String, int>{
      for (var i = 0; i < base.length; i++) _key(base[i]): i,
    };
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
    if (_running != null && !_rankingReady) {
      return base;
    }

    final out = [...base];
    out.sort((a, b) {
      if (a.isMagnet != b.isMagnet) {
        return a.isMagnet ? 1 : -1;
      }

      final pa = resultFor(a);
      final pb = resultFor(b);
      if (pa != null && pb != null) {
        final live = pb
            .scoreFor(b, mediaDuration: mediaDuration)
            .compareTo(pa.scoreFor(a, mediaDuration: mediaDuration));
        if (live != 0) return live;
      } else if (pa != null) {
        return pa.playableNow ? -1 : 1;
      } else if (pb != null) {
        return pb.playableNow ? 1 : -1;
      }
      return (baseIndex[_key(a)] ?? 999999)
          .compareTo(baseIndex[_key(b)] ?? 999999);
    });
    return out;
  }

  Future<void> probeTopCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function()? onUpdate,
  }) {
    final existing = _running;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _running = completer.future;
    _rankingReady = false;
    unawaited(() async {
      try {
        final candidates = _probeCandidates(results, sources)
            .where((source) => resultFor(source) == null)
            .toList(growable: false);

        // Two simultaneous probes keeps the UI responsive without turning a
        // source picker into six competing full torrent downloads.
        for (var start = 0; start < candidates.length; start += 2) {
          final end = (start + 2).clamp(0, candidates.length);
          final batch = candidates.sublist(start, end);
          await Future.wait(
            batch.map((source) async {
              final result = await LocalTorrentService.instance.probe(
                source,
                retainSession: true,
              );
              _cache[_key(source)] = (at: DateTime.now(), result: result);
            }),
          );
          // Update status chips as probes finish, but keep the list ordering
          // stable until the whole shortlist has been sampled.
          onUpdate?.call();
        }
        _rankingReady = true;
        onUpdate?.call();
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        _running = null;
      }
    }());
    return completer.future;
  }

  List<SourceResult> _probeCandidates(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    final base = sources
        .sortForFreeStreaming(results)
        .where((source) => source.isMagnet)
        .toList(growable: false);
    if (base.length <= 6) return base;

    final selected = <SourceResult>[];
    final seen = <String>{};

    void add(SourceResult source) {
      final key = _key(source);
      if (seen.add(key) && selected.length < 6) selected.add(source);
    }

    // Keep most of the proven static order, then deliberately sample the best
    // raw-seeder and raw-peer alternatives so stale provider metadata cannot
    // trap live probing inside one narrow static bucket.
    for (final source in base.take(4)) {
      add(source);
    }

    final bySeeders = [...base]
      ..sort((a, b) => (b.seeders ?? -1).compareTo(a.seeders ?? -1));
    for (final source in bySeeders) {
      if (selected.length >= 5) break;
      add(source);
    }

    final byPeers = [...base]
      ..sort((a, b) => (b.peers ?? -1).compareTo(a.peers ?? -1));
    for (final source in byPeers) {
      if (selected.length >= 6) break;
      add(source);
    }

    for (final source in base) {
      if (selected.length >= 6) break;
      add(source);
    }
    return selected;
  }

  Future<SourceResult?> probeBestCandidate(
    Iterable<SourceResult> results,
    SourceProviderService sources, {
    void Function(int completed, int total)? onUpdate,
  }) async {
    final base = sources.sortForFreeStreaming(results);
    if (base.isEmpty) return null;

    // Direct HTTP sources already have a usable transport and the static Free
    // score deliberately puts them ahead of torrents. Do not delay them with a
    // torrent-only probe.
    if (!base.first.isMagnet) return base.first;

    final candidates = _probeCandidates(base, sources);
    var completed = 0;
    for (var start = 0; start < candidates.length; start += 2) {
      final end = (start + 2).clamp(0, candidates.length);
      final batch = candidates.sublist(start, end);
      await Future.wait(
        batch.map((source) async {
          if (resultFor(source) == null) {
            final result = await LocalTorrentService.instance.probe(
              source,
              retainSession: true,
            );
            _cache[_key(source)] = (at: DateTime.now(), result: result);
          }
          completed++;
        }),
      );
      onUpdate?.call(completed, candidates.length);

      final best = rank(base, sources).first;
      final live = resultFor(best);
      // Stop as soon as one candidate has strong two-window evidence. This
      // gives Normal Play real swarm validation without forcing the user to
      // wait for every shortlist entry.
      if (live?.readyNow == true) {
        _rankingReady = true;
        return best;
      }
    }

    _rankingReady = true;
    return rank(base, sources).first;
  }

  void freezeRanking(
    Iterable<SourceResult> results,
    SourceProviderService sources,
  ) {
    if (_frozenOrder != null) return;
    _frozenOrder = rank(results, sources).map(_key).toList(growable: false);
  }

  Future<void> prepareForPlayback(SourceResult source) async {
    await LocalTorrentService.instance.prepareRetainedProbeForPlayback(source);
  }

  Future<void> release() async {
    await LocalTorrentService.instance.releaseRetainedProbeSessions();
  }

  void clear() {
    unawaited(release());
    _cache.clear();
    _rankingReady = false;
    _frozenOrder = null;
  }
}
