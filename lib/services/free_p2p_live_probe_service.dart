import 'dart:async';

import 'local_torrent_service.dart';
import 'source_provider_service.dart';

class FreeP2pLiveProbeService {
  final Map<String, ({DateTime at, LocalTorrentProbeResult result})> _cache =
      <String, ({DateTime at, LocalTorrentProbeResult result})>{};
  Future<void>? _running;

  String _key(SourceResult source) =>
      '${source.resource}|${source.torrentFileIndex ?? source.fileNameHint ?? 'auto'}';

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
    final out = [...base];
    out.sort((a, b) {
      final pa = resultFor(a);
      final pb = resultFor(b);
      if (pa != null && pb != null) {
        final live = pb.score.compareTo(pa.score);
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
    unawaited(() async {
      try {
        final candidates = sources
            .sortForFreeStreaming(results)
            .where((source) => source.isMagnet)
            .where((source) => resultFor(source) == null)
            .take(6)
            .toList(growable: false);

        // Two simultaneous probes keeps the UI responsive without turning a
        // source picker into six competing full torrent downloads.
        for (var start = 0; start < candidates.length; start += 2) {
          final end = (start + 2).clamp(0, candidates.length);
          final batch = candidates.sublist(start, end);
          await Future.wait(
            batch.map((source) async {
              final result = await LocalTorrentService.instance.probe(source);
              _cache[_key(source)] = (at: DateTime.now(), result: result);
            }),
          );
          onUpdate?.call();
        }
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

  void clear() => _cache.clear();
}
