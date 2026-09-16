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
  });

  final String id;
  final int season;
  final int episode;
  final String title;
  final String? overview;
  final String? thumbnail;
  final String? released;

  String get label => 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  DateTime? get releaseDate {
    final raw = released?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  bool get isUpcoming {
    final date = releaseDate;
    return date != null && date.isAfter(DateTime.now());
  }

  factory EpisodeItem.fromCinemeta(Map<String, dynamic> json) {
    return EpisodeItem(
      id: (json['id'] ?? '').toString(),
      season: int.tryParse((json['season'] ?? '0').toString()) ?? 0,
      episode: int.tryParse((json['episode'] ?? '0').toString()) ?? 0,
      title: (json['title'] ?? json['name'] ?? 'Episode').toString(),
      overview: json['overview']?.toString() ?? json['description']?.toString(),
      thumbnail: json['thumbnail']?.toString(),
      released: json['released']?.toString(),
    );
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

  String get typeLabel => kind == MediaKind.movie ? 'Movie' : 'TV Series';

  int? get startYear {
    final match = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(year ?? '');
    return int.tryParse(match?.group(0) ?? '');
  }

  bool get isUpcoming {
    final value = startYear;
    return value != null && value > DateTime.now().year;
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
    final genres = rawGenres is List
        ? rawGenres.map((e) => e.toString()).where((e) => e.isNotEmpty).toList(growable: false)
        : const <String>[];

    final rawVideos = json['videos'];
    final episodes = rawVideos is List
        ? rawVideos
            .whereType<Map<String, dynamic>>()
            .map(EpisodeItem.fromCinemeta)
            .where((e) => e.season > 0 && e.episode > 0)
            .toList(growable: false)
        : const <EpisodeItem>[];

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
    );
  }
}
