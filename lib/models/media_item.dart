enum MediaKind { movie, series }

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
  });

  final String id;
  final MediaKind kind;
  final String title;
  final String? year;
  final String? poster;
  final String? background;
  final String? description;
  final double? rating;

  String get typeLabel => kind == MediaKind.movie ? 'Movie' : 'TV Series';

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

    return MediaItem(
      id: (json['id'] ?? '').toString(),
      kind: kind,
      title: (json['name'] ?? json['title'] ?? 'Untitled').toString(),
      year: (json['year'] ?? json['releaseInfo'])?.toString(),
      poster: json['poster']?.toString(),
      background: json['background']?.toString(),
      description: json['description']?.toString(),
      rating: rating,
    );
  }
}
