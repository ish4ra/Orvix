import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'subdl_transcript_service.dart';

class OnlineSubtitleResult {
  const OnlineSubtitleResult({
    required this.id,
    required this.url,
    required this.language,
    required this.languageLabel,
    required this.label,
    required this.provider,
    required this.score,
    this.hashScoped = false,
    this.exactHashPath = false,
    this.releaseMatchCount = 0,
    this.strongReleaseMatchCount = 0,
  });

  final String id;
  final String url;
  final String language;
  final String languageLabel;
  final String label;
  final String provider;
  final int score;

  /// True when the subtitle addon request included an OpenSubtitles file hash.
  /// Some addons still return title/episode fallbacks for a hash-scoped request,
  /// so this alone must never be treated as proof of exact timing.
  final bool hashScoped;

  /// True only for the legacy official OpenSubtitles route where the file hash
  /// itself is the resource id. This is materially stronger than v3 merely
  /// receiving videoHash as an extra parameter.
  final bool exactHashPath;

  /// Number of selected-release filename tokens that were also present in the
  /// subtitle result metadata.
  final int releaseMatchCount;

  /// Release-specific matches after generic title/episode/year tokens have
  /// been removed. A positive value is evidence for the same encode/release.
  final int strongReleaseMatchCount;
}

class OnlineSubtitleService {
  OnlineSubtitleService._();

  static const providerName = 'OpenSubtitles v3';
  static const legacyProviderName = 'OpenSubtitles';
  static const _base = 'https://opensubtitles-v3.strem.io';
  static const _legacyBase = 'https://opensubtitles.strem.io/stremio/v1';

  static Future<List<OnlineSubtitleResult>> search({
    required MediaItem item,
    EpisodeItem? episode,
    String? releaseHint,
    int? videoSize,
    String? videoHash,
    String preferredLanguage = 'eng',
    bool includeTranscriptFallbacks = false,
  }) async {
    final imdbId = item.id.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) return const [];

    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final suffix = item.kind == MediaKind.series && episode != null
        ? '$imdbId:${episode.season}:${episode.episode}'
        : imdbId;

    final endpoints = <
        ({
          Uri uri,
          int bonus,
          String provider,
          bool hashScoped,
          bool exactHashPath,
        })
      >[];
    final extras = <String>[];
    final cleanHash = videoHash?.trim().toLowerCase();
    final validHash = cleanHash != null &&
        cleanHash.length == 16 &&
        !RegExp(r'[^a-f0-9]').hasMatch(cleanHash);
    if (validHash) {
      extras.add('videoHash=${Uri.encodeComponent(cleanHash!)}');
    }
    final cleanRelease = releaseHint?.trim();
    if (cleanRelease != null && cleanRelease.isNotEmpty) {
      extras.add('filename=${Uri.encodeComponent(cleanRelease)}');
    }
    if (videoSize != null && videoSize > 0) {
      extras.add('videoSize=$videoSize');
    }
    if (extras.isNotEmpty) {
      endpoints.add((
        uri: Uri.parse(
          '$_base/subtitles/$type/$suffix/${extras.join('&')}.json',
        ),
        bonus: validHash ? 600 : 40,
        provider: providerName,
        hashScoped: validHash,
        exactHashPath: false,
      ));
    }
    endpoints.add((
      uri: Uri.parse('$_base/subtitles/$type/$suffix.json'),
      bonus: 0,
      provider: providerName,
      hashScoped: false,
      exactHashPath: false,
    ));

    // Stremio still ships the older official OpenSubtitles addon alongside
    // v3. Use it as a secondary corpus and dedupe identical subtitle URLs.
    if (validHash) {
      final legacyExtras = <String>[
        'videoID=${Uri.encodeComponent(suffix)}',
        if (videoSize != null && videoSize > 0) 'videoSize=$videoSize',
      ];
      endpoints.add((
        uri: Uri.parse(
          '$_legacyBase/subtitles/$type/$cleanHash/${legacyExtras.join('&')}.json',
        ),
        bonus: 520,
        provider: legacyProviderName,
        hashScoped: true,
        exactHashPath: true,
      ));
    }
    endpoints.add((
      uri: Uri.parse('$_legacyBase/subtitles/$type/$suffix.json'),
      bonus: -10,
      provider: legacyProviderName,
      hashScoped: false,
      exactHashPath: false,
    ));

