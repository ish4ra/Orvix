import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/media_item.dart';

class AiSubtitleCue {
  AiSubtitleCue({
    required this.start,
    required this.end,
    required this.source,
    this.translation,
  });

  final Duration start;
  final Duration end;
  final String source;
  String? translation;
}

class AiPreparedSubtitle {
  AiPreparedSubtitle({
    required this.key,
    required this.title,
    required this.sourceUrl,
    required this.cues,
    required this.sourceMatch,
  });

  final String key;
  final String title;
  final String sourceUrl;
  final List<AiSubtitleCue> cues;
  final String sourceMatch;

  int get translatedCount =>
      cues.where((cue) => cue.translation?.isNotEmpty == true).length;

  String subtitleAt(Duration position) {
    if (cues.isEmpty) return '';
    var low = 0;
    var high = cues.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final cue = cues[mid];
      if (position < cue.start) {
        high = mid - 1;
      } else if (position > cue.end) {
        low = mid + 1;
      } else {
        return cue.translation?.trim() ?? '';
      }
    }
    return '';
  }

  AiSubtitleCue? matchSourceCue(String raw) {
    final target = _normalizeCue(raw);
    if (target.isEmpty) return null;
    for (final cue in cues) {
      if (_normalizeCue(cue.source) == target) return cue;
    }
    if (target.length < 12) return null;
    AiSubtitleCue? best;
    var bestScore = 0.0;
    final targetWords =
        target.split(' ').where((value) => value.isNotEmpty).toSet();
    if (targetWords.length < 3) return null;
    for (final cue in cues) {
      final source = _normalizeCue(cue.source);
      if (source.length < 12) continue;
      final words =
          source.split(' ').where((value) => value.isNotEmpty).toSet();
      if (words.length < 3) continue;
      final intersection = targetWords.intersection(words).length;
      final union = targetWords.union(words).length;
      if (union == 0) continue;
      final score = intersection / union;
      if (score > bestScore) {
        bestScore = score;
        best = cue;
      }
    }
    return bestScore >= .88 ? best : null;
  }
}

class AiSinhalaSubtitleService {
  AiSinhalaSubtitleService._();

  static final Map<String, AiPreparedSubtitle> _preparedCache =
      <String, AiPreparedSubtitle>{};
  static final Map<String, Future<AiPreparedSubtitle?>> _inFlight =
      <String, Future<AiPreparedSubtitle?>>{};

  static bool get canTranslate =>
      Supabase.instance.client.auth.currentSession != null;

