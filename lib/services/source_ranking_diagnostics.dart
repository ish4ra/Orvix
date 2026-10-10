import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'free_p2p_live_probe_service.dart';
import 'platform_profile.dart';
import 'source_provider_service.dart';

/// One row of a source-list ranking snapshot. Built only from provider
/// metadata, the user's local history and live-check evidence; never a
/// magnet, tracker, addon URL or a direct link's path or query.
class SourceRankingRow {
  const SourceRankingRow({
    required this.identity,
    required this.provider,
    required this.release,
    required this.quality,
    required this.sizeBytes,
    required this.providerSeeders,
    required this.providerPeers,
    required this.fileIndex,
    required this.providerPosition,
    required this.normalizedPosition,
    required this.displayedPosition,
    required this.pinned,
    required this.historyRank,
    required this.liveEvidence,
    required this.factors,
  });

  /// `bt:<info hash>|<file index or name hint>` for a torrent, or
  /// `url:<host>#<digest>` for a direct link (the digest only shows that two
  /// devices got the same link, without revealing it).
  final String identity;
  final String provider;
  final String release;
  final String? quality;
  final int? sizeBytes;
  final int? providerSeeders;
  final int? providerPeers;
  final int? fileIndex;

  /// Position in the provider's own response (per provider).
  final int? providerPosition;

  /// Position after resolve's merge, filter and default sort.
  final int normalizedPosition;

  /// Position in the list the user sees, or null when hidden by a filter or
  /// the result limit.
  final int? displayedPosition;
  final bool pinned;

  /// Local playback history: 2 recent success … -2 recent failure.
  final int historyRank;

  /// Live-check state, or null when the source was not checked.
  final String? liveEvidence;

  /// Ranking signals for the active order.
  final Map<String, int> factors;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': identity,
        'provider': provider,
        'release': release,
        if (quality != null) 'quality': quality,
        if (sizeBytes != null) 'sizeMb': sizeBytes! ~/ (1024 * 1024),
        if (providerSeeders != null) 'providerSeeders': providerSeeders,
        if (providerPeers != null) 'providerPeers': providerPeers,
        if (fileIndex != null) 'fileIdx': fileIndex,
        if (providerPosition != null) 'providerPos': providerPosition,
        'normalizedPos': normalizedPosition,
        'shownPos': displayedPosition,
        if (pinned) 'pinned': true,
        'history': historyRank,
        if (liveEvidence != null) 'live': liveEvidence,
        'factors': factors,
      };
}

/// The order of one source list on one device, with everything that can
/// change it. Two snapshots of the same title and episode from different
/// devices can be compared with [SourceRankingComparison.compare].
class SourceRankingSnapshot {
  const SourceRankingSnapshot({
    required this.platform,
    required this.target,
    required this.mode,
    required this.priority,
    required this.cloudConnected,
    required this.compatibilityOnly,
    required this.resultLimit,
    required this.rows,
  });

  final String platform;

  /// `movie:<id>` or `series:<id>:<season>:<episode>`.
  final String target;

  /// freeP2p, smooth or priority.
  final String mode;
  final List<String> priority;
  final bool cloudConnected;
  final bool compatibilityOnly;
  final int resultLimit;

  /// Every resolved source, in normalized (resolve) order.
  final List<SourceRankingRow> rows;

  /// Identities in the order the user sees them.
  List<String> get displayedOrder {
    final shown = rows.where((row) => row.displayedPosition != null).toList()
      ..sort((a, b) => a.displayedPosition!.compareTo(b.displayedPosition!));
    return shown.map((row) => row.identity).toList(growable: false);
  }

  static final RegExp _btih =
      RegExp(r'xt=urn:btih:([a-z0-9]+)', caseSensitive: false);

  static String identityOf(SourceResult source) {
    if (source.isMagnet) {
      final hash = _btih.firstMatch(source.resource)?.group(1)?.toLowerCase();
      final file = source.torrentFileIndex?.toString() ??
          source.fileNameHint?.trim().toLowerCase() ??
          'auto';
      return 'bt:${hash ?? 'unknown'}|$file';
    }
    final host = Uri.tryParse(source.resource)?.host ?? '';
    return 'url:$host#${_digest(source.resource)}';
  }