    final preferred = normalizeLanguage(preferredLanguage);
    final releaseTokens = _releaseTokens(cleanRelease);
    final titleTokens = _releaseTokens(item.title);
    final strongReleaseTokens = releaseTokens.where((token) {
      if (titleTokens.contains(token)) return false;
      if (RegExp(r'^s\d{1,2}e\d{1,3}$').hasMatch(token)) return false;
      if (RegExp(r'^\d{4}$').hasMatch(token)) return false;
      return true;
    }).toSet();
    final byUrl = <String, OnlineSubtitleResult>{};

    for (final endpoint in endpoints) {
      try {
        final response = await http.get(
          endpoint.uri,
          headers: const {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) continue;

        final decoded = jsonDecode(
          utf8.decode(response.bodyBytes, allowMalformed: true),
        );
        final entries = decoded is Map ? decoded['subtitles'] : null;
        if (entries is! List) continue;

        for (final raw in entries.whereType<Map>()) {
          final url = raw['url']?.toString().trim() ?? '';
          if (!url.startsWith(RegExp(r'https?://'))) continue;

          final language = normalizeLanguage(
            (raw['lang'] ?? raw['language'] ?? '').toString(),
          );
          final rawLabel =
              (raw['label'] ?? raw['id'] ?? 'Subtitle').toString().trim();
          final searchable = '$rawLabel ${raw['id'] ?? ''} $url'.toLowerCase();

          var score = endpoint.bonus;
          if (language == preferred) score += 500;
          if (language == 'eng') score += 20;

          var releaseMatches = 0;
          var strongReleaseMatches = 0;
          for (final token in releaseTokens) {
            if (searchable.contains(token)) {
              releaseMatches++;
              if (strongReleaseTokens.contains(token)) {
                strongReleaseMatches++;
              }
              score += token.length >= 5 ? 16 : 7;
            }
          }
          if (releaseMatches > 0) score += 60;
          if (strongReleaseMatches > 0) score += 80;
          if (searchable.contains('forced')) score -= 20;

          final result = OnlineSubtitleResult(
            id: (raw['id'] ?? url).toString(),
            url: url,
            language: language,
            languageLabel: languageName(language),
            label: rawLabel.isEmpty ? 'Subtitle' : rawLabel,
            provider: endpoint.provider,
            score: score,
            hashScoped: endpoint.hashScoped,
            exactHashPath: endpoint.exactHashPath,
            releaseMatchCount: releaseMatches,
            strongReleaseMatchCount: strongReleaseMatches,
          );

          final existing = byUrl[url];
          if (existing == null || result.score > existing.score) {
            byUrl[url] = result;
          }
        }
      } catch (_) {
        // A subtitle addon outage should never affect video playback.
      }
    }

    if (includeTranscriptFallbacks) {
      await _addSubDlEnglishResults(
        byUrl,
        item: item,
        episode: episode,
        releaseHint: cleanRelease,
        releaseTokens: releaseTokens,
      );
    }

    final results = byUrl.values.toList(growable: false)
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        final language = a.languageLabel.compareTo(b.languageLabel);
        if (language != 0) return language;
        return a.label.compareTo(b.label);
      });
    return results;
  }

  static Future<void> _addSubDlEnglishResults(
    Map<String, OnlineSubtitleResult> byUrl, {
    required MediaItem item,
    required EpisodeItem? episode,
    required String? releaseHint,
    required Set<String> releaseTokens,
  }) async {
    final candidates = await SubDlTranscriptService.searchEnglish(
      item: item,
      episode: episode,
      releaseHint: releaseHint,
    );

    for (final candidate in candidates) {
      final searchable = candidate.label.toLowerCase();
      var score = candidate.score;
      var releaseMatches = 0;
      for (final token in releaseTokens) {
        if (searchable.contains(token)) {
          releaseMatches++;
          score += token.length >= 5 ? 16 : 7;
        }
      }
      if (releaseMatches > 0) score += 60;
      if (searchable.contains('forced') ||
          searchable.contains('foreign only') ||
          searchable.contains('commentary') ||
          searchable.contains('signs')) {
        score -= 80;
      }

      final result = OnlineSubtitleResult(
        id: candidate.id,
        url: candidate.url,
        language: 'eng',
        languageLabel: 'English',
        label: candidate.label,
        provider: 'SubDL',
        score: score,
      );
      final existing = byUrl[candidate.url];
      if (existing == null || result.score > existing.score) {
        byUrl[candidate.url] = result;
      }
    }
  }

  static String normalizeLanguage(String raw) {
    final value = raw.trim().toLowerCase().replaceAll('_', '-');
    if (value.isEmpty) return 'und';
    const aliases = <String, String>{
      'en': 'eng',
      'en-us': 'eng',
      'en-gb': 'eng',
      'english': 'eng',
      'si': 'sin',
      'sinhala': 'sin',
      'sinhalese': 'sin',
      'ta': 'tam',
      'tamil': 'tam',
      'hi': 'hin',
      'hindi': 'hin',
      'es': 'spa',
      'spanish': 'spa',
      'fr': 'fre',
      'fra': 'fre',
      'french': 'fre',
      'de': 'ger',
      'deu': 'ger',
      'german': 'ger',
      'it': 'ita',
      'italian': 'ita',
      'pt': 'por',
      'pt-br': 'por',
      'portuguese': 'por',
      'nl': 'dut',
      'nld': 'dut',
      'dutch': 'dut',
      'ru': 'rus',
      'russian': 'rus',
      'ar': 'ara',
      'arabic': 'ara',
      'ja': 'jpn',
      'japanese': 'jpn',
      'ko': 'kor',
      'korean': 'kor',
      'zh': 'chi',
      'zho': 'chi',
      'chinese': 'chi',
      'id': 'ind',
      'indonesian': 'ind',
      'tr': 'tur',
      'turkish': 'tur',
    };
    return aliases[value] ?? value;
  }

  static String languageName(String code) {
    switch (normalizeLanguage(code)) {
      case 'eng':
        return 'English';
      case 'sin':
        return 'Sinhala';
      case 'tam':
        return 'Tamil';
      case 'hin':
        return 'Hindi';
      case 'spa':
        return 'Spanish';
      case 'fre':
        return 'French';
      case 'ger':
        return 'German';
      case 'ita':
        return 'Italian';
      case 'por':
        return 'Portuguese';
      case 'dut':
        return 'Dutch';
      case 'rus':
        return 'Russian';
      case 'ara':
        return 'Arabic';
      case 'jpn':
        return 'Japanese';
      case 'kor':
        return 'Korean';
      case 'chi':
        return 'Chinese';
      case 'ind':
        return 'Indonesian';
      case 'tur':
        return 'Turkish';
      case 'und':
        return 'Unknown';
      default:
        return code.trim().isEmpty ? 'Unknown' : code.toUpperCase();
    }
  }

  static Set<String> _releaseTokens(String? release) {
    if (release == null || release.trim().isEmpty) return const <String>{};
    final normalized = release
        .toLowerCase()
        .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();

    const ignored = <String>{
      '1080p',
      '2160p',
      '720p',
      '480p',
      '4k',
      'uhd',
      'hdr',
      'hdr10',
      'bluray',
      'brrip',
      'webrip',
      'web',
      'webdl',
      'x264',
      'x265',
      'h264',
      'h265',
      'hevc',
      'avc',
      'aac',
      'dts',
      'atmos',
      'remux',
      'mkv',
      'mp4',
      'avi',
      '10bit',
      '8bit',
    };

    return normalized
        .split(' ')
        .where((token) => token.length >= 3 && !ignored.contains(token))
        .take(16)
        .toSet();
  }
}
