import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

enum SourceSortMode { seeders, fileSize, quality }

enum SourceSortCriterion { cache, releaseQuality, resolution, fileSize, seeders }

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
    if ((quality?.toUpperCase() == '4K' || quality?.toUpperCase() == '2160P') && size > 0 && size < 1 * gb) rank -= 230;
    if (quality?.toUpperCase() == '1080P' && size > 0 && size < 350 * 1024 * 1024) rank -= 120;
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
    if (RegExp(r'(^|[\s._\-\[(])(8k|4320p)(?=$|[\s._\-\])])')
        .hasMatch(text)) {
      risk += 100;
    }
    if (RegExp(r'(^|[\s._\-\[(])(av1|av01)(?=$|[\s._\-\])])')
        .hasMatch(text)) {
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
    final sizeMb = ((sizeBytes ?? 0) ~/ (1024 * 1024))
        .clamp(0, 999999)
        .toInt();

    return cacheRank * 1000000000000000000 +
        releaseQualityRank * 1000000000000000 +
        qualityRank * 1000000000000 +
        sizeMb * 1000000 +
        seederRank;
  }
}

class SourceProviderService {
  SourceProviderService({http.Client? client}) : _client = client ?? http.Client();

  static const _prefsKey = 'pikora_source_addons';
  static const _torrentioKey = 'pikora_integrated_torrentio_url_v1';