  /// FNV-1a 32-bit: a stable, non-reversible tag for a direct link.
  static String _digest(String value) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(value)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _release(SourceResult source) {
    final lines = source.title.split('\n');
    final name = lines.length > 1 ? lines.last : lines.first;
    final clean = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 120 ? clean : '${clean.substring(0, 120)}…';
  }

  static String currentPlatform() {
    if (PlatformProfile.isAndroidTv) return 'androidTv';
    if (Platform.isAndroid) return 'androidMobile';
    return Platform.operatingSystem;
  }

  static SourceRankingSnapshot capture({
    required SourceProviderService sources,
    required String target,
    required List<SourceResult> resolved,
    required List<SourceResult> displayed,
    required String mode,
    required List<SourceSortCriterion> priority,
    required bool cloudConnected,
    bool compatibilityOnly = false,
    int resultLimit = 0,
    bool Function(SourceResult source)? isPinned,
    FreeP2pLiveProbeService? liveProbe,
    String? platform,
  }) {
    String rowKey(SourceResult source) =>
        '${identityOf(source)}\u0000${source.provider}';
    final shown = <String, int>{};
    for (var i = 0; i < displayed.length; i++) {
      shown.putIfAbsent(rowKey(displayed[i]), () => i);
    }
    final rows = <SourceRankingRow>[
      for (var i = 0; i < resolved.length; i++)
        () {
          final source = resolved[i];
          final health = liveProbe?.healthFor(source);
          return SourceRankingRow(
            identity: identityOf(source),
            provider: source.provider,
            release: _release(source),
            quality: source.quality,
            sizeBytes: source.sizeBytes,
            providerSeeders: source.seeders,
            providerPeers: source.peers,
            fileIndex: source.torrentFileIndex,
            providerPosition: source.providerPosition,
            normalizedPosition: i,
            displayedPosition: shown[rowKey(source)],
            pinned: isPinned?.call(source) ?? false,
            historyRank: sources.playbackHistoryRank(source),
            liveEvidence: health?.state.name,
            factors: mode == 'priority'
                ? sources.priorityFactors(source, priority)
                : sources.freeStreamingFactors(source),
          );
        }(),
    ];
    return SourceRankingSnapshot(
      platform: platform ?? currentPlatform(),
      target: target,
      mode: mode,
      priority: priority.map((criterion) => criterion.name).toList(),
      cloudConnected: cloudConnected,
      compatibilityOnly: compatibilityOnly,
      resultLimit: resultLimit,
      rows: rows,
    );
  }

  Map<String, Object?> headerJson() => <String, Object?>{
        'platform': platform,
        'target': target,
        'mode': mode,
        'priority': priority,
        'cloudConnected': cloudConnected,
        'compatibilityOnly': compatibilityOnly,
        'resultLimit': resultLimit,
        'sources': rows.length,
      };

  /// Copyable report: one header line, then one line per source.
  String toReport() => <String>[
        'Orvix source ranking',
        jsonEncode(headerJson()),
        for (final row in rows) jsonEncode(row.toJson()),
      ].join('\n');

  /// Most recent snapshot on this device, kept in memory only.
  static SourceRankingSnapshot? latest;

  /// Records [snapshot] as the latest and writes it to the device log.
  static void record(SourceRankingSnapshot snapshot) {
    latest = snapshot;
    debugPrint('[orvix-ranking] ${jsonEncode(snapshot.headerJson())}');
    for (final row in snapshot.rows) {
      debugPrint('[orvix-ranking] ${jsonEncode(row.toJson())}');
    }
  }
}

enum RankingDifferenceKind {
  /// The providers returned different sources or different metadata.
  providerResponse,

  /// Different sort mode, Source Priority, filter, limit or cloud path.
  preferences,

  /// A different pinned source.
  pinned,

  /// Different local playback history for the same source.
  playbackHistory,

  /// Different live-check evidence.
  liveEvidence,

  /// Identical inputs, different order: a real ordering defect.
  orderingDefect,
}

class RankingDifference {
  const RankingDifference(this.kind, this.detail);

  final RankingDifferenceKind kind;
  final String detail;

