import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';

class CatalogService {
  CatalogService({http.Client? client}) : _client = client ?? http.Client();

  static const _baseUrl = 'https://v3-cinemeta.strem.io';
  static const _imdbGraphqlUrl = 'https://caching.graphql.imdb.com/';
  final http.Client _client;

  Future<List<MediaItem>> popularMovies({int limit = 40}) {
    return _catalog(MediaKind.movie, 'top', limit: limit);
  }

  Future<List<MediaItem>> popularSeries({int limit = 40}) {
    return _catalog(MediaKind.series, 'top', limit: limit);
  }

  Future<List<MediaItem>> topRatedMovies({int limit = 40}) {
    return _imdbTop(MediaKind.movie, limit: limit);
  }

  Future<List<MediaItem>> topRatedSeries({int limit = 40}) {
    return _imdbTop(MediaKind.series, limit: limit);
  }

  Future<List<MediaItem>> imdbTopMovies({int limit = 40}) {
    return _imdbTop(MediaKind.movie, limit: limit);
  }

  Future<List<MediaItem>> imdbTopSeries({int limit = 40}) {
    return _imdbTop(MediaKind.series, limit: limit);
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

    merged.sort((a, b) {
      final byScore = _searchScore(
        b,
        normalized,
      ).compareTo(_searchScore(a, normalized));
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

    if (response.statusCode != 200) return item;
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return item;
    final meta = body['meta'];
    if (meta is! Map<String, dynamic>) return item;
    final resolved = MediaItem.fromCinemeta(meta, kind: item.kind);

    // When a title came from IMDb's live chart, keep the live IMDb rating and
    // poster/year fields while still enriching it with Cinemeta descriptions,
    // backgrounds, genres and episodes.
    return MediaItem(
      id: resolved.id,
      kind: resolved.kind,
      title: resolved.title,
      year: item.year ?? resolved.year,
      poster: item.poster ?? resolved.poster,
      background: resolved.background ?? item.background,
      description: resolved.description ?? item.description,
      rating: item.rating ?? resolved.rating,
      runtime: resolved.runtime ?? item.runtime,
      genres: resolved.genres.isNotEmpty ? resolved.genres : item.genres,
      episodes: resolved.episodes.isNotEmpty
          ? resolved.episodes
          : item.episodes,
    );
  }

  Future<List<MediaItem>> _imdbTop(MediaKind kind, {required int limit}) async {
    final first = limit.clamp(1, 250).toInt();
    final chartType = kind == MediaKind.movie
        ? 'TOP_RATED_MOVIES'
        : 'TOP_RATED_TV_SHOWS';

    final query =
        '''
{
  chartTitles(chart: {chartType: $chartType}, first: $first) {
    edges {
      node {
        id
        titleText { text }
        primaryImage { url }
        releaseYear { year }
        ratingsSummary {
          aggregateRating
          voteCount
        }
        runtime { seconds }
      }
    }
  }
}
''';

    try {
      final response = await _client
          .post(
            Uri.parse(_imdbGraphqlUrl),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Origin': 'https://www.imdb.com',
              'Referer': 'https://www.imdb.com/',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36',
              'x-imdb-client-name': 'imdb-web-next',
            },
            body: jsonEncode({'query': query}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }
      final data = body['data'];
      if (data is! Map<String, dynamic>) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }
      final chart = data['chartTitles'];
      if (chart is! Map<String, dynamic>) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }
      final edges = chart['edges'];
      if (edges is! List || edges.isEmpty) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }

      final chartRows = <_ImdbChartRow>[];
      for (final edge in edges.whereType<Map<String, dynamic>>()) {
        final node = edge['node'];
        if (node is! Map<String, dynamic>) continue;
        final id = node['id']?.toString() ?? '';
        if (!RegExp(r'^tt\d{7,10}$').hasMatch(id)) continue;

        final titleText = node['titleText'];
        final title = titleText is Map<String, dynamic>
            ? titleText['text']?.toString()
            : null;
        final image = node['primaryImage'];
        final poster = image is Map<String, dynamic>
            ? image['url']?.toString()
            : null;
        final releaseYear = node['releaseYear'];
        final yearValue = releaseYear is Map<String, dynamic>
            ? releaseYear['year']
            : null;
        final year = yearValue == null ? null : yearValue.toString();
        final ratings = node['ratingsSummary'];
        final rawRating = ratings is Map<String, dynamic>
            ? ratings['aggregateRating']
            : null;
        final rating = rawRating is num
            ? rawRating.toDouble()
            : double.tryParse(rawRating?.toString() ?? '');
        final runtime = node['runtime'];
        final rawSeconds = runtime is Map<String, dynamic>
            ? runtime['seconds']
            : null;
        final seconds = rawSeconds is num
            ? rawSeconds.toInt()
            : int.tryParse(rawSeconds?.toString() ?? '');

        chartRows.add(
          _ImdbChartRow(
            id: id,
            title: title,
            year: year,
            poster: poster,
            rating: rating,
            runtime: _runtimeLabel(seconds),
          ),
        );
      }

      if (chartRows.isEmpty) {
        return _catalog(kind, 'imdbRating', limit: limit);
      }

      final metadata = await Future.wait(
        chartRows.map((row) => _metaByImdbId(row.id, kind)),
      );

      final out = <MediaItem>[];
      for (var i = 0; i < chartRows.length; i++) {
        final row = chartRows[i];
        final meta = metadata[i];
        out.add(
          MediaItem(
            id: row.id,
            kind: kind,
            title: row.title ?? meta?.title ?? row.id,
            year: row.year ?? meta?.year,
            poster: row.poster ?? meta?.poster,
            background: meta?.background ?? row.poster,
            description: meta?.description,
            rating: row.rating ?? meta?.rating,
            runtime: meta?.runtime ?? row.runtime,
            genres: meta?.genres ?? const [],
            episodes: meta?.episodes ?? const [],
          ),
        );
      }
      return out.take(limit).toList(growable: false);
    } catch (_) {
      try {
        return await _catalog(kind, 'imdbRating', limit: limit);
      } catch (_) {
        return const [];
      }
    }
  }

  static String? _runtimeLabel(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    final minutes = (seconds / 60).round();
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    if (hours == 0) return '${minutes}m';
    if (remainder == 0) return '${hours}h';
    return '${hours}h ${remainder}m';
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
    final uri = Uri.parse('$_baseUrl/catalog/$type/top/search=$encoded.json');
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

class _ImdbChartRow {
  const _ImdbChartRow({
    required this.id,
    this.title,
    this.year,
    this.poster,
    this.rating,
    this.runtime,
  });

  final String id;
  final String? title;
  final String? year;
  final String? poster;
  final double? rating;
  final String? runtime;
}

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}
