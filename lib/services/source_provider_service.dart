import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class SourceResult {
  const SourceResult({
    required this.provider,
    required this.title,
    required this.resource,
    required this.isMagnet,
    this.quality,
  });

  final String provider;
  final String title;
  final String resource;
  final bool isMagnet;
  final String? quality;

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

  int get preferenceScore {
    final lower = title.toLowerCase();
    var score = qualityRank;
    if (lower.contains('web-dl') || lower.contains('webdl')) score += 35;
    if (lower.contains('bluray') || lower.contains('blu-ray')) score += 30;
    if (lower.contains('hevc') || lower.contains('x265') || lower.contains('h265')) score += 12;
    if (lower.contains('hdr')) score += 8;
    if (lower.contains('cam') || lower.contains('telesync') || lower.contains('ts ')) score -= 180;
    if (!isMagnet) score += 4;
    return score;
  }
}

class SourceProviderService {
  SourceProviderService({http.Client? client}) : _client = client ?? http.Client();

  static const _prefsKey = 'pikora_source_addons';
  final http.Client _client;

  Future<List<String>> getAddonUrls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefsKey) ?? const [];
  }

  Future<void> addAddonUrl(String raw) async {
    final normalized = _normalizeAddonUrl(raw);
    if (normalized == null) {
      throw const FormatException('Enter a valid http/https Stremio addon URL.');
    }
    final prefs = await SharedPreferences.getInstance();
    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    if (!current.contains(normalized)) current.add(normalized);
    await prefs.setStringList(_prefsKey, current);
  }

  Future<void> removeAddonUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final current = [...(prefs.getStringList(_prefsKey) ?? const <String>[])];
    current.remove(url);
    await prefs.setStringList(_prefsKey, current);
  }

  Future<List<SourceResult>> resolve(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    final addons = await getAddonUrls();
    if (addons.isEmpty) return const [];

    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final mediaId = episode == null
        ? item.id
        : '${item.id}:${episode.season}:${episode.episode}';

    final groups = await Future.wait(
      addons.map((addon) => _resolveAddon(addon, type, mediaId)),
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
    final copy = [...results]..sort((a, b) => b.preferenceScore.compareTo(a.preferenceScore));
    return copy.first;
  }

  Future<List<SourceResult>> _resolveAddon(
    String addon,
    String type,
    String mediaId,
  ) async {
    try {
      final uri = Uri.parse('$addon/stream/$type/${Uri.encodeComponent(mediaId)}.json');
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];
      final streams = decoded['streams'];
      if (streams is! List) return const [];

      final providerName = Uri.parse(addon).host;
      final out = <SourceResult>[];
      for (final raw in streams.whereType<Map<String, dynamic>>()) {
        final directUrl = raw['url']?.toString();
        final infoHash = raw['infoHash']?.toString();
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
                  .map((e) => '&tr=${Uri.encodeComponent(e.substring(8))}')
                  .join()
              : '';
          resource = 'magnet:?xt=urn:btih:$infoHash$trackers';
          isMagnet = true;
        }

        if (resource == null) continue;
        out.add(SourceResult(
          provider: providerName,
          title: title,
          resource: resource,
          isMagnet: isMagnet,
          quality: _guessQuality(title),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  String? _normalizeAddonUrl(String raw) {
    var value = raw.trim();
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
    for (final q in const ['2160p', '4k', '1440p', '1080p', '720p', '480p']) {
      if (lower.contains(q)) return q.toUpperCase();
    }
    return null;
  }

  void dispose() => _client.close();
}
