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
  });

  final String key;
  final String title;
  final String sourceUrl;
  final List<AiSubtitleCue> cues;

  int get translatedCount => cues.where((cue) => cue.translation?.isNotEmpty == true).length;

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
    EpisodeItem? episode,
    void Function(String message)? onStatus,
  }) {
    final key = _mediaKey(item, episode);
    final cached = _preparedCache[key];
    if (cached != null && cached.translatedCount >= math.min(48, cached.cues.length)) {
      return Future<AiPreparedSubtitle?>.value(cached);
    }
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _prepare(
          key: key,
          item: item,
          episode: episode,
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

    onStatus?.call('Finding a synced English subtitle…');
    final suffix = item.kind == MediaKind.series && episode != null
        ? '$imdbId:${episode.season}:${episode.episode}'
        : imdbId;
    final type = item.kind == MediaKind.movie ? 'movie' : 'series';
    final endpoint = Uri.parse(
      'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix.json',
    );
    final response = await http.get(endpoint).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AiSubtitleException('Could not load subtitle candidates.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    final entries = decoded is Map ? decoded['subtitles'] : null;
    if (entries is! List) {
      throw const AiSubtitleException('No compatible subtitle list was returned.');
    }

    final candidates = entries
        .whereType<Map>()
        .where((entry) {
          final lang = (entry['lang'] ?? entry['language'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          return lang == 'eng' ||
              lang == 'en' ||
              lang.startsWith('en-') ||
              lang.contains('english');
        })
        .map((entry) => entry['url']?.toString().trim() ?? '')
        .where((url) => url.startsWith('http'))
        .toList(growable: false);

    if (candidates.isEmpty) {
      throw const AiSubtitleException('No English text subtitle was found.');
    }

    List<AiSubtitleCue>? cues;
    String? sourceUrl;
    Object? lastError;
    for (final url in candidates.take(5)) {
      try {
        onStatus?.call('Downloading subtitle for Sinhala preparation…');
        final text = await _downloadSubtitle(url);
        final parsed = _parseSubtitle(text);
        if (parsed.length >= 8) {
          cues = parsed;
          sourceUrl = url;
          break;
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (cues == null || sourceUrl == null) {
      throw AiSubtitleException(
        lastError == null
            ? 'Could not read an English text subtitle.'
            : 'Could not prepare the subtitle source.',
      );
    }

    final prepared = AiPreparedSubtitle(
      key: key,
      title: episode == null ? item.title : '${item.title} ${episode.label}',
      sourceUrl: sourceUrl,
      cues: cues,
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
    final response = await Supabase.instance.client.functions.invoke(
      'translate-subtitle-si',
      body: <String, dynamic>{
        'title': prepared.title,
        'segments': slice.map((cue) => cue.source).toList(growable: false),
      },
    );
    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      if (response.status == 429 || (data is Map && data['error'] == 'rate_limited')) {
        throw const AiSubtitleException(
          'AI Sinhala subtitle limit reached.',
          rateLimited: true,
        );
      }
      throw const AiSubtitleException('Could not translate subtitle buffer.');
    }
    final data = response.data;
    final raw = data is Map ? data['translations'] : null;
    if (raw is! List || raw.length != slice.length) {
      throw const AiSubtitleException('AI subtitle buffer was incomplete.');
    }
    for (var i = 0; i < slice.length; i++) {
      final value = raw[i]?.toString().trim() ?? '';
      if (value.isNotEmpty) slice[i].translation = value;
    }
  }

  static Future<String> _downloadSubtitle(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AiSubtitleException('Subtitle download failed.');
    }
    var bytes = response.bodyBytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = gzip.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static List<AiSubtitleCue> _parseSubtitle(String input) {
    var text = input.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
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
        milliseconds = int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
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

  static String _mediaKey(MediaItem item, EpisodeItem? episode) => episode == null
      ? '${item.kind.name}:${item.id}'
      : '${item.kind.name}:${item.id}:${episode.season}:${episode.episode}';

  static void clearPreparedCache() => _preparedCache.clear();
}

class AiSubtitleException implements Exception {
  const AiSubtitleException(this.message, {this.rateLimited = false});

  final String message;
  final bool rateLimited;

  @override
  String toString() => message;
}