  @override
  String toString() => '${kind.name}: $detail';
}

/// Explains why two devices show the same title's sources in a different
/// order, separating legitimate input differences from ordering defects.
class SourceRankingComparison {
  SourceRankingComparison._();

  static List<RankingDifference> compare(
    SourceRankingSnapshot a,
    SourceRankingSnapshot b,
  ) {
    final out = <RankingDifference>[];
    if (a.target != b.target) {
      out.add(RankingDifference(
        RankingDifferenceKind.preferences,
        'different title or episode (${a.target} vs ${b.target})',
      ));
      return out;
    }

    final rowsA = {for (final row in a.rows) row.identity: row};
    final rowsB = {for (final row in b.rows) row.identity: row};
    final onlyA = rowsA.keys.where((id) => !rowsB.containsKey(id)).toList();
    final onlyB = rowsB.keys.where((id) => !rowsA.containsKey(id)).toList();
    if (onlyA.isNotEmpty || onlyB.isNotEmpty) {
      out.add(RankingDifference(
        RankingDifferenceKind.providerResponse,
        '${onlyA.length} source(s) only on ${a.platform}, '
        '${onlyB.length} only on ${b.platform}',
      ));
    }
    final common = rowsA.keys.where(rowsB.containsKey).toList();
    final metadata = common.where((id) {
      final x = rowsA[id]!;
      final y = rowsB[id]!;
      return x.provider != y.provider ||
          x.providerSeeders != y.providerSeeders ||
          x.providerPeers != y.providerPeers ||
          x.sizeBytes != y.sizeBytes ||
          x.quality != y.quality ||
          x.release != y.release ||
          x.providerPosition != y.providerPosition;
    }).toList();
    if (metadata.isNotEmpty) {
      out.add(RankingDifference(
        RankingDifferenceKind.providerResponse,
        '${metadata.length} source(s) with different provider metadata',
      ));
    }
    final prefs = <String>[
      if (a.mode != b.mode) 'mode ${a.mode} vs ${b.mode}',
      if (!_samePriority(a, b)) 'Source Priority differs',
      if (a.cloudConnected != b.cloudConnected)
        'cloud/debrid connected ${a.cloudConnected} vs ${b.cloudConnected}',
      if (a.compatibilityOnly != b.compatibilityOnly)
        'compatibility filter differs',
      if (a.resultLimit != b.resultLimit)
        'result limit ${a.resultLimit} vs ${b.resultLimit}',
    ];
    if (prefs.isNotEmpty) {
      out.add(RankingDifference(
        RankingDifferenceKind.preferences,
        prefs.join('; '),
      ));
    }

    final pinA = a.rows.where((row) => row.pinned).map((r) => r.identity);
    final pinB = b.rows.where((row) => row.pinned).map((r) => r.identity);
    if (pinA.toSet().difference(pinB.toSet()).isNotEmpty ||
        pinB.toSet().difference(pinA.toSet()).isNotEmpty) {
      out.add(const RankingDifference(
        RankingDifferenceKind.pinned,
        'a different source is pinned',
      ));
    }

    final history = common
        .where((id) => rowsA[id]!.historyRank != rowsB[id]!.historyRank)
        .toList();
    if (history.isNotEmpty) {
      out.add(RankingDifference(
        RankingDifferenceKind.playbackHistory,
        '${history.length} source(s) with different local playback history',
      ));
    }

    final live = common
        .where((id) => rowsA[id]!.liveEvidence != rowsB[id]!.liveEvidence)
        .toList();
    if (live.isNotEmpty) {
      out.add(RankingDifference(
        RankingDifferenceKind.liveEvidence,
        '${live.length} source(s) with different live-check evidence',
      ));
    }

    if (out.isEmpty && !_sameOrder(a.displayedOrder, b.displayedOrder)) {
      out.add(RankingDifference(
        RankingDifferenceKind.orderingDefect,
        'identical inputs produced a different order on '
        '${a.platform} and ${b.platform}',
      ));
    }
    return out;
  }

  static bool _samePriority(SourceRankingSnapshot a, SourceRankingSnapshot b) =>
      _sameOrder(a.priority, b.priority);

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
