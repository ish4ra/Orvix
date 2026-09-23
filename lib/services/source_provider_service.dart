import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

enum SourceSortMode { seeders, fileSize, quality }

enum SourceSortCriterion {
  cache,
  releaseQuality,
  resolution,
  fileSize,
  seeders,
}

extension SourceSortCriterionLabel on SourceSortCriterion {
  String get label {
    switch (this) {
      case SourceSortCriterion.cache:
        return 'Cache';
      case SourceSortCriterion.releaseQuality:
        return 'Quality';
      case SourceSortCriterion.resolution:
        return 'Resolution';
      case SourceSortCriterion.fileSize:
        return 'Size';
      case SourceSortCriterion.seeders:
        return 'Seeders';
    }
  }
}

extension SourceSortModeLabel on SourceSortMode {
  String get label {
    switch (this) {
      case SourceSortMode.seeders:
        return 'Seeders';
      case SourceSortMode.fileSize:
        return 'File size';
      case SourceSortMode.quality:
        return 'Source type';
    }
  }
}

class SourceResult {
  const SourceResult({
    required this.provider,
    required this.title,
    required this.resource,
    required this.isMagnet,
    required this.sortMode,
    this.quality,
    this.releaseQuality,
    this.preferredGroup = false,
    this.cached = false,
    this.seeders,
    this.sizeBytes,
    this.torrentFileIndex,
    this.fileNameHint,
    this.videoHash,
    this.bingeGroup,
  });

  final String provider;
  final String title;
  final String resource;
  final bool isMagnet;
  final SourceSortMode sortMode;
  final String? quality;
  final String? releaseQuality;
  final bool preferredGroup;
  final bool cached;
  final int? seeders;
  final int? sizeBytes;

  /// Stremio's torrent file index. This identifies the exact playable file
  /// inside a multi-file torrent/season pack.
  final int? torrentFileIndex;

  /// Filename supplied by the addon's behaviorHints. This is useful when the
  /// cloud provider creates a folder for the torrent and the intended episode
  /// has to be located among many child files.
  final String? fileNameHint;

  /// OpenSubtitles-compatible file hash supplied by the stream addon's
  /// behaviorHints. When present, Orvix can do exact subtitle matching without
  /// seeking to the end of a live P2P stream.
  final String? videoHash;

  /// Stable Stremio stream-family identifier when the addon provides one.
  /// Torrentio/other addons can keep this stable across episodes, which makes
  /// a series-wide pin possible without guessing from filenames.
  final String? bingeGroup;

  int get qualityRank {
    var rank = switch (quality?.toUpperCase()) {
      '2160P' || '4K' => 600,
      '1440P' => 500,
      '1080P' => 400,
      '720P' => 300,
      '480P' => 200,
      _ => 100,
    };
    // A tiny file labelled 4K/1080p is usually a low-bitrate re-encode or bad
    // metadata. Keep it visible, but don't let the label alone beat sane files.
    final size = sizeBytes ?? 0;
    const gb = 1024 * 1024 * 1024;
    if ((quality?.toUpperCase() == '4K' || quality?.toUpperCase() == '2160P') &&
        size > 0 &&
        size < 1 * gb) rank -= 230;
    if (quality?.toUpperCase() == '1080P' &&
        size > 0 &&
        size < 350 * 1024 * 1024) rank -= 120;
    return rank;
  }

  int get releaseQualityRank {
    switch (releaseQuality?.toUpperCase()) {
      case 'REMUX':
        return 800;
      case 'BLURAY':
        return 700;
      case 'WEB-DL':
        return 600;
      case 'WEBRIP':
        return 550;
      case 'HDTV':
        return 400;
      case 'DVD':
        return 250;
      case 'CAM':
        return 100;
      default:
        return 200;
    }
  }

  int get compatibilityRisk {
    final text = '$title ${fileNameHint ?? ''}'.toLowerCase();
    var risk = 0;

    // File size is intentionally NOT a compatibility signal. Very large
    // remuxes can still be excellent when the stream path is healthy.
    if (RegExp(r'(^|[\s._\-\[(])(8k|4320p)(?=$|[\s._\-\])])').hasMatch(text)) {
      risk += 100;
    }
    if (RegExp(r'(^|[\s._\-\[(])(av1|av01)(?=$|[\s._\-\])])').hasMatch(text)) {
      risk += 45;
    }
    if (RegExp(
      r'(^|[\s._\-\[(])(hi10p|h\.?264[ ._-]?10bit|avc[ ._-]?10bit)(?=$|[\s._\-\])])',
    ).hasMatch(text)) {
      risk += 40;
    }

    final hasDolbyVision = RegExp(
      r'(^|[\s._\-\[(])(dovi|dolby[ ._-]?vision|dv)(?=$|[\s._\-\])])',
    ).hasMatch(text);
    final hasHdrFallback = RegExp(
      r'(^|[\s._\-\[(])(hdr10\+?|hdr)(?=$|[\s._\-\])])',
    ).hasMatch(text);
    if (hasDolbyVision && !hasHdrFallback) risk += 30;

    return risk;
  }

  bool get compatibilityFriendly => compatibilityRisk == 0;

  String? get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    if (bytes >= tb) {
      return '${(bytes / tb).toStringAsFixed(bytes >= 10 * tb ? 1 : 2)} TB';
    }
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 1 : 2)} GB';
    }
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  /// Auto-pick follows the same default priority shown in Source Engine:
  /// cache -> quality/source type -> resolution -> size -> seeders.
  int get preferenceScore {
    final cacheRank = cached ? 1 : 0;
    final seederRank = (seeders ?? -1).clamp(-1, 999999).toInt() + 1;
    final sizeMb = ((sizeBytes ?? 0) ~/ (1024 * 1024)).clamp(0, 999999).toInt();

    return cacheRank * 1000000000000000000 +
        releaseQualityRank * 1000000000000000 +
        qualityRank * 1000000000000 +
        sizeMb * 1000000 +
        seederRank;
  }
}

class FreeSourceAssessment {
  const FreeSourceAssessment({
    required this.label,
    required this.detail,
    required this.recommended,
    required this.warning,
  });

  final String label;
  final String detail;
  final bool recommended;
  final bool warning;
}

class _SourcePlaybackHistory {
  const _SourcePlaybackHistory({
    required this.successes,
    required this.failures,
    this.lastSuccess,
    this.lastFailure,
    this.lastFailureReason,
  });

  final int successes;
  final int failures;
  final DateTime? lastSuccess;
  final DateTime? lastFailure;
  final String? lastFailureReason;

  Map<String, dynamic> toJson() => {
        'successes': successes,
        'failures': failures,
        if (lastSuccess != null) 'lastSuccess': lastSuccess!.toIso8601String(),
        if (lastFailure != null) 'lastFailure': lastFailure!.toIso8601String(),
        if (lastFailureReason != null) 'lastFailureReason': lastFailureReason,
      };

