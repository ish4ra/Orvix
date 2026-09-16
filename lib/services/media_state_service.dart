import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class ContinueWatchingEntry {
  const ContinueWatchingEntry({
    required this.item,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.episode,
  });

  final MediaItem item;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final EpisodeItem? episode;

  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds)
        .clamp(0, 1)
        .toDouble();
  }

  String get key => MediaStateService.progressKey(item, episode: episode);
}

class MediaStateService {
  static const _watchlistKey = 'pikora_watchlist_v1';
  static const _progressKey = 'pikora_continue_watching_v1';

  static String progressKey(MediaItem item, {EpisodeItem? episode}) {
    final suffix = episode == null ? 'movie' : 's${episode.season}e${episode.episode}';
    return '${item.kind.name}:${item.id}:$suffix';
  }

  Future<List<MediaItem>> watchlist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_watchlistKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(_mediaFromJson)
          .where((item) => item.id.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<bool> isWatchlisted(MediaItem item) async {
    final list = await watchlist();
    return list.any((entry) => entry.id == item.id && entry.kind == item.kind);
  }

  Future<bool> toggleWatchlist(MediaItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final current = [...await watchlist()];
    final index = current.indexWhere((entry) => entry.id == item.id && entry.kind == item.kind);
    final added = index < 0;
    if (added) {
      current.insert(0, item);
    } else {
      current.removeAt(index);
    }
    await prefs.setString(
      _watchlistKey,
      jsonEncode(current.map(_mediaToJson).toList(growable: false)),
    );
    return added;
  }

  Future<void> saveProgress(
    MediaItem item, {
    required Duration position,
    required Duration duration,
    EpisodeItem? episode,
  }) async {
    if (duration.inSeconds <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_progressKey);
    final map = <String, dynamic>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map.addAll(decoded);
      } catch (_) {}
    }

    final key = progressKey(item, episode: episode);
    final fraction = position.inMilliseconds / duration.inMilliseconds;
    if (fraction >= .95 || position < const Duration(seconds: 20)) {
      map.remove(key);
    } else {
      map[key] = {
        'item': _mediaToJson(item),
        if (episode != null) 'episode': _episodeToJson(episode),
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'updatedAt': DateTime.now().toIso8601String(),
      };
    }
    await prefs.setString(_progressKey, jsonEncode(map));
  }

  Future<Duration?> resumePosition(MediaItem item, {EpisodeItem? episode}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_progressKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final entry = decoded[progressKey(item, episode: episode)];
      if (entry is! Map<String, dynamic>) return null;
      final milliseconds = int.tryParse(entry['positionMs']?.toString() ?? '');
      if (milliseconds == null || milliseconds <= 0) return null;
      return Duration(milliseconds: milliseconds);
    } catch (_) {
      return null;
    }
  }

  Future<List<ContinueWatchingEntry>> continueWatching({int limit = 20}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_progressKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const [];
      final entries = <ContinueWatchingEntry>[];
      for (final value in decoded.values) {
        if (value is! Map<String, dynamic>) continue;
        final itemRaw = value['item'];
        if (itemRaw is! Map<String, dynamic>) continue;
        final item = _mediaFromJson(itemRaw);
        final episodeRaw = value['episode'];
        final positionMs = int.tryParse(value['positionMs']?.toString() ?? '') ?? 0;
        final durationMs = int.tryParse(value['durationMs']?.toString() ?? '') ?? 0;
        final updatedAt = DateTime.tryParse(value['updatedAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (item.id.isEmpty || durationMs <= 0) continue;
        entries.add(
          ContinueWatchingEntry(
            item: item,
            episode: episodeRaw is Map<String, dynamic> ? _episodeFromJson(episodeRaw) : null,
            position: Duration(milliseconds: positionMs),
            duration: Duration(milliseconds: durationMs),
            updatedAt: updatedAt,
          ),
        );
      }
      entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return entries.take(limit).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _mediaToJson(MediaItem item) => {
        'id': item.id,
        'kind': item.kind.name,
        'title': item.title,
        'year': item.year,
        'poster': item.poster,
        'background': item.background,
        'description': item.description,
        'rating': item.rating,
        'runtime': item.runtime,
        'genres': item.genres,
      };

  MediaItem _mediaFromJson(Map<String, dynamic> json) => MediaItem(
        id: (json['id'] ?? '').toString(),
        kind: json['kind']?.toString() == MediaKind.series.name ? MediaKind.series : MediaKind.movie,
        title: (json['title'] ?? 'Untitled').toString(),
        year: json['year']?.toString(),
        poster: json['poster']?.toString(),
        background: json['background']?.toString(),
        description: json['description']?.toString(),
        rating: double.tryParse(json['rating']?.toString() ?? ''),
        runtime: json['runtime']?.toString(),
        genres: json['genres'] is List
            ? (json['genres'] as List).map((e) => e.toString()).toList(growable: false)
            : const [],
      );

  Map<String, dynamic> _episodeToJson(EpisodeItem episode) => {
        'id': episode.id,
        'season': episode.season,
        'episode': episode.episode,
        'title': episode.title,
        'overview': episode.overview,
        'thumbnail': episode.thumbnail,
        'released': episode.released,
      };

  EpisodeItem _episodeFromJson(Map<String, dynamic> json) => EpisodeItem(
        id: (json['id'] ?? '').toString(),
        season: int.tryParse(json['season']?.toString() ?? '') ?? 0,
        episode: int.tryParse(json['episode']?.toString() ?? '') ?? 0,
        title: (json['title'] ?? 'Episode').toString(),
        overview: json['overview']?.toString(),
        thumbnail: json['thumbnail']?.toString(),
        released: json['released']?.toString(),
      );
}