  // v2 intentionally resets the old default. v0.3.7 makes the default order
  // Quality -> Seeders -> Size while still allowing the user to switch it.
  static const _sortKey = 'pikora_source_sort_mode_v2';
  static const _priorityKey = 'orvix_source_priority_v6';
  static const _show3DKey = 'orvix_show_3d_sources_v1';
  static const _showLowQualityKey = 'orvix_show_low_quality_sources_v1';
  static const _preferredGroupsKey = 'orvix_preferred_release_groups_v1';
  static const _resultLimitKey = 'orvix_source_result_limit_v1';
  static const _pinnedSourcePrefix = 'orvix_pinned_source_v1_';
  static const defaultResultLimit = 0; // 0 = show all
  static const resultLimitOptions = <int>[25, 50, 100, 200, 0];
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
        if (criterion.name == value && !out.contains(criterion)) out.add(criterion);
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
    final normalized = value < 0 ? defaultResultLimit : value.clamp(0, 500).toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_resultLimitKey, normalized);
  }

  String sourceTargetKey(MediaItem item, {EpisodeItem? episode}) {
    final base = '${item.kind.name}:${item.id}';
    if (episode == null) return base;
    return '$base:${episode.season}:${episode.episode}';
  }

  String sourceIdentity(SourceResult result) {
    final provider = result.provider.trim().toLowerCase();
    if (result.isMagnet) {
      final match = RegExp(
        r'xt=urn:btih:([a-z0-9]+)',
        caseSensitive: false,
      ).firstMatch(result.resource);
      final hash = match?.group(1)?.toLowerCase();
      if (hash != null && hash.isNotEmpty) {
        return '$provider|btih:$hash|idx:${result.torrentFileIndex ?? -1}';
      }
    }

    final fileName = result.fileNameHint?.trim();
    final raw = fileName != null && fileName.isNotEmpty
        ? fileName
        : result.title.split('\n').last.trim();
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (normalized.isNotEmpty) return '$provider|title:$normalized';
    return '$provider|resource:${result.resource}';
  }

  bool matchesPinned(SourceResult result, String? pinnedIdentity) {
    if (pinnedIdentity == null || pinnedIdentity.isEmpty) return false;
    return sourceIdentity(result) == pinnedIdentity;
  }

  String _pinPreferenceKey(String targetKey) => '$_pinnedSourcePrefix$targetKey';

  Future<String?> getPinnedSourceIdentity(String targetKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pinPreferenceKey(targetKey));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final identity = decoded['identity']?.toString().trim();
        return identity == null || identity.isEmpty ? null : identity;
      }
    } catch (_) {
      // A future migration can still accept a legacy plain identity value.
      return raw.trim();
    }
    return null;
  }

  Future<void> pinSource(String targetKey, SourceResult result) async {
    final prefs = await SharedPreferences.getInstance();
    final label = result.title.split('\n').last.trim();
    await prefs.setString(
      _pinPreferenceKey(targetKey),
      jsonEncode({
        'identity': sourceIdentity(result),
        'provider': result.provider,
        'label': label,
        'pinnedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> unpinSource(String targetKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinPreferenceKey(targetKey));
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
    await prefs.setStringList(_priorityKey, normalized.map((e) => e.name).toList());
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

  Future<void> addAddonUrl(String raw) async {
    final normalized = _normalizeAddonUrl(raw);
    if (normalized == null) {
      throw const FormatException('Enter a valid http/https Stremio addon URL.');
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
  }) async {
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

    final groups = await Future.wait(
      addons.map((addon) => _resolveAddon(
            addon, type, mediaId, sortMode, show3D, preferredGroups)),
    );

    final out = <SourceResult>[];
    final seen = <String>{};
    for (final group in groups) {
      for (final result in group) {
        // Keep the same source returned by different providers visible: their
        // reported seed counts/metadata may differ. Only remove exact duplicate
        // rows from the same provider.
        final dedupeKey = '${result.provider}\u0000${result.resource}';
        if (seen.add(dedupeKey)) out.add(result);
      }
    }
    // Apply the quality floor BEFORE cache ranking. Cache is the first
    // ranking criterion only among sources that survive the normal quality
    // filter, so cached CAM/DVD/sub-720p rows cannot jump ahead of good HD
    // sources merely because they are cached.
    var visible = out;
    if (!showLowQuality) {
      final hasHd = out.any((r) => r.qualityRank >= 300 && r.releaseQuality?.toUpperCase() != 'CAM');
      if (hasHd) {
        visible = out.where((r) {
          final release = r.releaseQuality?.toUpperCase();
          return release != 'CAM' && release != 'DVD' && r.qualityRank >= 300;
        }).toList();
      }
    }
    return sortResults(visible, priority);
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
    SourceSortMode sortMode,
    bool show3D,
    List<String> preferredGroups,
  ) async {
    try {
      final uri = Uri.parse(
        '$addon/stream/$type/${Uri.encodeComponent(mediaId)}.json',
      );
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
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
        final torrentFileIndex = _parseInt(
          raw['fileIdx'] ?? raw['file_idx'] ?? raw['mapIdx'],
        );
        final metadataText = <String>[
          raw['name']?.toString() ?? '',
          rawTitle,
          fileNameHint ?? '',
        ].where((value) => value.trim().isNotEmpty).join('\n');
        final cached = _guessCached(raw, metadataText);
        if (!show3D && _is3DRelease(metadataText)) continue;
        final preferredGroup = _matchesPreferredGroup(metadataText, preferredGroups);
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
        final displayTitle = '${statParts.join('  •  ')}\n${_compactTitle(rawTitle)}';

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
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
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
    if (RegExp(r'(^|[\s._\-\[\(])(3d|sbs|hsbs|h-sbs|half[ ._-]?sbs|full[ ._-]?sbs|tab|top[ ._-]?and[ ._-]?bottom)(?=$|[\s._\-\]\)])')
        .hasMatch(lower)) {
      return true;
    }
    // MVC is predominantly used by frame-packed Blu-ray 3D releases. Require
    // a Blu-ray/3D context so an unrelated token cannot hide a normal file.
    return RegExp(r'\bmvc\b').hasMatch(lower) &&
        (lower.contains('bluray') || lower.contains('blu-ray') || lower.contains('3d'));
  }

  bool _matchesPreferredGroup(String value, List<String> groups) {
    if (groups.isEmpty) return false;
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    for (final group in groups) {
      final token = group
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (token.isNotEmpty && (' $normalized ').contains(' $token ')) return true;
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
    if (lower.contains('blu-ray') || lower.contains('bluray') ||
        RegExp(r'\b(?:bdremux|bdrip|brrip)\b').hasMatch(lower)) {
      return 'BluRay';
    }
    if (RegExp(r'\bweb[ ._-]?dl\b').hasMatch(lower) || lower.contains('webdl')) {
      return 'WEB-DL';
    }
    if (RegExp(r'\bweb[ ._-]?rip\b').hasMatch(lower) || lower.contains('webrip')) {
      return 'WEBRip';
    }
    if (RegExp(r'\b(?:hdtv|hdrip|ppv|dsr)\b').hasMatch(lower)) return 'HDTV';
    if (RegExp(r'\b(?:dvdrip|dvd-rip|dvd)\b').hasMatch(lower)) return 'DVD';
    if (RegExp(r'\b(?:cam|hdcam|camrip|telesync|telecine)\b').hasMatch(lower)) return 'CAM';
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
        return !const {'limit', 'sizefilter', 'qualityfilter', 'sort', 'priorityforeignlanguage'}.contains(key);
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
    return uri.replace(pathSegments: segments).toString().replaceAll(RegExp(r'/$'), '');
  }

  String? _guessQuality(String value) {
    final lower = value.toLowerCase();
    for (final q in const [
      '2160p',
      '4k',
      '1440p',
      '1080p',
      '720p',
      '480p',
    ]) {
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
      final number = double.tryParse((match.group(1) ?? '').replaceAll(',', '.'));
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
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 1 : 2)} GB';
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
