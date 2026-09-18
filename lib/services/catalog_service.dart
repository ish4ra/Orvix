import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class CatalogService {
  CatalogService({http.Client? client}) : _client = client ?? http.Client();

  static const _baseUrl = 'https://v3-cinemeta.strem.io';
  static const _imdbGraphqlUrl = 'https://caching.graphql.imdb.com/';
  static const _aioMetadataBaseUrl = 'https://aiometadata.elfhosted.com';
  static const _aioUuidPreference = 'orvix_aiometadata_default_uuid_v1';
  final http.Client _client;
  Future<String?>? _aioUuidFuture;

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

    final imdbSignals = await _imdbSearchSignals(merged);
    final enriched = merged
        .map((item) => _withSearchSignal(item, imdbSignals[item.id]))
        .toList(growable: false);
    final originalOrder = <String, int>{
      for (var i = 0; i < enriched.length; i++)
        (enriched[i].kind.name + ':' + enriched[i].id): i,
    };

    enriched.sort((a, b) {
      final byScore = _searchScore(
        b,
        normalized,
        signal: imdbSignals[b.id],
      ).compareTo(
        _searchScore(
          a,
          normalized,
          signal: imdbSignals[a.id],
        ),
      );
      if (byScore != 0) return byScore;
      final aRank = originalOrder[a.kind.name + ':' + a.id] ?? 9999;
      final bRank = originalOrder[b.kind.name + ':' + b.id] ?? 9999;
      return aRank.compareTo(bRank);
    });

    return enriched.take(limit).toList(growable: false);
  }

  Future<MediaItem?> details(MediaItem item) async {
    MediaItem? aio;
    try {
      aio = await _aioMetadataDetails(item);
    } catch (_) {
      aio = null;
    }

    MediaItem? cinemeta;
    if (aio == null ||
        (item.kind == MediaKind.series && aio.episodes.isEmpty)) {
      cinemeta = await _metaByImdbId(item.id, item.kind);
    }

    final resolved = _mergeMetadata(aio, cinemeta) ?? item;
    var episodes = resolved.episodes;
    if (item.kind == MediaKind.series && episodes.isNotEmpty) {
      episodes = await _enrichEpisodeRatings(item.id, episodes);
    }

    final richDescription = _richDescription(resolved);

    // Keep live IMDb chart data when the title came from an IMDb ranked shelf,
    // while AIOMetadata supplies richer art, cast/director data and episodes.
    return MediaItem(
      id: resolved.id.isNotEmpty ? resolved.id : item.id,
      kind: resolved.kind,
      title: resolved.title.isNotEmpty ? resolved.title : item.title,
      year: item.year ?? resolved.year,
      poster: resolved.poster ?? item.poster,
      background: resolved.background ?? item.background,
      description: richDescription ?? item.description,
      rating: item.rating ?? resolved.rating,
      runtime: resolved.runtime ?? item.runtime,
      genres: resolved.genres.isNotEmpty ? resolved.genres : item.genres,
      episodes: episodes.isNotEmpty ? episodes : item.episodes,
      cast: resolved.cast,
      directors: resolved.directors,
      country: resolved.country,
      certification: resolved.certification,
    );
  }

  Future<MediaItem?> _aioMetadataDetails(MediaItem item) async {
    final uuid = await _ensureAioMetadataUuid();
    if (uuid == null || uuid.isEmpty) return null;

    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final uri = Uri.parse(
      '$_aioMetadataBaseUrl/stremio/$uuid/meta/$type/${item.id}.json',
    );
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return null;

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return null;
    final meta = body['meta'];
    if (meta is! Map<String, dynamic>) return null;
    final parsed = MediaItem.fromCinemeta(meta, kind: item.kind);
    if (parsed.id.isEmpty || parsed.title.isEmpty) return null;
    return parsed;
  }

  Future<String?> _ensureAioMetadataUuid() {
    return _aioUuidFuture ??= _loadOrCreateAioMetadataUuid();
  }

  Future<String?> _loadOrCreateAioMetadataUuid() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(_aioUuidPreference)?.trim();
      if (stored != null && stored.isNotEmpty) return stored;

      final random = Random.secure();
      final password =
          'orvix-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 31)}';
      final payload = <String, dynamic>{
        'config': _defaultAioMetadataConfig(),
        'password': password,
      };

      final response = await _client
          .post(
            Uri.parse('$_aioMetadataBaseUrl/api/config/save'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final uuid = body['userUUID']?.toString().trim();
      if (uuid == null || uuid.isEmpty) return null;
      await preferences.setString(_aioUuidPreference, uuid);
      return uuid;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _defaultAioMetadataConfig() {
    return <String, dynamic>{
      'language': 'en-US',
      'addonName': 'Orvix Metadata',
      'includeAdult': false,
      'blurThumbs': false,
      'showPrefix': false,
      'showMetaProviderAttribution': false,
      'castCount': 10,
      'displayAgeRating': true,
      'showDisabledCatalogs': false,
      'sfw': false,
      'hideUnreleasedDigital': false,
      'hideUnreleasedDigitalSearch': false,
      'hideUnreleasedShows': false,
      'hideUnreleasedShowsSearch': false,
      'hideWatchedTrakt': false,
      'hideWatchedAnilist': false,
      'hideWatchedMdblist': false,
      'hideWatchedSimkl': false,
      'providers': <String, dynamic>{
        'movie': 'tmdb',
        'series': 'tvdb',
        'anime': 'mal',
        'anime_id_provider': 'imdb',
        'forceAnimeForDetectedImdb': false,
      },
      'artProviders': <String, dynamic>{
        'movie': <String, dynamic>{
          'poster': 'meta',
          'background': 'meta',
          'logo': 'meta',
        },
        'series': <String, dynamic>{
          'poster': 'meta',
          'background': 'meta',
          'logo': 'meta',
        },
        'anime': <String, dynamic>{
          'poster': 'meta',
          'background': 'imdb',
          'logo': 'imdb',
        },
        'englishArtOnly': false,
        'originalLangFallback': true,
      },
      'tvdbSeasonType': 'default',
      'mal': <String, dynamic>{
        'skipFiller': false,
        'skipRecap': false,
        'allowEpisodeMarking': false,
        'useImdbIdForCatalogAndSearch': false,
      },
      'tmdb': <String, dynamic>{
        'scrapeImdb': false,
        'forceLatinCastNames': false,
      },
      'apiKeys': <String, dynamic>{
        'gemini': '',
        'tmdb': '',
        'tvdb': '',
        'fanart': '',
        'rpdb': '',
        'topPoster': '',
        'mdblist': '',
        'openrouter': '',
        'publicmetadb': '',
      },
      'posterRatingProvider': 'none',
      'usePosterProxy': true,
      'mdblistWatchTracking': false,
      'anilistWatchTracking': false,
      'malWatchTracking': false,
      'simklWatchTracking': false,
      'traktWatchTracking': false,
      'publicmetadbWatchTracking': false,
      'enableRatingPostersForLibrary': false,
      'showRateMeButton': false,
      'ageRating': 'None',
      'allowUnratedContent': true,
      'searchEnabled': false,
      'catalogSetupComplete': true,
      'catalogs': <dynamic>[],
      'search': <String, dynamic>{
        'enabled': false,
        'ai_enabled': false,
        'providers': <String, dynamic>{},
        'engineEnabled': <String, dynamic>{},
      },
    };
  }

  MediaItem? _mergeMetadata(MediaItem? primary, MediaItem? fallback) {
    if (primary == null) return fallback;
    if (fallback == null) return primary;
    return MediaItem(
      id: primary.id.isNotEmpty ? primary.id : fallback.id,
      kind: primary.kind,
      title: primary.title.isNotEmpty ? primary.title : fallback.title,
      year: primary.year ?? fallback.year,
      poster: primary.poster ?? fallback.poster,
      background: primary.background ?? fallback.background,
      description: primary.description ?? fallback.description,
      rating: primary.rating ?? fallback.rating,
      runtime: primary.runtime ?? fallback.runtime,
      genres: primary.genres.isNotEmpty ? primary.genres : fallback.genres,
      episodes: primary.episodes.isNotEmpty
          ? primary.episodes
          : fallback.episodes,
      cast: primary.cast.isNotEmpty ? primary.cast : fallback.cast,
      directors: primary.directors.isNotEmpty
          ? primary.directors
          : fallback.directors,
      country: primary.country ?? fallback.country,
      certification: primary.certification ?? fallback.certification,
    );
  }

  String? _richDescription(MediaItem item) {
    final facts = <String>[];
    if (item.certification?.trim().isNotEmpty == true) {
      facts.add('Rated ${item.certification!.trim()}');
    }
    if (item.country?.trim().isNotEmpty == true) {
      facts.add(item.country!.trim());
    }
    if (item.directors.isNotEmpty) {
      facts.add('Director: ${item.directors.take(2).join(', ')}');
    }
    if (item.cast.isNotEmpty) {
      facts.add('Cast: ${item.cast.take(4).join(', ')}');
    }

    final description = item.description?.trim();
    if (facts.isEmpty) return description;
    final line = facts.join('  •  ');
    if (description == null || description.isEmpty) return line;
    return '$line\n$description';
  }

  Future<List<EpisodeItem>> _enrichEpisodeRatings(
    String seriesId,
    List<EpisodeItem> episodes,
  ) async {
    if (!RegExp(r'^tt\d{7,10}$').hasMatch(seriesId)) return episodes;
    try {
      final ratings = await _imdbEpisodeRatings(seriesId);
      if (ratings.isEmpty) return episodes;
      return episodes
          .map((episode) {
            if (episode.rating != null) return episode;
            return episode.withRating(
              ratings['${episode.season}:${episode.episode}'],
            );
          })
          .toList(growable: false);
    } catch (_) {
      return episodes;
    }
  }

  Future<Map<String, double>> _imdbEpisodeRatings(String seriesId) async {
    final ratings = <String, double>{};
    String? cursor;

    for (var page = 0; page < 8; page++) {
      final after = cursor == null ? '' : ', after: ${jsonEncode(cursor)}';
      final query =
          '''
{
  title(id: ${jsonEncode(seriesId)}) {
    episodes {
      episodes(first: 250$after) {
        edges {
          node {
            id
            ratingsSummary { aggregateRating voteCount }
            series {
              episodeNumber { seasonNumber episodeNumber }
            }
          }
        }
        pageInfo { endCursor hasNextPage }
      }
    }
  }
}
''';

      final response = await _client
          .post(
            Uri.parse(_imdbGraphqlUrl),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Origin': 'https://www.imdb.com',
              'Referer': 'https://www.imdb.com/',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36',
              'x-imdb-client-name': 'imdb-web-next',
            },
            body: jsonEncode({'query': query}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) break;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) break;
      final data = body['data'];
      if (data is! Map<String, dynamic>) break;
      final title = data['title'];
      if (title is! Map<String, dynamic>) break;
      final episodeRoot = title['episodes'];
      if (episodeRoot is! Map<String, dynamic>) break;
      final connection = episodeRoot['episodes'];
      if (connection is! Map<String, dynamic>) break;
      final edges = connection['edges'];
      if (edges is! List) break;

      for (final edge in edges.whereType<Map<String, dynamic>>()) {
        final node = edge['node'];
        if (node is! Map<String, dynamic>) continue;
        final series = node['series'];
        if (series is! Map<String, dynamic>) continue;
        final number = series['episodeNumber'];
        if (number is! Map<String, dynamic>) continue;
        final season = int.tryParse(number['seasonNumber']?.toString() ?? '');
        final episode = int.tryParse(number['episodeNumber']?.toString() ?? '');
        final ratingSummary = node['ratingsSummary'];
        final rawRating = ratingSummary is Map<String, dynamic>
            ? ratingSummary['aggregateRating']
            : null;
        final rating = rawRating is num
            ? rawRating.toDouble()
            : double.tryParse(rawRating?.toString() ?? '');
        if (season == null || episode == null || rating == null) continue;
        ratings['$season:$episode'] = rating;
      }

      final pageInfo = connection['pageInfo'];
      if (pageInfo is! Map<String, dynamic> || pageInfo['hasNextPage'] != true) {
        break;
      }
      cursor = pageInfo['endCursor']?.toString();
      if (cursor == null || cursor.isEmpty) break;
    }

    return ratings;
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
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128 Safari/537.36',
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
            cast: meta?.cast ?? const [],
            directors: meta?.directors ?? const [],
            country: meta?.country,
            certification: meta?.certification,
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

  int _searchScore(
    MediaItem item,
    String query, {
    _ImdbSearchSignal? signal,
  }) {
    final q = _searchKey(query);
    final title = _searchKey(item.title);
    if (q.isEmpty || title.isEmpty) return 0;

    final queryYearMatch = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(q);
    final queryYear = int.tryParse(queryYearMatch?.group(0) ?? '');
    final titleQuery = queryYearMatch == null
        ? q
        : q.replaceFirst(queryYearMatch.group(0)!, '').trim();

    var score = 0;
    if (title == titleQuery) {
      score += 1000000;
    } else if (title.startsWith(titleQuery + ' ')) {
      score += 320000;
    } else if (title.contains(titleQuery)) {
      score += 140000;
    } else {
      final words = titleQuery
          .split(' ')
          .where((word) => word.isNotEmpty)
          .toList(growable: false);
      if (words.isNotEmpty && words.every(title.contains)) {
        score += 80000;
      }
    }

    final itemYear = item.startYear;
    if (queryYear != null) {
      score += itemYear == queryYear ? 250000 : -50000;
    } else if (itemYear != null && itemYear > DateTime.now().year) {
      score -= 15000;
    }

    final votes = signal?.voteCount ?? 0;
    if (votes > 0) {
      score += (log(votes + 1) * 9000).round();
    }

    final rating = signal?.rating ?? item.rating ?? 0;
    score += (rating * 850).round();
    return score;
  }

  MediaItem _withSearchSignal(MediaItem item, _ImdbSearchSignal? signal) {
    if (signal == null) return item;
    final betterPoster = signal.poster?.trim();
    return MediaItem(
      id: item.id,
      kind: item.kind,
      title: item.title,
      year: item.year,
      poster: betterPoster != null && betterPoster.isNotEmpty
          ? betterPoster
          : item.poster,
      background: item.background,
      description: item.description,
      rating: signal.rating ?? item.rating,
      runtime: item.runtime,
      genres: item.genres,
      episodes: item.episodes,
      cast: item.cast,
      directors: item.directors,
      country: item.country,
      certification: item.certification,
    );
  }

  Future<Map<String, _ImdbSearchSignal>> _imdbSearchSignals(
    List<MediaItem> items,
  ) async {
    final ids = items
        .map((item) => item.id)
        .where((id) => RegExp(r'^tt\d{7,10}
  String _searchKey(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  void dispose() => _client.close();
}

class _ImdbSearchSignal {
  const _ImdbSearchSignal({
    this.rating,
    required this.voteCount,
    this.poster,
  });

  final double? rating;
  final int voteCount;
  final String? poster;
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
).hasMatch(id))
        .toSet()
        .take(40)
        .toList(growable: false);
    if (ids.isEmpty) return const {};

    final query = StringBuffer('query SearchSignals {\n');
    for (var i = 0; i < ids.length; i++) {
      query.writeln(
        '  t' +
            i.toString() +
            ': title(id: ' +
            jsonEncode(ids[i]) +
            ') { ratingsSummary { aggregateRating voteCount } '
                'primaryImage { url } }',
      );
    }
    query.writeln('}');

    try {
      final response = await _client
          .post(
            Uri.parse(_imdbGraphqlUrl),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Origin': 'https://www.imdb.com',
              'Referer': 'https://www.imdb.com/',
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/128 Mobile Safari/537.36',
              'x-imdb-client-name': 'imdb-web-next',
            },
            body: jsonEncode({'query': query.toString()}),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return const {};

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return const {};
      final data = body['data'];
      if (data is! Map<String, dynamic>) return const {};

      final out = <String, _ImdbSearchSignal>{};
      for (var i = 0; i < ids.length; i++) {
        final node = data['t' + i.toString()];
        if (node is! Map<String, dynamic>) continue;
        final ratings = node['ratingsSummary'];
        final rawRating = ratings is Map<String, dynamic>
            ? ratings['aggregateRating']
            : null;
        final rawVotes =
            ratings is Map<String, dynamic> ? ratings['voteCount'] : null;
        final image = node['primaryImage'];
        final poster =
            image is Map<String, dynamic> ? image['url']?.toString() : null;

        final rating = rawRating is num
            ? rawRating.toDouble()
            : double.tryParse(rawRating?.toString() ?? '');
        final votes = rawVotes is num
            ? rawVotes.toInt()
            : int.tryParse(rawVotes?.toString() ?? '') ?? 0;

        out[ids[i]] = _ImdbSearchSignal(
          rating: rating,
          voteCount: votes,
          poster: poster,
        );
      }
      return out;
    } catch (_) {
      return const {};
    }
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