  static _SourcePlaybackHistory fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return const _SourcePlaybackHistory(successes: 0, failures: 0);
    }
    return _SourcePlaybackHistory(
      successes: int.tryParse(raw['successes']?.toString() ?? '') ?? 0,
      failures: int.tryParse(raw['failures']?.toString() ?? '') ?? 0,
      lastSuccess: DateTime.tryParse(raw['lastSuccess']?.toString() ?? ''),
      lastFailure: DateTime.tryParse(raw['lastFailure']?.toString() ?? ''),
      lastFailureReason: raw['lastFailureReason']?.toString(),
    );
  }
}
class _SourceResolveCacheEntry {
  const _SourceResolveCacheEntry({
    required this.createdAt,
    required this.results,
  });

  final DateTime createdAt;
  final List<SourceResult> results;
}

class PinnedSourcePreference {
  const PinnedSourcePreference({
    required this.identity,
    required this.provider,
    required this.label,
    this.bingeGroup,
  });

  final String identity;
  final String provider;
  final String label;
  final String? bingeGroup;
}

class SourceProviderService {
  SourceProviderService({http.Client? client})
      : _client = client ?? http.Client();

  static const _prefsKey = 'pikora_source_addons';
  static const _torrentioKey = 'pikora_integrated_torrentio_url_v1';
  // AIOStreams manifest URLs can contain an encrypted profile credential.
  // Keep the value local-only instead of putting it in cloud preferences.
  static const _aioStreamsManifestKey = 'local_aiostreams_manifest_v1';

  // v2 intentionally resets the old default. v0.3.7 makes the default order
  // Quality -> Seeders -> Size while still allowing the user to switch it.
  static const _sortKey = 'pikora_source_sort_mode_v2';
  static const _priorityKey = 'orvix_source_priority_v6';
  static const _show3DKey = 'orvix_show_3d_sources_v1';
  static const _showLowQualityKey = 'orvix_show_low_quality_sources_v1';
  static const _preferredGroupsKey = 'orvix_preferred_release_groups_v1';
  static const _resultLimitKey = 'orvix_source_result_limit_v1';
  static const _pinnedSourcePrefix = 'orvix_pinned_source_v1_';
  static const _tvLegacyPinsClearedKey = 'orvix_tv_legacy_pins_cleared_beta8';
  static const _playbackHistoryKey = 'orvix_source_playback_history_v1';
  static const defaultResultLimit = 0; // 0 = show all
  static const _recommendedProvidersSeedKey =
      'orvix_recommended_source_pool_seeded_v1';
  static const _recommendedAddonUrls = <String>[
    'https://comet.elfhosted.com',
    'https://mediafusion.elfhosted.com',
  ];

  // A distributor may inject an authorized/self-hosted Stremio-compatible
  // Torrentio endpoint at build time without putting a public index URL in
  // source control. Existing users are migrated automatically from the old
  // manual provider list, so they do not have to add it again after updating.
  static const _bundledTorrentioProvider = String.fromEnvironment(
    'PIKORA_TORRENTIO_URL',
    defaultValue: 'https://torrentio.strem.fun',
  );

  final http.Client _client;
  final Map<String, _SourcePlaybackHistory> _playbackHistory =
      <String, _SourcePlaybackHistory>{};
  bool _playbackHistoryLoaded = false;
  final Map<String, _SourceResolveCacheEntry> _resolveCache =
      <String, _SourceResolveCacheEntry>{};
  final Map<String, Future<List<SourceResult>>> _resolveInFlight =
      <String, Future<List<SourceResult>>>{};

