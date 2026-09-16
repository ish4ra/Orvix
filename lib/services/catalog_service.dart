import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';

class CatalogService {
  CatalogService({http.Client? client}) : _client = client ?? http.Client();

  static const _baseUrl = 'https://v3-cinemeta.strem.io';
  final http.Client _client;

  Future<List<MediaItem>> popularMovies({int limit = 40}) {
    return _catalog(MediaKind.movie, 'top', limit: limit);
  }

  Future<List<MediaItem>> popularSeries({int limit = 40}) {
    return _catalog(MediaKind.series, 'top', limit: limit);
  }

  Future<List<MediaItem>> topRatedMovies({int limit = 40}) {
    return _catalog(MediaKind.movie, 'imdbRating', limit: limit);
  }

  Future<List<MediaItem>> topRatedSeries({int limit = 40}) {
    return _catalog(MediaKind.series, 'imdbRating', limit: limit);
  }

  Future<List<MediaItem>> imdbTopMovies({int limit = 40}) {
    return _imdbChart(MediaKind.movie, 'https://www.imdb.com/chart/top/', limit: limit);
  }

  Future<List<MediaItem>> imdbTopSeries({int limit = 40}) {
    return _imdbChart(MediaKind.series, 'https://www.imdb.com/chart/toptv/', limit: limit);
  }

  Future<List<MediaItem>> search(String query, {int limit = 18}) async {
    final normalized = query.trim();
    if (normalized.runes.length < 2) return const [];

    final results = await Future.wait([
      _searchKind(MediaKind.movie, normalized, limit: limit),
      _searchKind(MediaKind.series, normalized, limit: limit),
    ]);

    final merged = <MediaItem>[];
    final seen = <String>{};
    for (final group in results) {
      for (final item in group) {
        final key = '${item.kind.name}:${item.id}';
        if (seen.add(key)) merged.add(item);
      }
    }

    // Cinemeta's native order is relevance-oriented, but it can place a
    // similarly named upcoming remake above the exact title a user typed.
    // Re-rank across movies + series so exact title matches are always first,
    // followed by starts-with/contains matches. Released titles get a small
    // tie-break boost, never enough to beat an exact title query.
    merged.sort((a, b) {
      final byScore = _searchScore(b, normalized).compareTo(
        _searchScore(a, normalized),
      );
      if (byScore != 0) return byScore;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return merged.take(limit).toList(growable: false);
  }

  Future<MediaItem?> details(MediaItem item) async {
    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final uri = Uri.parse('$_baseUrl/meta/$type/${item.id}.json');
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return null;
    final meta = body['meta'];
    if (meta is! Map<String, dynamic>) return null;
    return MediaItem.fromCinemeta(meta, kind: item.kind);
  }

  Future<List<MediaItem>> _imdbChart(
    MediaKind kind,
    String url, {
    required int limit,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(url),
        headers: const {
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'en-US,en;q=0.9',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36',
        },
      ).timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) return const [];

      final ids = <String>[];
      final seen = <String>{};
      final pattern = RegExp(r'/title/(tt\d{7,10})/');
      for (final match in pattern.allMatches(response.body)) {
        final id = match.group(1);
        if (id != null && seen.add(id)) ids.add(id);
      }
      if (ids.isEmpty) return const [];

      final selected = ids.take(limit).toList(growable: false);
      final resolved = await Future.wait(
        selected.map((id) => _metaByImdbId(id, kind)),
      );
      return resolved.whereType<MediaItem>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<MediaItem?> _metaByImdbId(String id, MediaKind kind) async {
    try {
      final type = kind == MediaKind.movie ? 'movie' : 'series';
      final response = await _client
          .get(
            Uri.parse('$_baseUrl/meta/$type/$id.json'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final meta = body['meta'];
      if (meta is! Map<String, dynamic>) return null;
      return MediaItem.fromCinemeta(meta, kind: kind);
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaItem>> _catalog(
    MediaKind kind,
    String catalog, {
    required int limit,
  }) async {
    final type = kind == MediaKind.movie ? 'movie' : 'series';
    final uri = Uri.parse('$_baseUrl/catalog/$type/$catalog.json');
    return _fetchMetas(uri, kind, limit);
  }

  Future<List<MediaItem>> _searchKind(
    MediaKind kind,
    String query, {
    required int limit,
  }) async {
    final type = kind == MediaKind.movie ? 'movie' : 'series';
    final encoded = Uri.encodeComponent(query);
    final uri = Uri.parse(
      '$_baseUrl/catalog/$type/top/search=$encoded.json',
    );
    return _fetchMetas(uri, kind, limit);
  }

  Future<List<MediaItem>> _fetchMetas(
    Uri uri,
    MediaKind kind,
    int limit,
  ) async {
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw CatalogException('Catalog returned HTTP ${response.statusCode}.');
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return const [];
    final metas = body['metas'];
    if (metas is! List) return const [];

    return metas
        .whereType<Map<String, dynamic>>()
        .map((meta) => MediaItem.fromCinemeta(meta, kind: kind))
        .where((item) => item.id.isNotEmpty && item.title.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }

  int _searchScore(MediaItem item, String query) {
    final q = _searchKey(query);
    final title = _searchKey(item.title);
    if (q.isEmpty || title.isEmpty) return 0;

    var score = 0;
    if (title == q) {
      score += 100000;
    } else if (title.startsWith('$q ')) {
      score += 40000;
    } else if (title.contains(q)) {
      score += 20000;
    }

    final yearMatch = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(item.year ?? '');
    final year = int.tryParse(yearMatch?.group(0) ?? '');
    if (year != null) {
      score += year <= DateTime.now().year ? 5000 : -1000;
    }

    score += ((item.rating ?? 0) * 100).round();
    return score;
  }

  String _searchKey(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  void dispose() => _client.close();
}

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}
