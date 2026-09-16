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

  void dispose() => _client.close();
}

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}