  static Future<AiPreparedSubtitle?> prepareBuffered({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    void Function(String message)? onStatus,
  }) async {
    final probe = await _probeVideo(videoUrl);
    final identity = probe.hash ??
        '${probe.size ?? 0}:${probe.fileName ?? Uri.tryParse(videoUrl)?.pathSegments.lastOrNull ?? 'unknown'}';
    final key = '${_mediaKey(item, episode)}:$identity';
    final cached = _preparedCache[key];
    if (cached != null &&
        cached.translatedCount >= math.min(48, cached.cues.length)) {
      return cached;
    }
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _prepare(
          key: key,
          item: item,
          episode: episode,
          probe: probe,
          onStatus: onStatus,
        );
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  static Future<AiPreparedSubtitle?> _prepare({
    required String key,
    required MediaItem item,
    required EpisodeItem? episode,
    required _VideoProbe probe,
    void Function(String message)? onStatus,
  }) async {
    if (!canTranslate) {
      throw const AiSubtitleException(
        'Sign in to your Orvix account to use AI Sinhala subtitles.',
      );
    }
    final imdbId = item.id.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) {
      throw const AiSubtitleException(
        'This title does not have a compatible IMDb subtitle id.',
      );
    }

    final suffix = item.kind == MediaKind.series && episode != null
        ? '$imdbId:${episode.season}:${episode.episode}'
        : imdbId;
    final type = item.kind == MediaKind.movie ? 'movie' : 'series';

    final endpoints = <({Uri uri, String match})>[];
    final extras = <String>[];
    if (probe.hash != null)
      extras.add('videoHash=${Uri.encodeComponent(probe.hash!)}');
    if (probe.size != null) extras.add('videoSize=${probe.size}');
    if (probe.fileName?.isNotEmpty == true) {
      extras.add('filename=${Uri.encodeComponent(probe.fileName!)}');
    }
    if (extras.isNotEmpty) {
      endpoints.add((
        uri: Uri.parse(
          'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix/${extras.join('&')}.json',
        ),
        match: probe.hash != null ? 'video-hash' : 'filename-size',
      ));
    }
    endpoints.add((
      uri: Uri.parse(
        'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix.json',
      ),
      match: 'title-episode',
    ));

    List<AiSubtitleCue>? cues;
    String? sourceUrl;
    var sourceMatch = 'title-episode';
    Object? lastError;

    for (final endpoint in endpoints) {
      onStatus?.call(
        endpoint.match == 'video-hash'
            ? 'Matching subtitles to this exact video file…'
            : endpoint.match == 'filename-size'
                ? 'Matching subtitles to this video release…'
                : 'Finding the best English subtitle…',
      );

      List<String> candidates = const [];
      try {
        candidates = await _subtitleCandidates(
          endpoint.uri,
          preferredFileName: probe.fileName,
        );
      } catch (error) {
        lastError = error;
        continue;
      }
      if (candidates.isEmpty) continue;

      for (final url
          in candidates.take(endpoint.match == 'title-episode' ? 10 : 6)) {
        try {
          onStatus?.call('Checking the matched English subtitle…');
          final text = await _downloadSubtitle(url);
          final parsed = _parseSubtitle(text);
          if (parsed.length >= 8) {
            cues = parsed;
            sourceUrl = url;
            sourceMatch = endpoint.match;
            break;
          }
        } catch (error) {
          lastError = error;
        }
      }
      if (cues != null && sourceUrl != null) break;

      // A provider can return stale/broken files for an otherwise exact query.
      // Keep going to filename/title matching instead of failing the whole feature.
      onStatus?.call('Trying another subtitle match…');
    }

    if (cues == null || sourceUrl == null) {
      throw AiSubtitleException(
        lastError == null
            ? 'No usable English text subtitle was found.'
            : 'Could not prepare a usable English subtitle source.',
      );
    }

    final prepared = AiPreparedSubtitle(
      key: key,
      title: episode == null ? item.title : '${item.title} ${episode.label}',
      sourceUrl: sourceUrl,
      cues: cues,
      sourceMatch: sourceMatch,
    );
    _preparedCache[key] = prepared;

    final firstEnd = math.min(48, cues.length);
    onStatus?.call('Translating the first subtitle buffer to Sinhala…');
    await _translateRange(prepared, 0, firstEnd);
    onStatus?.call('Sinhala subtitles ready — opening player…');

    if (firstEnd < cues.length) {
      unawaited(_translateRemaining(prepared, firstEnd));
    }
    return prepared;
  }

