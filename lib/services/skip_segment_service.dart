import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum SkipSegmentType { intro, recap, outro, postCredits }

class SkipSegment {
  const SkipSegment({
    required this.type,
    required this.start,
    required this.end,
  });

  final SkipSegmentType type;
  final Duration start;
  final Duration end;

  String get label => switch (type) {
        SkipSegmentType.intro => 'Skip Intro',
        SkipSegmentType.recap => 'Skip Recap',
        SkipSegmentType.outro => 'Skip Outro',
        SkipSegmentType.postCredits => 'Skip Credits',
      };

  bool contains(Duration position) =>
      position >= start && position < end && end > start;
}

class SkipSegmentPreferencesService {
  static const _enabledKey = 'orvix_skip_segments_enabled_v1';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }
}

class IntroDbService {
  IntroDbService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static final Map<String, List<SkipSegment>> _cache = {};

  static String? imdbIdFrom(String raw) => _normalizeImdb(raw);

  Future<List<SkipSegment>> segments({
    required String imdbId,
    int? season,
    int? episode,
  }) async {
    final id = _normalizeImdb(imdbId);
    if (id == null) return const [];
    final key = '$id:${season ?? 0}:${episode ?? 0}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final query = <String, String>{'imdb_id': id};
    if (season != null && episode != null) {
      query['season'] = season.toString();
      query['episode'] = episode.toString();
    } else {
      query['is_movie'] = 'true';
    }
    final uri = Uri.https('api.introdb.app', '/segments', query);
    try {
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return const [];
      final result = <SkipSegment>[];
      void add(String key, SkipSegmentType type) {
        final raw = decoded[key];
        if (raw is! Map) return;
        final start = _seconds(raw['start_sec']) ??
            _milliseconds(raw['start_ms']);
        final end = _seconds(raw['end_sec']) ?? _milliseconds(raw['end_ms']);
        if (start == null || end == null || start < Duration.zero || end <= start) {
          return;
        }
        result.add(SkipSegment(type: type, start: start, end: end));
      }

      add('intro', SkipSegmentType.intro);
      add('recap', SkipSegmentType.recap);
      add('outro', SkipSegmentType.outro);
      add('post_credits', SkipSegmentType.postCredits);
      result.sort((a, b) => a.start.compareTo(b.start));
      _cache[key] = List.unmodifiable(result);
      return _cache[key]!;
    } catch (_) {
      return const [];
    }
  }

  static String? _normalizeImdb(String raw) {
    final match = RegExp(r'tt\d+', caseSensitive: false).firstMatch(raw);
    return match?.group(0)?.toLowerCase();
  }

  static Duration? _seconds(Object? value) {
    if (value is String && value.contains(':')) {
      final parts = value.split(':').map(double.tryParse).toList();
      if (parts.any((part) => part == null) || parts.length < 2 || parts.length > 3) {
        return null;
      }
      final seconds = parts.length == 3
          ? parts[0]! * 3600 + parts[1]! * 60 + parts[2]!
          : parts[0]! * 60 + parts[1]!;
      if (!seconds.isFinite || seconds < 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    }
    final number = value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
    if (number == null || !number.isFinite) return null;
    return Duration(milliseconds: (number * 1000).round());
  }

  static Duration? _milliseconds(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
    if (number == null || !number.isFinite) return null;
    return Duration(milliseconds: number.round());
  }

  static void clearCache() => _cache.clear();
}
