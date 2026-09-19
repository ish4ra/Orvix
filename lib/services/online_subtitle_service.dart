import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'subtitle_provider_credentials_service.dart';

class OnlineSubtitleResult {
  const OnlineSubtitleResult({
    required this.id,
    required this.url,
    required this.language,
    required this.languageLabel,
    required this.label,
    required this.provider,
    required this.score,
  });

  final String id;
  final String url;
  final String language;
  final String languageLabel;
  final String label;
  final String provider;
  final int score;
}

class OnlineSubtitleService {
  OnlineSubtitleService._();

  static const providerName = 'OpenSubtitles v3';
  static const _base = 'https://opensubtitles-v3.strem.io';

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

    final endpoints = <({Uri uri, int bonus})>[];
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
      ));
    }
    endpoints.add((
      uri: Uri.parse('$_base/subtitles/$type/$suffix.json'),
      bonus: 0,
    ));

    final preferred = normalizeLanguage(preferredLanguage);
    final releaseTokens = _releaseTokens(cleanRelease);
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
          for (final token in releaseTokens) {
            if (searchable.contains(token)) {
              releaseMatches++;
              score += token.length >= 5 ? 16 : 7;
            }
          }
          if (releaseMatches > 0) score += 60;
          if (searchable.contains('forced')) score -= 20;

          final result = OnlineSubtitleResult(
            id: (raw['id'] ?? url).toString(),
            url: url,
            language: language,
            languageLabel: languageName(language),
            label: rawLabel.isEmpty ? 'Subtitle' : rawLabel,
            provider: providerName,
            score: score,
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

  static Future<bool> validateSubDlApiKey(String rawKey) async {
    final key = rawKey.trim();
    if (key.isEmpty) return false;
    try {
      final response = await http
          .get(
            Uri.https('api.subdl.com', '/api/v1/me', <String, String>{
              'api_key': key,
            }),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      return decoded is Map && decoded['status'] != false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _addSubDlEnglishResults(
    Map<String, OnlineSubtitleResult> byUrl, {
    required MediaItem item,
    required EpisodeItem? episode,
    required String? releaseHint,
    required Set<String> releaseTokens,
  }) async {
    final apiKey = await SubtitleProviderCredentialsService.subDlApiKey();
    if (apiKey == null || apiKey.isEmpty) return;

    final imdbId = item.id.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) return;

    final params = <String, String>{
      'api_key': apiKey,
      'imdb_id': imdbId,
      'type': item.kind == MediaKind.movie ? 'movie' : 'tv',
      'languages': 'EN',
      'releases': '1',
      'unpack': '1',
      'subs_per_page': '30',
      'client': 'custom_integration',
    };
    final year = item.startYear;
    if (year != null) params['year'] = year.toString();
    if (releaseHint != null && releaseHint.trim().isNotEmpty) {
      params['file_name'] = releaseHint.trim();
    }
    if (item.kind == MediaKind.series && episode != null) {
      params['season_number'] = episode.season.toString();
      params['episode_number'] = episode.episode.toString();
    }

    try {
      final response = await http
          .get(
            Uri.https('api.subdl.com', '/api/v1/subtitles', params),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return;

      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is! Map || decoded['status'] == false) return;
      final subtitles = decoded['subtitles'];
      if (subtitles is! List) return;

      for (final raw in subtitles.whereType<Map>()) {
        final parentLabel =
            (raw['release_name'] ?? raw['name'] ?? 'SubDL subtitle')
                .toString()
                .trim();
        final unpack = raw['unpack_files'];

        var addedDirect = false;
        if (unpack is List) {
          for (final file in unpack.whereType<Map>()) {
            if (!_subDlEpisodeFileMatches(file, episode)) continue;
            final path = file['url']?.toString().trim() ?? '';
            if (path.isEmpty) continue;
            final normalizedPath = path.startsWith('/') ? path : '/' + path;
            final url = path.startsWith('http')
                ? path
                : 'https://dl.subdl.com' + normalizedPath;
            final fileLabel =
                (file['release_name'] ?? file['name'] ?? parentLabel)
                    .toString()
                    .trim();
            final searchable = (parentLabel +
                    ' ' +
                    fileLabel +
                    ' ' +
                    (file['name'] ?? '').toString())
                .toLowerCase();
            final score = _subDlProviderScore(
              searchable: searchable,
              releaseTokens: releaseTokens,
              providerBonus: 35,
            );
            final rawId =
                file['file_n_id'] ?? file['md5'] ?? url.hashCode.toString();
            byUrl[url] = OnlineSubtitleResult(
              id: 'subdl:' + rawId.toString(),
              url: url,
              language: 'eng',
              languageLabel: 'English',
              label: fileLabel.isEmpty ? parentLabel : fileLabel,
              provider: 'SubDL',
              score: score,
            );
            addedDirect = true;
          }
        }

        if (addedDirect) continue;

        final path = raw['url']?.toString().trim() ?? '';
        if (path.isEmpty) continue;
        final normalizedPath = path.startsWith('/') ? path : '/' + path;
        final url = path.startsWith('http')
            ? path
            : 'https://dl.subdl.com' + normalizedPath;
        final searchable = (parentLabel +
                ' ' +
                (raw['name'] ?? '').toString() +
                ' ' +
                (raw['releases'] ?? '').toString())
            .toLowerCase();
        final score = _subDlProviderScore(
          searchable: searchable,
          releaseTokens: releaseTokens,
          providerBonus: 30,
        );
        final rawId =
            raw['id'] ?? raw['subtitlePage'] ?? raw['name'] ?? url.hashCode.toString();
        byUrl[url] = OnlineSubtitleResult(
          id: 'subdl:' + rawId.toString(),
          url: url,
          language: 'eng',
          languageLabel: 'English',
          label: parentLabel.isEmpty ? 'SubDL subtitle' : parentLabel,
          provider: 'SubDL',
          score: score,
        );
      }
    } catch (_) {
      // Optional provider failures must never affect playback.
    }
  }

  static bool _subDlEpisodeFileMatches(Map file, EpisodeItem? episode) {
    if (episode == null) return true;
    final season = int.tryParse(file['season']?.toString() ?? '');
    final ep = int.tryParse(file['episode']?.toString() ?? '');
    if (season != null && season > 0 && season != episode.season) return false;
    if (ep != null && ep > 0 && ep != episode.episode) return false;
    return true;
  }

  static int _subDlProviderScore({
    required String searchable,
    required Set<String> releaseTokens,
    required int providerBonus,
  }) {
    var score = providerBonus + 520;
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
        searchable.contains('commentary')) {
      score -= 80;
    }
    return score;
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