  Future<void> _ensurePlaybackHistoryLoaded() async {
    if (_playbackHistoryLoaded) return;
    _playbackHistoryLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_playbackHistoryKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final entry in decoded.entries) {
        _playbackHistory[entry.key] =
            _SourcePlaybackHistory.fromJson(entry.value);
      }
    } catch (_) {
      _playbackHistory.clear();
    }
  }

  String _playbackHistoryIdentity(SourceResult source) {
    if (source.isMagnet) {
      final match = RegExp(
        r'xt=urn:btih:([a-zA-Z0-9]+)',
        caseSensitive: false,
      ).firstMatch(source.resource);
      final hash = match?.group(1)?.toLowerCase() ?? source.resource;
      final file = source.torrentFileIndex?.toString() ??
          source.fileNameHint?.trim().toLowerCase() ??
          'auto';
      return 'bt:$hash:$file';
    }
    return 'url:${source.resource}';
  }

  _SourcePlaybackHistory? _historyFor(SourceResult source) =>
      _playbackHistory[_playbackHistoryIdentity(source)];

  int _historyRank(SourceResult source) {
    final history = _historyFor(source);
    if (history == null) return 0;

    final now = DateTime.now();
    final lastSuccess = history.lastSuccess;
    final lastFailure = history.lastFailure;
    final successFresh = lastSuccess != null &&
        now.difference(lastSuccess).abs() < const Duration(days: 14);
    final failureFresh = lastFailure != null &&
        now.difference(lastFailure).abs() < const Duration(days: 7);

    if (successFresh &&
        (!failureFresh ||
            lastFailure == null ||
            lastSuccess!.isAfter(lastFailure))) {
      return 2;
    }
    if (failureFresh &&
        (lastSuccess == null || lastFailure!.isAfter(lastSuccess))) {
      return -2;
    }
    if (history.successes > history.failures) return 1;
    if (history.failures > history.successes) return -1;
    return 0;
  }

  Future<void> recordPlaybackOutcome(
    SourceResult source, {
    required bool success,
    String? reason,
  }) async {
    if (!_playbackHistoryLoaded) {
      await _ensurePlaybackHistoryLoaded();
    }
    final key = _playbackHistoryIdentity(source);
    final previous = _playbackHistory[key] ??
        const _SourcePlaybackHistory(successes: 0, failures: 0);
    final now = DateTime.now();
    _playbackHistory[key] = _SourcePlaybackHistory(
      successes: previous.successes + (success ? 1 : 0),
      failures: previous.failures + (success ? 0 : 1),
      lastSuccess: success ? now : previous.lastSuccess,
      lastFailure: success ? previous.lastFailure : now,
      lastFailureReason: success
          ? previous.lastFailureReason
          : reason?.trim().isNotEmpty == true
              ? reason!.trim()
              : previous.lastFailureReason,
    );

    if (_playbackHistory.length > 80) {
      final entries = _playbackHistory.entries.toList()
        ..sort((a, b) {
          final aTime = a.value.lastSuccess ??
              a.value.lastFailure ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.value.lastSuccess ??
              b.value.lastFailure ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });
      final keep = entries.take(80).map((entry) => entry.key).toSet();
      _playbackHistory.removeWhere((key, value) => !keep.contains(key));
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playbackHistoryKey,
      jsonEncode(
        _playbackHistory.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      ),
    );
  }

  (String, String) _friendlyFailureReason(String? raw) {
    final clean = raw?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    final lower = clean.toLowerCase();

    final speedMatch = RegExp(
      r'speed:\s*([0-9.]+\s*(?:kb/s|mb/s))',
      caseSensitive: false,
    ).firstMatch(clean);
    if (lower.contains('timed out') ||
        lower.contains('taking longer') ||
        lower.contains('no data') ||
        lower.contains('buffer')) {
      final speed = speedMatch?.group(1);
      return (
        'SLOW / STALLED',
        speed == null
            ? 'This release recently failed to deliver playable data in time.'
            : 'Recent attempt stalled while the torrent engine reported about $speed.',
      );
    }
    if (lower.contains('decoder') ||
        lower.contains('codec') ||
        lower.contains('format') ||
        lower.contains('avcodec')) {
      return (
        'FORMAT FAILED',
        'This release recently reached the player but its codec/container path failed.',
      );
    }
    if (lower.contains('file') ||
        lower.contains('404') ||
        lower.contains('invalid') ||
        lower.contains('index')) {
      return (
        'FILE ROUTE FAILED',
        'The recent attempt could not resolve/open the expected video file cleanly.',
      );
    }
    return const (
      'FAILED RECENTLY',
      'This exact release failed to start recently; try another source first.',
    );
  }

  FreeSourceAssessment assessFreePlayback(SourceResult source) {
    final historyRank = _historyRank(source);
    final seeders = source.seeders ?? 0;
    final size = source.sizeBytes ?? 0;
    const mb = 1024 * 1024;
    const gb = 1024 * mb;
    final exactFile = source.torrentFileIndex != null ||
        source.fileNameHint?.trim().isNotEmpty == true;

    if (historyRank <= -2) {
      final reason = _friendlyFailureReason(_historyFor(source)?.lastFailureReason);
      return FreeSourceAssessment(
        label: reason.$1,
        detail: reason.$2,
        recommended: false,
        warning: true,
      );
    }
    if (!source.isMagnet) {
      return const FreeSourceAssessment(
        label: 'DIRECT',
        detail: 'Direct HTTP stream; no torrent swarm startup is required.',
        recommended: true,
        warning: false,
      );
    }
    if (source.compatibilityRisk > 0) {
      return const FreeSourceAssessment(
        label: 'FORMAT RISK',
        detail: 'The release name suggests a codec/HDR profile that can be less reliable on TV hardware.',
        recommended: false,
        warning: true,
      );
    }
    if (seeders <= 0) {
      return const FreeSourceAssessment(
        label: 'NO SEEDS',
        detail: 'The provider reports no seeders, so P2P startup is unlikely.',
        recommended: false,
        warning: true,
      );
    }
    if (seeders < 3) {
      return const FreeSourceAssessment(
        label: 'WEAK SWARM',
        detail: 'Only a very small reported swarm is available.',
        recommended: false,
        warning: true,
      );
    }

    final practicalSize =
        size == 0 || (size >= 200 * mb && size <= 4 * gb);
    if (seeders >= 25 && practicalSize && exactFile) {
      return FreeSourceAssessment(
        label: 'RECOMMENDED',
        detail: 'Strong reported swarm${size > 0 ? ', practical ${source.sizeLabel}' : ''}, and an exact file hint/index.',
        recommended: true,
        warning: false,
      );
    }
    if (seeders >= 10 && practicalSize) {
      return FreeSourceAssessment(
        label: 'STRONG SWARM',
        detail: 'Healthy reported seeder count${size > 0 ? ' with a practical ${source.sizeLabel} payload' : ''}.',
        recommended: true,
        warning: false,
      );
    }
    if (size > 6 * gb) {
      return const FreeSourceAssessment(
        label: 'HEAVY',
        detail: 'Large payload; it may need substantially more real torrent throughput before playback is stable.',
        recommended: false,
        warning: true,
      );
    }
    if (!exactFile) {
      return const FreeSourceAssessment(
        label: 'AUTO FILE',
        detail: 'The torrent engine must auto-select the video file because the provider did not supply an exact index/name.',
        recommended: false,
        warning: false,
      );
    }
    return const FreeSourceAssessment(
      label: 'P2P',
      detail: 'Normal torrent source. Reported seeders are only a snapshot, not a guarantee of real download speed.',
      recommended: false,
      warning: false,
    );
  }
  Future<List<String>> getAddonUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateTorrentio(prefs);
    await _seedRecommendedProviders(prefs);

    final out = <String>[];
    final torrentio = _normalizeAddonUrl(
      prefs.getString(_torrentioKey) ?? _bundledTorrentioProvider,
    );
    if (torrentio != null) {
      final broad = _broadenTorrentioUrl(torrentio);
      if (broad != null && broad != torrentio) out.add(broad);
      out.add(torrentio);
    }

    final aioStreams = _normalizeAddonUrl(
      prefs.getString(_aioStreamsManifestKey) ?? '',
    );
    if (aioStreams != null && !out.contains(aioStreams)) {
      out.add(aioStreams);
    }

    for (final raw in prefs.getStringList(_prefsKey) ?? const <String>[]) {
      final value = _normalizeAddonUrl(raw);
      if (value != null && !out.contains(value)) out.add(value);
    }
    return out;
  }

  Future<String?> getIntegratedTorrentioUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateTorrentio(prefs);
    return _normalizeAddonUrl(
      prefs.getString(_torrentioKey) ?? _bundledTorrentioProvider,
    );
  }

  Future<String?> getAioStreamsManifestUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return _normalizeAddonUrl(
      prefs.getString(_aioStreamsManifestKey) ?? '',
    );
  }

  Future<void> setAioStreamsManifestUrl(String raw) async {
    final clean = raw.trim();
    if (clean.isEmpty || !clean.toLowerCase().contains('/manifest.json')) {
      throw const FormatException(
        'Paste the full AIOStreams manifest URL generated by the instance.',
      );
    }
    final normalized = _normalizeAddonUrl(clean);
    if (normalized == null) {
      throw const FormatException(
          'Enter a valid HTTPS AIOStreams manifest URL.');
    }
    final uri = Uri.tryParse(clean);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('AIOStreams manifest must use HTTPS.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_aioStreamsManifestKey, normalized);
  }

  Future<void> clearAioStreamsManifestUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_aioStreamsManifestKey);
  }

  Future<SourceSortMode> getSortMode() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_sortKey);
    return SourceSortMode.values.firstWhere(
      (mode) => mode.name == stored,
      orElse: () => SourceSortMode.quality,
    );
  }

  Future<void> setSortMode(SourceSortMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortKey, mode.name);
  }

  static const defaultPriority = <SourceSortCriterion>[
    SourceSortCriterion.cache,
    SourceSortCriterion.releaseQuality,
    SourceSortCriterion.resolution,
    SourceSortCriterion.fileSize,
    SourceSortCriterion.seeders,
  ];

  Future<List<SourceSortCriterion>> getPriorityOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_priorityKey);
    if (stored == null || stored.isEmpty) return [...defaultPriority];
    final out = <SourceSortCriterion>[];
    for (final value in stored) {
      for (final criterion in SourceSortCriterion.values) {
        if (criterion.name == value && !out.contains(criterion))
          out.add(criterion);
      }
    }
    for (final criterion in defaultPriority) {
      if (!out.contains(criterion)) out.add(criterion);
    }
    return out;
  }

  Future<bool> getShow3D() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_show3DKey) ?? false;
  }

  Future<void> setShow3D(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_show3DKey, value);
  }

  Future<bool> getShowLowQuality() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showLowQualityKey) ?? false;
  }

  Future<void> setShowLowQuality(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showLowQualityKey, value);
  }

  Future<List<String>> getPreferredGroups() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_preferredGroupsKey) ?? const <String>[])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> setPreferredGroups(List<String> values) async {
    final cleaned = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final v = value.trim();
      if (v.isEmpty) continue;
      final key = v.toLowerCase();
      if (seen.add(key)) cleaned.add(v);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_preferredGroupsKey, cleaned);
  }

  Future<int> getResultLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_resultLimitKey) ?? defaultResultLimit;
    return value < 0 ? defaultResultLimit : value.clamp(0, 500).toInt();
  }

  Future<void> setResultLimit(int value) async {
    final normalized =
        value < 0 ? defaultResultLimit : value.clamp(0, 500).toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_resultLimitKey, normalized);
  }

  String sourceTargetKey(MediaItem item, {EpisodeItem? episode}) {
    // Movies keep one exact pin per title. TV keeps one source-family pin per
    // series, matching Debrify's source binding model while avoiding a separate
    // preference for every episode.
    return '${item.kind.name}:${item.id}';
  }

  String sourceIdentity(SourceResult result, {bool seriesWide = false}) {
    final provider = result.provider.trim().toLowerCase();

    final bingeGroup = result.bingeGroup?.trim();
    if (seriesWide && bingeGroup != null && bingeGroup.isNotEmpty) {
      final normalizedGroup = bingeGroup
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (normalizedGroup.isNotEmpty) {
        return '$provider|binge:$normalizedGroup';
      }
    }

    if (result.isMagnet) {
      final match = RegExp(
        r'xt=urn:btih:([a-z0-9]+)',
        caseSensitive: false,
      ).firstMatch(result.resource);
      final hash = match?.group(1)?.toLowerCase();
      if (hash != null && hash.isNotEmpty) {
        // A season/series pack has one infohash but a different file index for
        // each episode. Ignore the index for a series-wide pin so the same pack
        // stays preferred as the user moves through episodes.
        return seriesWide
            ? '$provider|btih:$hash'
            : '$provider|btih:$hash|idx:${result.torrentFileIndex ?? -1}';
      }
    }

    final fileName = result.fileNameHint?.trim();
    final raw = fileName != null && fileName.isNotEmpty
        ? fileName
        : result.title.split('\n').last.trim();
    final normalized =
        raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    if (normalized.isNotEmpty) return '$provider|title:$normalized';
    return '$provider|resource:${result.resource}';
  }

  bool matchesPinned(
    SourceResult result,
    String? pinnedIdentity, {
    bool seriesWide = false,
  }) {
    if (pinnedIdentity == null || pinnedIdentity.isEmpty) return false;
    return sourceIdentity(result, seriesWide: seriesWide) == pinnedIdentity;
  }

  String _pinPreferenceKey(String targetKey) =>
      '$_pinnedSourcePrefix$targetKey';

  Future<PinnedSourcePreference?> getPinnedSourcePreference(
    String targetKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pinPreferenceKey(targetKey));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final identity = decoded['identity']?.toString().trim() ?? '';
        if (identity.isEmpty) return null;
        final provider = decoded['provider']?.toString().trim();
        final label = decoded['label']?.toString().trim();
        return PinnedSourcePreference(
          identity: identity,
          provider: provider == null || provider.isEmpty
              ? identity.split('|').first
              : provider,
          label: label == null || label.isEmpty ? 'Pinned release' : label,
          bingeGroup: decoded['bingeGroup']?.toString(),
        );
      }
    } catch (_) {
      final identity = raw.trim();
      if (identity.isEmpty) return null;
      return PinnedSourcePreference(
        identity: identity,
        provider: identity.split('|').first,
        label: 'Pinned release',
      );
    }
    return null;
  }

  Future<String?> getPinnedSourceIdentity(String targetKey) async =>
      (await getPinnedSourcePreference(targetKey))?.identity;

  Future<void> pinSource(
    String targetKey,
    SourceResult result, {
    bool seriesWide = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final fileName = result.fileNameHint?.trim();
    final label = fileName != null && fileName.isNotEmpty
        ? fileName
        : result.title.split('\n').last.trim();
    await prefs.setString(
      _pinPreferenceKey(targetKey),
      jsonEncode({
        'identity': sourceIdentity(result, seriesWide: seriesWide),
        'provider': result.provider,
        'label': label,
        if (result.bingeGroup != null) 'bingeGroup': result.bingeGroup,
        'pinnedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> unpinSource(String targetKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinPreferenceKey(targetKey));
  }

  /// The experimental TV source browser used a long-press pin gesture and
  /// series-wide identities. That made accidental pins hard to remove with a
  /// remote. Clear those legacy preferences once when the repaired TV source
  /// browser is first opened. Mobile/desktop pin behavior is otherwise left
  /// untouched.
  Future<void> clearLegacyTvPinsOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_tvLegacyPinsClearedKey) == true) return;

    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(_pinnedSourcePrefix))
        .toList(growable: false);
    for (final key in keys) {
      await prefs.remove(key);
    }
    await prefs.setBool(_tvLegacyPinsClearedKey, true);
  }

  Future<void> setPriorityOrder(List<SourceSortCriterion> order) async {
    final normalized = <SourceSortCriterion>[];
    for (final criterion in order) {
      if (!normalized.contains(criterion)) normalized.add(criterion);
    }
    for (final criterion in defaultPriority) {
      if (!normalized.contains(criterion)) normalized.add(criterion);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _priorityKey,
      normalized.map((e) => e.name).toList(),
    );
  }

  int compareResults(
    SourceResult a,
    SourceResult b,
    List<SourceSortCriterion> priority,
  ) {
    for (final criterion in priority) {
      final av = _criterionValue(a, criterion);
      final bv = _criterionValue(b, criterion);
      final cmp = bv.compareTo(av);
      if (cmp != 0) return cmp;
    }
    return a.title.compareTo(b.title);
  }

  int _criterionValue(SourceResult result, SourceSortCriterion criterion) {
    switch (criterion) {
      case SourceSortCriterion.cache:
        return result.cached ? 1 : 0;
      case SourceSortCriterion.releaseQuality:
        return result.releaseQualityRank + (result.preferredGroup ? 50 : 0);
      case SourceSortCriterion.resolution:
        return result.qualityRank;
      case SourceSortCriterion.seeders:
        return result.seeders ?? -1;
      case SourceSortCriterion.fileSize:
        return result.sizeBytes ?? 0;
    }
  }

  List<SourceResult> sortResults(
    Iterable<SourceResult> results,
    List<SourceSortCriterion> priority,
  ) {
    final out = results.toList();
    out.sort((a, b) => compareResults(a, b, priority));
    return out;
  }

  /// Optional playback-focused ordering for users who care more about a
  /// stream starting and staying smooth than about the normal release-size
  /// preference. Nothing is hidden here; this only changes the order.
  ///
  /// The order deliberately favors common 1080p/720p playback targets,
  /// efficient HEVC/x265 encodes, healthy swarms, then smaller files. Cache is
  /// still useful, but it is not allowed to dominate playback characteristics.
  List<SourceResult> sortForSmoothPlayback(Iterable<SourceResult> results) {
    final out = results.toList();
    out.sort(_compareSmoothPlayback);
    return out;
  }

  int _compareSmoothPlayback(SourceResult a, SourceResult b) {
    final riskCmp = a.compatibilityRisk.compareTo(b.compatibilityRisk);
    if (riskCmp != 0) return riskCmp;

    final resolutionCmp =
        _smoothResolutionRank(b).compareTo(_smoothResolutionRank(a));
    if (resolutionCmp != 0) return resolutionCmp;

    final codecCmp = _smoothCodecRank(b).compareTo(_smoothCodecRank(a));
    if (codecCmp != 0) return codecCmp;

    final seedCmp = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
    if (seedCmp != 0) return seedCmp;

    final aSize = a.sizeBytes;
    final bSize = b.sizeBytes;
    if (aSize != null && bSize != null && aSize != bSize) {
      return aSize.compareTo(bSize);
    }
    if (aSize != null && bSize == null) return -1;
    if (aSize == null && bSize != null) return 1;

    final cacheCmp = (b.cached ? 1 : 0).compareTo(a.cached ? 1 : 0);
    if (cacheCmp != 0) return cacheCmp;

    final releaseCmp = b.releaseQualityRank.compareTo(a.releaseQualityRank);
    if (releaseCmp != 0) return releaseCmp;

    return a.title.compareTo(b.title);
  }

  int _smoothResolutionRank(SourceResult result) {
    switch (result.quality?.toUpperCase()) {
      case '1080P':
        return 600;
      case '720P':
        return 560;
      case '1440P':
        return 520;
      case '2160P':
      case '4K':
        return 480;
      case '480P':
        return 300;
      default:
        return 200;
    }
  }

  int _smoothCodecRank(SourceResult result) {
    final text = '${result.title} ${result.fileNameHint ?? ''}'.toLowerCase();
    if (RegExp(r'\b(?:x265|h[ ._-]?265|hevc)\b').hasMatch(text)) {
      return 300;
    }
    if (RegExp(r'\b(?:x264|h[ ._-]?264|avc)\b').hasMatch(text)) {
      return 250;
    }
    if (RegExp(r'\b(?:av1|av01)\b').hasMatch(text)) {
      return 100;
    }
    return 180;
  }

  /// Free P2P ordering is intentionally playability-first. Resolution and
  /// source-quality labels do not participate in this score: a compatible,
  /// healthy 480p/720p file should outrank a fragile 4K/1080p release.
  List<SourceResult> sortForFreeStreaming(Iterable<SourceResult> results) {
    final out = results.toList();
    out.sort(_compareFreeStreaming);
    return out;
  }

  int _compareFreeStreaming(SourceResult a, SourceResult b) {
    final scoreCmp = _freeStreamingScore(b).compareTo(_freeStreamingScore(a));
    if (scoreCmp != 0) return scoreCmp;

    final seedCmp = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
    if (seedCmp != 0) return seedCmp;

    final aSize = a.sizeBytes;
    final bSize = b.sizeBytes;
    if (aSize != null && bSize != null && aSize != bSize) {
      return aSize.compareTo(bSize);
    }
    if (aSize != null && bSize == null) return -1;
    if (aSize == null && bSize != null) return 1;

    return a.title.compareTo(b.title);
  }

  int _freeStreamingScore(SourceResult result) {
    final history = _historyRank(result);
    final direct = result.isMagnet ? 0 : 1;
    final availability = _freeAvailabilityRank(result.seeders);
    final universal = _universalPlaybackRank(result);
    final exactFile = result.torrentFileIndex != null ||
            result.fileNameHint?.trim().isNotEmpty == true
        ? 1
        : 0;
    final seedHealth = _freeSeederHealthRank(result.seeders);
    final size = _freeSizeEfficiencyRank(result);

    // A recent real failure is stronger evidence than addon labels. Successful
    // history is deliberately NOT boosted: "played here before" does not mean
    // the release is the most portable choice on another Android/TV device.
    final recentFailurePenalty = history <= -2 ? 1500000000 : 0;

    return direct * 2000000000 +
        availability * 400000000 +
        universal * 30000000 +
        exactFile * 120000000 +
        seedHealth * 10000000 +
        // Once a swarm is viable, a practical payload matters to real startup
        // more than chasing another raw-seeder bucket. This lets a healthy
        // compact 720p encode outrank a very heavy 1080p/4K torrent without
        // giving resolution itself any bonus.
        size * 2000000 -
        recentFailurePenalty;
  }

  int _freeAvailabilityRank(int? seeders) {
    // First separate a dead/unavailable swarm from one that can at least
    // connect. Once viable, portability and exact file routing matter more
    // than chasing a larger reported seeder number.
    return (seeders ?? 0) > 0 ? 1 : 0;
  }

  int _universalPlaybackRank(SourceResult result) {
    if (!result.isMagnet) return 10;
    if (!result.compatibilityFriendly) return 0;

    final text = '${result.title} ${result.fileNameHint ?? ''}'.toLowerCase();
    var rank = 6;

    // H.264/AVC + AAC/AC3 are the broadest common Android/TV path. HEVC is
    // also widely supported, but older/cheaper devices are less predictable.
    if (RegExp(r'\b(?:x264|h[ ._-]?264|avc)\b').hasMatch(text)) {
      rank = 10;
    } else if (RegExp(r'\b(?:x265|h[ ._-]?265|hevc)\b').hasMatch(text)) {
      rank = 8;
    }

    if (RegExp(r'\b(?:aac|ac3|eac3|e-ac-3)\b').hasMatch(text)) rank += 1;
    if (RegExp(r'\b(?:truehd|dts[ ._-]?hd|dts:x)\b').hasMatch(text)) {
      rank -= 2;
    }
    if (RegExp(r'\b(?:hdr10\+?|hdr)\b').hasMatch(text)) rank -= 1;

    return rank.clamp(0, 10).toInt();
  }

  int _freeSeederHealthRank(int? seeders) {
    final value = seeders ?? 0;
    if (value >= 200) return 8;
    if (value >= 100) return 7;
    if (value >= 50) return 6;
    if (value >= 25) return 5;
    if (value >= 15) return 4;
    if (value >= 8) return 3;
    if (value >= 3) return 2;
    if (value >= 1) return 1;
    return 0;
  }

  int _freeSizeEfficiencyRank(SourceResult result) {
    final bytes = result.sizeBytes;
    if (bytes == null || bytes <= 0) return 4;
    const mb = 1024 * 1024;
    const gb = 1024 * mb;

    if (bytes >= 350 * mb && bytes <= 1500 * mb) return 10;
    if (bytes > 1500 * mb && bytes <= 2500 * mb) return 8;
    if (bytes >= 200 * mb && bytes < 350 * mb) return 7;
    if (bytes > 2500 * mb && bytes <= 4 * gb) return 6;
    if (bytes >= 120 * mb && bytes < 200 * mb) return 5;
    if (bytes > 4 * gb && bytes <= 6 * gb) return 3;
    if (bytes > 6 * gb && bytes <= 10 * gb) return 1;
    return 0;
  }

  Future<void> addAddonUrl(String raw) async {
    final normalized = _normalizeAddonUrl(raw);
    if (normalized == null) {
      throw const FormatException(
        'Enter a valid http/https Stremio addon URL.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    if (_looksLikeTorrentio(normalized)) {
      await prefs.setString(_torrentioKey, normalized);
      final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
      current.removeWhere(_looksLikeTorrentio);
      await prefs.setStringList(_prefsKey, current);
      return;
    }

    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    if (!current.contains(normalized)) current.add(normalized);
    await prefs.setStringList(_prefsKey, current);
  }

  Future<void> removeAddonUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeAddonUrl(url);
    final integrated = _normalizeAddonUrl(prefs.getString(_torrentioKey) ?? '');
    if (normalized != null && normalized == integrated) {
      await prefs.remove(_torrentioKey);
    }
    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    current.remove(url);
    if (normalized != null) current.remove(normalized);
    await prefs.setStringList(_prefsKey, current);
  }

  String providerName(String url) {
    if (_looksLikeTorrentio(url)) return 'Torrentio';
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    if (host.contains('comet')) return 'Comet';
    if (host.contains('mediafusion')) return 'MediaFusion';
    return host.isNotEmpty ? uri!.host : 'Source provider';
  }

  Future<List<SourceResult>> resolve(
    MediaItem item, {
    EpisodeItem? episode,
    bool includeLowQuality = false,
    bool forceRefresh = false,
  }) async {
    await _ensurePlaybackHistoryLoaded();
    final addons = await getAddonUrls();
    if (addons.isEmpty) return const [];
    final sortMode = await getSortMode();
    final priority = await getPriorityOrder();
    final show3D = await getShow3D();
    final showLowQuality = await getShowLowQuality();
    final preferredGroups = await getPreferredGroups();

    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final mediaId = episode == null
        ? item.id
        : '${item.id}:${episode.season}:${episode.episode}';
    final cacheKey = <String>[
      type,
      mediaId,
      includeLowQuality.toString(),
      show3D.toString(),
      showLowQuality.toString(),
      sortMode.name,
      priority.map((e) => e.name).join(','),
      preferredGroups.join(',').toLowerCase(),
      addons.join('|'),
    ].join('::');

    final cached = _resolveCache[cacheKey];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) <
            const Duration(minutes: 5)) {
      return [...cached.results];
    }

    final running = _resolveInFlight[cacheKey];
    if (!forceRefresh && running != null) return [...await running];

    final future = (() async {
      final groups = await Future.wait(
        addons.map(
          (addon) => _resolveAddon(
            addon,
            type,
            mediaId,
            item,
            episode,
            sortMode,
            show3D,
            preferredGroups,
          ),
        ),
      );

      final out = <SourceResult>[];
      final seen = <String>{};
      for (final group in groups) {
        for (final result in group) {
          final dedupeKey = '${result.provider}\u0000${result.resource}';
          if (seen.add(dedupeKey)) out.add(result);
        }
      }

      var visible = out;
      if (!includeLowQuality && !showLowQuality) {
        final hasHd = out.any(
          (r) =>
              r.qualityRank >= 300 &&
              r.releaseQuality?.toUpperCase() != 'CAM',
        );
        if (hasHd) {
          visible = out.where((r) {
            final release = r.releaseQuality?.toUpperCase();
            return release != 'CAM' &&
                release != 'DVD' &&
                r.qualityRank >= 300;
          }).toList();
        }
      }
      return sortResults(visible, priority);
    })();

    _resolveInFlight[cacheKey] = future;
    try {
      final results = await future;
      _resolveCache[cacheKey] = _SourceResolveCacheEntry(
        createdAt: DateTime.now(),
        results: results,
      );
      return [...results];
    } finally {
      _resolveInFlight.remove(cacheKey);
      if (_resolveCache.length > 30) {
        final entries = _resolveCache.entries.toList()
          ..sort((a, b) => b.value.createdAt.compareTo(a.value.createdAt));
        final keep = entries.take(24).map((entry) => entry.key).toSet();
        _resolveCache.removeWhere((key, value) => !keep.contains(key));
      }
    }
  }

  Future<void> prefetch(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    try {
      await resolve(
        item,
        episode: episode,
        includeLowQuality: true,
      );
    } catch (_) {
      // Prefetching is opportunistic and must never affect navigation.
    }
  }

  SourceResult? bestSource(List<SourceResult> results) {
    if (results.isEmpty) return null;
    final copy = [...results]
      ..sort((a, b) => b.preferenceScore.compareTo(a.preferenceScore));
    return copy.first;
  }

  Future<List<SourceResult>> _resolveAddon(
    String addon,
    String type,
    String mediaId,
    MediaItem item,
    EpisodeItem? episode,
    SourceSortMode sortMode,
    bool show3D,
    List<String> preferredGroups,
  ) async {
    try {
      final uri = Uri.parse(
        '$addon/stream/$type/${Uri.encodeComponent(mediaId)}.json',
      );
      final response = await _client.get(uri, headers: const {
        'Accept': 'application/json'
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];
      final streams = decoded['streams'];
      if (streams is! List) return const [];

      final provider = providerName(addon);
      final out = <SourceResult>[];
      for (final raw in streams.whereType<Map<String, dynamic>>()) {
        final directUrl = raw['url']?.toString();
        final infoHash = raw['infoHash']?.toString().trim();
        final rawTitle = (raw['title'] ?? raw['name'] ?? 'Source').toString();
        final hints = raw['behaviorHints'] is Map<String, dynamic>
            ? raw['behaviorHints'] as Map<String, dynamic>
            : null;
        final fileNameHint = _nonEmpty(hints?['filename']?.toString());
        final rawVideoHash = _nonEmpty(
          hints?['videoHash']?.toString() ?? raw['videoHash']?.toString(),
        );
        final videoHash = rawVideoHash != null &&
                RegExp(r'^[a-fA-F0-9]{16}$').hasMatch(rawVideoHash)
            ? rawVideoHash.toLowerCase()
            : null;
        final bingeGroup = _nonEmpty(
          hints?['bingeGroup']?.toString() ?? hints?['binge_group']?.toString(),
        );
        final torrentFileIndex = _parseInt(
          raw['fileIdx'] ?? raw['file_idx'] ?? raw['mapIdx'],
        );
        final metadataText = <String>[
          raw['name']?.toString() ?? '',
          rawTitle,
          fileNameHint ?? '',
        ].where((value) => value.trim().isNotEmpty).join('\n');

        // Addons occasionally return a different title that happens to share
        // the same name/season/episode numbering (for example One Piece 1999
        // anime vs One Piece 2023 live action). Reject only strong identity
        // contradictions: an explicit show/movie year mismatch or an explicit
        // SxxEyy mismatch. Ambiguous releases without those clues stay visible.
        if (!sourceMatchesRequestedMedia(
          item,
          episode,
          rawTitle,
          fileNameHint,
        )) {
          continue;
        }

        final cached = _guessCached(raw, metadataText);
        if (!show3D && _is3DRelease(metadataText)) continue;
        final preferredGroup = _matchesPreferredGroup(
          metadataText,
          preferredGroups,
        );
        final quality = _guessQuality(metadataText);
        final releaseQuality = _guessReleaseQuality(metadataText);
        final seeders = _guessSeeders(raw, metadataText);
        final sizeBytes = _guessSizeBytes(raw, metadataText);

        String? resource;
        var isMagnet = false;
        if (directUrl != null && directUrl.startsWith(RegExp(r'https?://'))) {
          resource = directUrl;
        } else if (infoHash != null && infoHash.isNotEmpty) {
          final queryParts = <String>[];
          if (raw['sources'] is List) {
            for (final source in raw['sources'] as List) {
              final value = source.toString();
              if (value.startsWith('tracker:')) {
                queryParts.add(
                  'tr=${Uri.encodeComponent(value.substring('tracker:'.length))}',
                );
              }
            }
          }

          // Orvix metadata is carried on the in-memory magnet URL so the
          // PikPak transfer layer can keep track of the exact torrent child.
          // The transfer layer strips these parameters before sending the
          // magnet to PikPak, so PikPak only sees a normal magnet.
          if (torrentFileIndex != null) {
            queryParts.add('x-orvix-file-idx=$torrentFileIndex');
          }
          if (fileNameHint != null) {
            queryParts.add(
              'x-orvix-file-name=${Uri.encodeComponent(fileNameHint)}',
            );
          }
          if (sizeBytes != null && sizeBytes > 0) {
            queryParts.add('x-orvix-video-size=$sizeBytes');
          }
          if (videoHash != null) {
            queryParts.add('x-orvix-video-hash=$videoHash');
          }

          final suffix = queryParts.isEmpty ? '' : '&${queryParts.join('&')}';
          resource = 'magnet:?xt=urn:btih:$infoHash$suffix';
          isMagnet = true;
        }

        if (resource == null) continue;

        // Existing source sheet renders two title lines. Put the useful stats
        // first so they remain visible even when a long release name truncates.
        final statParts = <String>[
          if (cached) '⚡ Cached',
          if (preferredGroup) '⭐ Preferred',
          if (releaseQuality != null) '🎞 $releaseQuality',
          if (quality != null) '📺 $quality',
          '👥 ${seeders?.toString() ?? '—'} seeders',
          '💾 ${_formatSize(sizeBytes) ?? 'size unknown'}',
        ];
        final displayTitle =
            '${statParts.join('  •  ')}\n${_compactTitle(rawTitle)}';

        out.add(
          SourceResult(
            provider: provider,
            title: displayTitle,
            resource: resource,
            isMagnet: isMagnet,
            sortMode: sortMode,
            quality: quality,
            releaseQuality: releaseQuality,
            preferredGroup: preferredGroup,
            cached: cached,
            seeders: seeders,
            sizeBytes: sizeBytes,
            torrentFileIndex: torrentFileIndex,
            fileNameHint: fileNameHint,
            videoHash: videoHash,
            bingeGroup: bingeGroup,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  bool sourceMatchesRequestedMedia(
    MediaItem item,
    EpisodeItem? episode,
    String rawTitle,
    String? fileNameHint,
  ) {
    final candidates = <String>[
      rawTitle,
      if (fileNameHint?.trim().isNotEmpty == true) fileNameHint!,
    ];

    final expectedYear = item.startYear;
    final normalizedTitle = _normalizeIdentityText(item.title);

    for (final candidate in candidates) {
      final normalized = _normalizeIdentityText(candidate);

      if (expectedYear != null && normalizedTitle.isNotEmpty) {
        final titleIndex = normalized.indexOf(normalizedTitle);
        if (titleIndex >= 0) {
          final tail = normalized.substring(
            titleIndex + normalizedTitle.length,
          );
          final nearby = tail.length > 44 ? tail.substring(0, 44) : tail;
          final yearMatch = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(nearby);
          final explicitYear =
              int.tryParse(yearMatch?.group(0) ?? '');
          if (explicitYear != null &&
              (explicitYear - expectedYear).abs() > 1) {
            return false;
          }
        }
      }

      if (episode != null) {
        final explicitEpisode = RegExp(
          r'\bs(\d{1,2})[ ._-]*e(\d{1,3})\b',
          caseSensitive: false,
        ).firstMatch(candidate);
        if (explicitEpisode != null) {
          final season = int.tryParse(explicitEpisode.group(1) ?? '');
          final number = int.tryParse(explicitEpisode.group(2) ?? '');
          if (season != null &&
              number != null &&
              (season != episode.season || number != episode.episode)) {
            return false;
          }
        }

        final xEpisode = RegExp(
          r'\b(\d{1,2})x(\d{1,3})\b',
          caseSensitive: false,
        ).firstMatch(candidate);
        if (xEpisode != null) {
          final season = int.tryParse(xEpisode.group(1) ?? '');
          final number = int.tryParse(xEpisode.group(2) ?? '');
          if (season != null &&
              number != null &&
              (season != episode.season || number != episode.episode)) {
            return false;
          }
        }
      }
    }

    return true;
  }

  String _normalizeIdentityText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _seedRecommendedProviders(SharedPreferences prefs) async {
    // Seed curated zero-config providers once. The Provider pool UI can
    // remove them later; the marker prevents a removed provider being re-added
    // on every launch.
    if (prefs.getBool(_recommendedProvidersSeedKey) == true) return;

    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    for (final raw in _recommendedAddonUrls) {
      final value = _normalizeAddonUrl(raw);
      if (value != null &&
          !_looksLikeTorrentio(value) &&
          !current.contains(value)) {
        current.add(value);
      }
    }
    await prefs.setStringList(_prefsKey, current);
    await prefs.setBool(_recommendedProvidersSeedKey, true);
  }

  Future<void> _migrateTorrentio(SharedPreferences prefs) async {
    if ((prefs.getString(_torrentioKey) ?? '').trim().isNotEmpty) return;
    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    String? found;
    for (final value in current) {
      if (_looksLikeTorrentio(value)) {
        found = _normalizeAddonUrl(value);
        break;
      }
    }
    if (found == null) return;
    await prefs.setString(_torrentioKey, found);
    current.removeWhere(_looksLikeTorrentio);
    await prefs.setStringList(_prefsKey, current);
  }

  bool _looksLikeTorrentio(String value) {
    final host = Uri.tryParse(value)?.host.toLowerCase() ?? value.toLowerCase();
    return host.contains('torrentio');
  }

  String? _normalizeAddonUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.endsWith('/manifest.json')) {
      value = value.substring(0, value.length - '/manifest.json'.length);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  bool _is3DRelease(String value) {
    final lower = value.toLowerCase();
    if (RegExp(
      r'(^|[\s._\-\[\(])(3d|sbs|hsbs|h-sbs|half[ ._-]?sbs|full[ ._-]?sbs|tab|top[ ._-]?and[ ._-]?bottom)(?=$|[\s._\-\]\)])',
    ).hasMatch(lower)) {
      return true;
    }
    // MVC is predominantly used by frame-packed Blu-ray 3D releases. Require
    // a Blu-ray/3D context so an unrelated token cannot hide a normal file.
    return RegExp(r'\bmvc\b').hasMatch(lower) &&
        (lower.contains('bluray') ||
            lower.contains('blu-ray') ||
            lower.contains('3d'));
  }

  bool _matchesPreferredGroup(String value, List<String> groups) {
    if (groups.isEmpty) return false;
    final normalized =
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    for (final group in groups) {
      final token =
          group.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
      if (token.isNotEmpty && (' $normalized ').contains(' $token '))
        return true;
    }
    return false;
  }

  bool _guessCached(Map<String, dynamic> raw, String value) {
    final hints = raw['behaviorHints'];
    final candidates = <dynamic>[
      raw['cached'],
      raw['isCached'],
      raw['is_cached'],
      if (hints is Map<String, dynamic>) hints['cached'],
      if (hints is Map<String, dynamic>) hints['isCached'],
      if (hints is Map<String, dynamic>) hints['is_cached'],
    ];

    for (final candidate in candidates) {
      if (candidate is bool) return candidate;
      final normalized = candidate?.toString().trim().toLowerCase();
      if (normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'cached') {
        return true;
      }
    }

    return RegExp(
      r'(^|[\s|•\[\(])(cached|rd\+|ad\+|tb\+|pm\+)(?=$|[\s|•\]\)])',
      caseSensitive: false,
    ).hasMatch(value);
  }

  String? _guessReleaseQuality(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\bremux\b').hasMatch(lower)) return 'REMUX';
    if (lower.contains('blu-ray') ||
        lower.contains('bluray') ||
        RegExp(r'\b(?:bdremux|bdrip|brrip)\b').hasMatch(lower)) {
      return 'BluRay';
    }
    if (RegExp(r'\bweb[ ._-]?dl\b').hasMatch(lower) ||
        lower.contains('webdl')) {
      return 'WEB-DL';
    }
    if (RegExp(r'\bweb[ ._-]?rip\b').hasMatch(lower) ||
        lower.contains('webrip')) {
      return 'WEBRip';
    }
    if (RegExp(r'\b(?:hdtv|hdrip|ppv|dsr)\b').hasMatch(lower)) return 'HDTV';
    if (RegExp(r'\b(?:dvdrip|dvd-rip|dvd)\b').hasMatch(lower)) return 'DVD';
    if (RegExp(r'\b(?:cam|hdcam|camrip|telesync|telecine)\b').hasMatch(lower))
      return 'CAM';
    return null;
  }

  String? _broadenTorrentioUrl(String value) {
    if (!_looksLikeTorrentio(value)) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final segments = [...uri.pathSegments];
    var changed = false;

    if (segments.isNotEmpty && segments.last.toLowerCase() == 'lite') {
      segments.removeLast();
      changed = true;
    }

    for (var i = 0; i < segments.length; i++) {
      if (!segments[i].contains('=')) continue;
      final parts = segments[i].split('|');
      final filtered = parts.where((part) {
        final key = part.split('=').first.trim().toLowerCase();
        return !const {
          'limit',
          'sizefilter',
          'qualityfilter',
          'sort',
          'priorityforeignlanguage',
        }.contains(key);
      }).toList();
      if (filtered.length != parts.length) {
        changed = true;
        if (filtered.isEmpty) {
          segments.removeAt(i);
          i--;
        } else {
          segments[i] = filtered.join('|');
        }
      }
    }

    if (!changed) return value;
    return uri
        .replace(pathSegments: segments)
        .toString()
        .replaceAll(RegExp(r'/$'), '');
  }

  String? _guessQuality(String value) {
    final lower = value.toLowerCase();
    for (final q in const ['2160p', '4k', '1440p', '1080p', '720p', '480p']) {
      if (lower.contains(q)) return q.toUpperCase();
    }
    return null;
  }

  int? _guessSeeders(Map<String, dynamic> raw, String value) {
    final hints = raw['behaviorHints'];
    final candidates = <dynamic>[
      raw['seeders'],
      raw['seeds'],
      raw['peers'],
      raw['seed'],
      if (hints is Map<String, dynamic>) hints['seeders'],
      if (hints is Map<String, dynamic>) hints['seeds'],
      if (hints is Map<String, dynamic>) hints['peers'],
    ];
    for (final candidate in candidates) {
      final parsed = candidate is num
          ? candidate.toInt()
          : int.tryParse(candidate?.toString().trim() ?? '');
      if (parsed != null && parsed >= 0) return parsed;
    }

    final patterns = <RegExp>[
      RegExp(r'👤\s*(\d[\d,]*)', caseSensitive: false),
      RegExp(r'👥\s*(\d[\d,]*)', caseSensitive: false),
      RegExp(r'\bseeders?\s*[:=]?\s*(\d[\d,]*)\b', caseSensitive: false),
      RegExp(r'\bseeds?\s*[:=]?\s*(\d[\d,]*)\b', caseSensitive: false),
      RegExp(r'\bpeers?\s*[:=]?\s*(\d[\d,]*)\b', caseSensitive: false),
      RegExp(r'\bS\s*[:=]\s*(\d[\d,]*)\b', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      final normalized = match?.group(1)?.replaceAll(',', '');
      final parsed = normalized == null ? null : int.tryParse(normalized);
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _guessSizeBytes(Map<String, dynamic> raw, String title) {
    final hints = raw['behaviorHints'];
    final candidates = <dynamic>[
      if (hints is Map<String, dynamic>) hints['videoSize'],
      if (hints is Map<String, dynamic>) hints['size'],
      if (hints is Map<String, dynamic>) hints['fileSize'],
      raw['videoSize'],
      raw['size'],
      raw['fileSize'],
      raw['filesize'],
    ];
    for (final candidate in candidates) {
      if (candidate is num && candidate > 0) return candidate.toInt();
      final parsed = _parseHumanSize(candidate?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return _parseHumanSize(title);
  }

  int? _parseHumanSize(String value) {
    final matches = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(TiB|TB|GiB|GB|MiB|MB|KiB|KB)\b',
      caseSensitive: false,
    ).allMatches(value).toList();
    if (matches.isEmpty) return null;

    // Addons sometimes include pack size and video size in one title. The
    // largest explicit size is the safest value for source ranking/display.
    int? largest;
    for (final match in matches) {
      final number = double.tryParse(
        (match.group(1) ?? '').replaceAll(',', '.'),
      );
      final unit = (match.group(2) ?? '').toUpperCase();
      if (number == null) continue;
      final multiplier = switch (unit) {
        'TIB' || 'TB' => 1024.0 * 1024 * 1024 * 1024,
        'GIB' || 'GB' => 1024.0 * 1024 * 1024,
        'MIB' || 'MB' => 1024.0 * 1024,
        'KIB' || 'KB' => 1024.0,
        _ => 1.0,
      };
      final bytes = (number * multiplier).round();
      if (largest == null || bytes > largest) largest = bytes;
    }
    return largest;
  }

  String? _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return null;
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(2)} TB';
    if (bytes >= gb)
      return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 1 : 2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  String _compactTitle(String value) {
    return value
        .replaceAll(RegExp(r'[\r\n]+'), '  •  ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  int? _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  String? _nonEmpty(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  void dispose() => _client.close();
}
