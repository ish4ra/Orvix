enum MediaKind { movie, series }

class EpisodeItem {
  const EpisodeItem({
    required this.id,
    required this.season,
    required this.episode,
    required this.title,
    this.overview,
    this.thumbnail,
    this.released,
    this.rating,
  });

  final String id;
  final int season;
  final int episode;
  final String title;
  final String? overview;
  final String? thumbnail;
  final String? released;
  final double? rating;

  String get label =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  DateTime? get releaseDate {
    final raw = released?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  bool get isUpcoming {
    final date = releaseDate;
    return date != null && date.isAfter(DateTime.now());
  }

  EpisodeItem withRating(double? value) {
    if (value == null) return this;
    final cleanOverview = _stripRatingPrefix(overview);
    final decorated = cleanOverview == null || cleanOverview.isEmpty
        ? '★ ${value.toStringAsFixed(1)}'
        : '★ ${value.toStringAsFixed(1)}  $cleanOverview';
    return EpisodeItem(
      id: id,
      season: season,
      episode: episode,
      title: title,
      overview: decorated,
      thumbnail: thumbnail,
      released: released,
      rating: value,
    );
  }

  factory EpisodeItem.fromCinemeta(Map<String, dynamic> json) {
    final rawOverview =
        json['overview']?.toString() ?? json['description']?.toString();
    final rating = _readRating(
      json['imdbRating'] ?? json['rating'] ?? json['vote_average'],
    );
    final overview = rating == null
        ? rawOverview
        : (rawOverview == null || rawOverview.isEmpty
            ? '★ ${rating.toStringAsFixed(1)}'
            : '★ ${rating.toStringAsFixed(1)}  $rawOverview');

    return EpisodeItem(
      id: (json['id'] ?? '').toString(),
      season: int.tryParse((json['season'] ?? '0').toString()) ?? 0,
      episode: int.tryParse((json['episode'] ?? '0').toString()) ?? 0,
      title: (json['title'] ?? json['name'] ?? 'Episode').toString(),
      overview: overview,
      thumbnail: json['thumbnail']?.toString(),
      released: json['released']?.toString(),
      rating: rating,
    );
  }

  static double? _readRating(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _stripRatingPrefix(String? value) {
    if (value == null) return null;
    return value.replaceFirst(RegExp(r'^★\s*\d+(?:\.\d+)?\s*'), '').trim();
  }
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.title,
    this.year,
    this.poster,
    this.background,
    this.description,
    this.rating,
    this.runtime,
    this.genres = const [],
    this.episodes = const [],
    this.cast = const [],
    this.directors = const [],
    this.country,
    this.certification,
  });

  final String id;
  final MediaKind kind;
  final String title;
  final String? year;
  final String? poster;
  final String? background;
  final String? description;
  final double? rating;
  final String? runtime;
  final List<String> genres;
  final List<EpisodeItem> episodes;
  final List<String> cast;
  final List<String> directors;
  final String? country;
  final String? certification;

  int? get startYear {
    final match = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(year ?? '');
    return int.tryParse(match?.group(0) ?? '');
  }

  bool get isUpcoming {
    final value = startYear;
    return value != null && value > DateTime.now().year;
  }

  String get typeLabel {
    if (isUpcoming) {
      return kind == MediaKind.movie ? 'Upcoming Movie' : 'Upcoming TV Series';
    }
    return kind == MediaKind.movie ? 'Movie' : 'TV Series';
  }

  factory MediaItem.fromCinemeta(
    Map<String, dynamic> json, {
    required MediaKind kind,
  }) {
    final rawRating = json['imdbRating'];
    double? rating;
    if (rawRating is num) {
      rating = rawRating.toDouble();
    } else if (rawRating is String) {
      rating = double.tryParse(rawRating);
    }

    final rawGenres = json['genres'];
    final legacyGenres = rawGenres is List
        ? rawGenres
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final linkedGenres = _linkNames(json['links'], const {'genre'});
    final genres = legacyGenres.isNotEmpty ? legacyGenres : linkedGenres;

    final rawVideos = json['videos'];
    final episodes = rawVideos is List
        ? rawVideos
            .whereType<Map<String, dynamic>>()
            .map(EpisodeItem.fromCinemeta)
            .where((e) => e.season > 0 && e.episode > 0)
            .toList(growable: false)
        : const <EpisodeItem>[];

    final legacyCast = _stringList(json['cast']);
    final linkedCast = _linkNames(json['links'], const {'actor', 'cast'});
    final cast = legacyCast.isNotEmpty ? legacyCast : linkedCast;

    final legacyDirectors = _stringList(json['director'] ?? json['directors']);
    final linkedDirectors = _linkNames(json['links'], const {'director'});
    final directors =
        legacyDirectors.isNotEmpty ? legacyDirectors : linkedDirectors;

    return MediaItem(
      id: (json['id'] ?? '').toString(),
      kind: kind,
      title: (json['name'] ?? json['title'] ?? 'Untitled').toString(),
      year: (json['year'] ?? json['releaseInfo'])?.toString(),
      poster: json['poster']?.toString(),
      background: json['background']?.toString(),
      description: json['description']?.toString(),
      rating: rating,
      runtime: json['runtime']?.toString(),
      genres: genres,
      episodes: episodes,
      cast: cast,
      directors: directors,
      country: _stringValue(json['country']),
      certification: _stringValue(
        json['certification'] ?? json['ageRating'] ?? json['rated'],
      ),
    );
  }

  static List<String> _linkNames(dynamic value, Set<String> categories) {
    if (value is! List) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final entry in value) {
      if (entry is! Map) continue;
      final category = entry['category']?.toString().trim().toLowerCase() ?? '';
      if (!categories.contains(category)) continue;
      final name = entry['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (seen.add(key)) out.add(name);
    }
    return out;
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return const [];
    return text
        .split(RegExp(r'\s*,\s*'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static String? _stringValue(dynamic value) {
    if (value is List) {
      final items = value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      return items.isEmpty ? null : items.join(', ');
    }
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