  static Future<http.Response> _httpGetWithRetry(
    Uri endpoint, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await http.get(endpoint).timeout(timeout);
        if ((response.statusCode >= 200 && response.statusCode < 300) ||
            (response.statusCode < 500 && response.statusCode != 429)) {
          return response;
        }
        lastError = AiSubtitleException(
          'Subtitle service returned ${response.statusCode}.',
        );
      } catch (error) {
        lastError = error;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 450 * (attempt + 1)));
      }
    }
    throw lastError ??
        const AiSubtitleException('Subtitle service is unavailable.');
  }

  static Set<String> _releaseTokens(String? fileName) {
    if (fileName == null || fileName.trim().isEmpty) return const <String>{};
    final normalized = fileName
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
      'proper',
      'repack',
      'multi',
      'mkv',
      'mp4',
      'avi',
      '10bit',
      '8bit',
    };
    return normalized
        .split(' ')
        .where((token) => token.length >= 3 && !ignored.contains(token))
        .take(14)
        .toSet();
  }

  static Future<List<String>> _subtitleCandidates(
    Uri endpoint, {
    String? preferredFileName,
  }) async {
    final response = await _httpGetWithRetry(endpoint);
    if (response.statusCode < 200 || response.statusCode >= 300)
      return const [];
    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    final entries = decoded is Map ? decoded['subtitles'] : null;
    if (entries is! List) return const [];

    final preferredTokens = _releaseTokens(preferredFileName);
    final ranked = <({String url, int score})>[];
    for (final entry in entries.whereType<Map>()) {
      final lang = (entry['lang'] ?? entry['language'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final english = lang == 'eng' ||
          lang == 'en' ||
          lang.startsWith('en-') ||
          lang.contains('english');
      if (!english) continue;
      final url = entry['url']?.toString().trim() ?? '';
      if (!url.startsWith('http')) continue;

      final searchable = '${entry['label'] ?? ''} ${entry['id'] ?? ''} $url'
          .toString()
          .toLowerCase();
      var score = 0;
      for (final token in preferredTokens) {
        if (searchable.contains(token)) score += token.length >= 5 ? 3 : 1;
      }
      if (searchable.contains('forced')) score -= 3;
      ranked.add((url: url, score: score));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked.map((entry) => entry.url).toList(growable: false);
  }

  static Future<void> _translateRemaining(
    AiPreparedSubtitle prepared,
    int start,
  ) async {
    var cursor = start;
    while (cursor < prepared.cues.length) {
      final end = math.min(cursor + 60, prepared.cues.length);
      try {
        await _translateRange(prepared, cursor, end);
      } on AiSubtitleException catch (error) {
        if (error.rateLimited) return;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      cursor = end;
    }
  }

  static Future<void> _translateRange(
    AiPreparedSubtitle prepared,
    int start,
    int end,
  ) async {
    if (start >= end) return;
    final slice = prepared.cues.sublist(start, end);

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await Supabase.instance.client.functions.invoke(
          'translate-subtitle-si',
          body: <String, dynamic>{
            'title': prepared.title,
            'segments': slice.map((cue) => cue.source).toList(growable: false),
          },
        );
        final data = response.data;
        if (response.status == 429 ||
            (data is Map && data['error'] == 'rate_limited')) {
          throw const AiSubtitleException(
            'AI Sinhala subtitle limit reached.',
            rateLimited: true,
          );
        }
        if (response.status < 200 || response.status >= 300) {
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 550));
            continue;
          }
          throw const AiSubtitleException(
              'Could not translate subtitle buffer.');
        }

        final raw = data is Map ? data['translations'] : null;
        if (raw is! List || raw.length != slice.length) {
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 550));
            continue;
          }
          throw const AiSubtitleException('AI subtitle buffer was incomplete.');
        }
        for (var i = 0; i < slice.length; i++) {
          final value = raw[i]?.toString().trim() ?? '';
          if (value.isNotEmpty) slice[i].translation = value;
        }
        return;
      } on AiSubtitleException catch (error) {
        if (error.rateLimited || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 550));
      } catch (_) {
        if (attempt == 1) {
          throw const AiSubtitleException(
              'Could not translate subtitle buffer.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 550));
      }
    }
  }

  static Future<_VideoProbe> _probeVideo(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return const _VideoProbe();
    }
    final client = http.Client();
    try {
      final first = await _readRange(client, uri, 0, 65535);
      if (first == null) return _VideoProbe(fileName: _fileNameFromUri(uri));
      final fileName =
          _fileNameFromHeaders(first.headers) ?? _fileNameFromUri(uri);
      final size = _totalSize(first.statusCode, first.headers);
      if (first.statusCode != 206 ||
          size == null ||
          size < 131072 ||
          first.bytes.length < 65536) {
        return _VideoProbe(fileName: fileName, size: size);
      }
      final tail = await _readRange(client, uri, size - 65536, size - 1);
      if (tail == null || tail.statusCode != 206 || tail.bytes.length < 65536) {
        return _VideoProbe(fileName: fileName, size: size);
      }
      return _VideoProbe(
        fileName: fileName,
        size: size,
        hash: _openSubtitlesHash(size, first.bytes, tail.bytes),
      );
    } catch (_) {
      return _VideoProbe(fileName: _fileNameFromUri(uri));
    } finally {
      client.close();
    }
  }

  static Future<_RangeRead?> _readRange(
    http.Client client,
    Uri uri,
    int start,
    int end,
  ) async {
    final request = http.Request('GET', uri)
      ..headers['Range'] = 'bytes=$start-$end'
      ..headers['Accept-Encoding'] = 'identity';
    final response =
        await client.send(request).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 400) return null;
    final limit = end - start + 1;
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      final remaining = limit - bytes.length;
      if (remaining <= 0) break;
      if (chunk.length <= remaining) {
        bytes.addAll(chunk);
      } else {
        bytes.addAll(chunk.take(remaining));
      }
      if (bytes.length >= limit) break;
    }
    return _RangeRead(
      statusCode: response.statusCode,
      headers: response.headers,
      bytes: bytes,
    );
  }

  static int? _totalSize(int statusCode, Map<String, String> headers) {
    final contentRange = headers['content-range'];
    if (contentRange != null) {
      final match = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      final value = match == null ? null : int.tryParse(match.group(1)!);
      if (value != null && value > 0) return value;
    }
    if (statusCode == 200) {
      final length = int.tryParse(headers['content-length'] ?? '');
      if (length != null && length > 0) return length;
    }
    return null;
  }

  static String? _fileNameFromHeaders(Map<String, String> headers) {
    final disposition = headers['content-disposition'];
    if (disposition == null || disposition.isEmpty) return null;
    final utf = RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false)
        .firstMatch(disposition);
    if (utf != null) return Uri.decodeComponent(utf.group(1)!.trim());
    final plain = RegExp(r'filename="?([^";]+)"?', caseSensitive: false)
        .firstMatch(disposition);
    return plain?.group(1)?.trim();
  }

  static String? _fileNameFromUri(Uri uri) {
    if (uri.pathSegments.isEmpty) return null;
    final value = Uri.decodeComponent(uri.pathSegments.last).trim();
    return value.isEmpty ? null : value;
  }

  static String _openSubtitlesHash(
    int size,
    List<int> first,
    List<int> last,
  ) {
    const mask = 0xFFFFFFFFFFFFFFFF;
    var hash = size & mask;
    for (var offset = 0; offset + 7 < 65536; offset += 8) {
      hash = (hash + _littleEndian64(first, offset)) & mask;
      hash = (hash + _littleEndian64(last, offset)) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static int _littleEndian64(List<int> bytes, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value |= (bytes[offset + i] & 0xff) << (8 * i);
    }
    return value;
  }

  static Future<String> _downloadSubtitle(String url) async {
    final response = await _httpGetWithRetry(
      Uri.parse(url),
      timeout: const Duration(seconds: 15),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AiSubtitleException('Subtitle download failed.');
    }
    List<int> bytes = response.bodyBytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = gzip.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static List<AiSubtitleCue> _parseSubtitle(String input) {
    var text = input
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (text.trimLeft().startsWith('WEBVTT')) {
      text = text.replaceFirst(RegExp(r'^\s*WEBVTT[^\n]*\n'), '');
    }
    final blocks = text.split(RegExp(r'\n\s*\n'));
    final cues = <AiSubtitleCue>[];
    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((line) => line.trimRight())
          .toList(growable: false);
      final timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0) continue;
      final timing = lines[timingIndex].split('-->');
      if (timing.length < 2) continue;
      final start = _parseTimestamp(timing[0].trim());
      final endText = timing[1].trim().split(RegExp(r'\s+')).first;
      final end = _parseTimestamp(endText);
      if (start == null || end == null || end <= start) continue;
      final cueText = lines
          .skip(timingIndex + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\{\\[^}]+\}'), '')
          .trim();
      if (cueText.isEmpty) continue;
      cues.add(AiSubtitleCue(start: start, end: end, source: cueText));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration? _parseTimestamp(String raw) {
    final clean = raw.replaceAll(',', '.').trim();
    final parts = clean.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final secondsPart = parts.last;
    final secondPieces = secondsPart.split('.');
    final seconds = int.tryParse(secondPieces.first);
    if (seconds == null) return null;
    var milliseconds = 0;
    if (secondPieces.length > 1) {
      final fraction = secondPieces[1].replaceAll(RegExp(r'\D'), '');
      if (fraction.isNotEmpty) {
        milliseconds =
            int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
      }
    }
    final minutes = int.tryParse(parts[parts.length - 2]) ?? 0;
    final hours = parts.length == 3 ? int.tryParse(parts.first) ?? 0 : 0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  static String _mediaKey(MediaItem item, EpisodeItem? episode) =>
      episode == null
          ? '${item.kind.name}:${item.id}'
          : '${item.kind.name}:${item.id}:${episode.season}:${episode.episode}';

  static void clearPreparedCache() => _preparedCache.clear();
}

class _VideoProbe {
  const _VideoProbe({this.fileName, this.size, this.hash});

  final String? fileName;
  final int? size;
  final String? hash;
}

class _RangeRead {
  const _RangeRead({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bytes;
}

String _normalizeCue(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll(RegExp(r"[^a-z0-9\s'’-]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

class AiSubtitleException implements Exception {
  const AiSubtitleException(this.message, {this.rateLimited = false});

  final String message;
  final bool rateLimited;

  @override
  String toString() => message;
}
