import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

enum SourceSortMode { seeders, fileSize, quality }

extension SourceSortModeLabel on SourceSortMode {
  String get label {
    switch (this) {
      case SourceSortMode.seeders:
        return 'Seeders';
      case SourceSortMode.fileSize:
        return 'File size';
      case SourceSortMode.quality:
        return 'Quality';
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
    this.seeders,
    this.sizeBytes,
  });

  final String provider;
  final String title;
  final String resource;
  final bool isMagnet;
  final SourceSortMode sortMode;
  final String? quality;
  final int? seeders;
  final int? sizeBytes;

  int get qualityRank {
    switch (quality?.toUpperCase()) {
      case '2160P':
      case '4K':
        return 600;
      case '1440P':
        return 500;
      case '1080P':
        return 400;
      case '720P':
        return 300;
      case '480P':
        return 200;
      default:
        return 100;
    }
  }

  String? get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(bytes >= 10 * tb ? 1 : 2)} TB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 1 : 2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  int get preferenceScore {
    final availability = seeders ?? -1;
    final sizeMb = (sizeBytes ?? 0) ~/ (1024 * 1024);

    // A known dead torrent should never beat a live result just because its
    // release name says 4K/Remux.
    if (isMagnet && seeders == 0) return -1000000000 + qualityRank;

    switch (sortMode) {
      case SourceSortMode.seeders:
        return (availability >= 0 ? availability * 100000 : 0) +
            qualityRank * 100 +
            sizeMb.clamp(0, 50000).toInt();
      case SourceSortMode.fileSize:
        return sizeMb * 1000 +
            qualityRank * 100 +
            (availability >= 0 ? availability.clamp(0, 999).toInt() : 0);
      case SourceSortMode.quality:
        return qualityRank * 1000000 +
            (availability >= 0 ? availability.clamp(0, 9999).toInt() * 10 : 0) +
            sizeMb.clamp(0, 9).toInt();
    }
  }
}

class SourceProviderService {
  SourceProviderService({http.Client? client}) : _client = client ?? http.Client();

  static const _prefsKey = 'pikora_source_addons';
  static const _torrentioKey = 'pikora_integrated_torrentio_url_v1';
  static const _sortKey = 'pikora_source_sort_mode_v1';

  // A distributor may inject an authorized/self-hosted Stremio-compatible
  // Torrentio endpoint at build time without putting a public index URL in
  // source control. Existing users are migrated automatically from the old
  // manual provider list, so they do not have to add it again after updating.
  static const _bundledTorrentioProvider = String.fromEnvironment(
    'PIKORA_TORRENTIO_URL',
    defaultValue: '',
  );

  final http.Client _client;

  Future<List<String>> getAddonUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateTorrentio(prefs);

    final out = <String>[];
    final torrentio = _normalizeAddonUrl(
      prefs.getString(_torrentioKey) ?? _bundledTorrentioProvider,
    );
    if (torrentio != null) out.add(torrentio);

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
      orElse: () => SourceSortMode.seeders,
    );
  }

  Future<void> setSortMode(SourceSortMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortKey, mode.name);
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
    return uri?.host.isNotEmpty == true ? uri!.host : 'Source provider';
  }

  Future<List<SourceResult>> resolve(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    final addons = await getAddonUrls();
    if (addons.isEmpty) return const [];
    final sortMode = await getSortMode();

    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final mediaId = episode == null
        ? item.id
        : '${item.id}:${episode.season}:${episode.episode}';

    final groups = await Future.wait(
      addons.map((addon) => _resolveAddon(addon, type, mediaId, sortMode)),
    );

    final out = <SourceResult>[];
    final seen = <String>{};
    for (final group in groups) {
      for (final result in group) {
        if (seen.add(result.resource)) out.add(result);
      }
    }
    out.sort((a, b) => b.preferenceScore.compareTo(a.preferenceScore));
    return out;
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
  ) async {
    try {
      final uri = Uri.parse(
        '$addon/stream/$type/${Uri.encodeComponent(mediaId)}.json',
      );
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
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
        final title = (raw['title'] ?? raw['name'] ?? 'Source').toString();

        String? resource;
        var isMagnet = false;
        if (directUrl != null && directUrl.startsWith(RegExp(r'https?://'))) {
          resource = directUrl;
        } else if (infoHash != null && infoHash.isNotEmpty) {
          final trackers = raw['sources'] is List
              ? (raw['sources'] as List)
                  .map((e) => e.toString())
                  .where((e) => e.startsWith('tracker:'))
                  .map(
                    (e) =>
                        '&tr=${Uri.encodeComponent(e.substring('tracker:'.length))}',
                  )
                  .join()
              : '';
          resource = 'magnet:?xt=urn:btih:$infoHash$trackers';
          isMagnet = true;
        }

        if (resource == null) continue;
        out.add(
          SourceResult(
            provider: provider,
            title: title,
            resource: resource,
            isMagnet: isMagnet,
            sortMode: sortMode,
            quality: _guessQuality(title),
            seeders: _guessSeeders(raw, title),
            sizeBytes: _guessSizeBytes(raw, title),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
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
    for (final candidate in [
      raw['seeders'],
      raw['seeds'],
      raw['peers'],
      if (raw['behaviorHints'] is Map<String, dynamic>)
        (raw['behaviorHints'] as Map<String, dynamic>)['seeders'],
    ]) {
      final parsed = candidate is num
          ? candidate.toInt()
          : int.tryParse(candidate?.toString() ?? '');
      if (parsed != null) return parsed;
    }

    final patterns = <RegExp>[
      RegExp(r'👤\s*(\d+)', caseSensitive: false),
      RegExp(r'\bseeders?\s*[:=]?\s*(\d+)\b', caseSensitive: false),
      RegExp(r'\bseeds?\s*[:=]?\s*(\d+)\b', caseSensitive: false),
      RegExp(r'\bpeers?\s*[:=]?\s*(\d+)\b', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      final parsed = match == null ? null : int.tryParse(match.group(1) ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _guessSizeBytes(Map<String, dynamic> raw, String title) {
    final hints = raw['behaviorHints'];
    final candidates = <dynamic>[
      if (hints is Map<String, dynamic>) hints['videoSize'],
      raw['videoSize'],
      raw['size'],
    ];
    for (final candidate in candidates) {
      if (candidate is num && candidate > 0) return candidate.toInt();
      final parsed = _parseHumanSize(candidate?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return _parseHumanSize(title);
  }

  int? _parseHumanSize(String value) {
    final match = RegExp(
      r'(\d+(?:\.\d+)?)\s*(TiB|TB|GiB|GB|MiB|MB|KiB|KB)\b',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;
    final number = double.tryParse(match.group(1) ?? '');
    final unit = (match.group(2) ?? '').toUpperCase();
    if (number == null) return null;
    final multiplier = switch (unit) {
      'TIB' || 'TB' => 1024.0 * 1024 * 1024 * 1024,
      'GIB' || 'GB' => 1024.0 * 1024 * 1024,
      'MIB' || 'MB' => 1024.0 * 1024,
      'KIB' || 'KB' => 1024.0,
      _ => 1.0,
    };
    return (number * multiplier).round();
  }

  void dispose() => _client.close();
}
