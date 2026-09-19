import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/media_item.dart';
import 'online_subtitle_service.dart';

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

  int cueIndexNear(Duration position) {
    if (cues.isEmpty) return -1;
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
        return mid;
      }
    }
    if (low >= cues.length) return cues.length - 1;
    return low.clamp(0, cues.length - 1).toInt();
  }

  bool isTranslatedAt(int index) =>
      index >= 0 &&
      index < cues.length &&
      cues[index].translation?.trim().isNotEmpty == true;

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

  ({int index, int count})? matchSourceCueRange(
    String raw, {
    int previousIndex = -1,
  }) {
    final target = _normalizeCue(raw);
    if (target.isEmpty || cues.isEmpty) return null;

    final localStart =
        previousIndex >= 0 ? math.max(0, previousIndex - 3) : 0;
    final localEnd = previousIndex >= 0
        ? math.min(cues.length, previousIndex + 180)
        : math.min(cues.length, 520);

    ({int index, int count, double score})? best;

    for (var i = localStart; i < localEnd; i++) {
      for (var count = 1; count <= 3 && i + count <= localEnd; count++) {
        final combined = _normalizeCue(
          cues
              .sublist(i, i + count)
              .map((cue) => cue.source)
              .join(' '),
        );
        if (combined == target) {
          return (index: i, count: count);
        }
        final score = _cueTextSimilarity(target, combined);
        if (best == null || score > best.score) {
          best = (index: i, count: count, score: score);
        }
      }
    }

    final wordCount =
        target.split(' ').where((value) => value.isNotEmpty).length;
    final threshold = wordCount >= 5 ? .60 : .70;
    if (best != null && best.score >= threshold) {
      return (index: best.index, count: best.count);
    }

    // A seek can jump outside the local sequence window. Global recovery is
    // exact-only, including 2–3 adjacent candidate cues, to avoid attaching a
    // common repeated line to the wrong point in the episode.
    if (previousIndex >= 0) {
      for (var i = 0; i < cues.length; i++) {
        for (var count = 1; count <= 3 && i + count <= cues.length; count++) {
          final combined = _normalizeCue(
            cues
                .sublist(i, i + count)
                .map((cue) => cue.source)
                .join(' '),
          );
          if (combined == target) {
            return (index: i, count: count);
          }
        }
      }
    }
    return null;
  }

  int matchSourceCueIndex(
    String raw, {
    int previousIndex = -1,
  }) {
    final match = matchSourceCueRange(raw, previousIndex: previousIndex);
    return match?.index ?? -1;
  }

  AiSubtitleCue? matchSourceCue(String raw) {
    final match = matchSourceCueRange(raw);
    return match == null ? null : cues[match.index];
  }

}

class AiNativeCueSample {
  const AiNativeCueSample({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

class _SubtitleCalibration {
  const _SubtitleCalibration({
    required this.candidate,
    required this.cues,
    required this.scale,
    required this.offsetMs,
    required this.matches,
    required this.medianResidualMs,
    required this.score,
  });

  final OnlineSubtitleResult candidate;
  final List<AiSubtitleCue> cues;
  final double scale;
  final double offsetMs;
  final int matches;
  final double medianResidualMs;
  final double score;
}

class AiGeneratedSubtitleFile {
  const AiGeneratedSubtitleFile({
    required this.path,
    required this.source,
    required this.label,
    required this.cacheHit,
  });

  final String path;
  final String source;
  final String label;
  final bool cacheHit;
}

class _LocalP2pFileIdentity {
  const _LocalP2pFileIdentity({
    required this.infoHash,
    required this.fileIndex,
  });

  final String infoHash;
  final int fileIndex;
}

class _EmbeddedSubtitleSource {
  const _EmbeddedSubtitleSource({
    required this.content,
    required this.identity,
    required this.label,
  });

  final String content;
  final String identity;
  final String label;
}

class AiSinhalaSubtitleService {
  AiSinhalaSubtitleService._();

  static final Map<String, AiPreparedSubtitle> _preparedCache =
      <String, AiPreparedSubtitle>{};
  static final Map<String, Future<AiPreparedSubtitle?>> _inFlight =
      <String, Future<AiPreparedSubtitle?>>{};
  static final Map<String, Future<void>> _translationWork =
      <String, Future<void>>{};
  static final Map<String, String> _liveCueCache = <String, String>{};

  // This is Supabase's public legacy anon key, not a secret. Orvix uses it only
  // when there is no signed-in user so the JWT-protected Edge Function can
  // serve guest/free-streaming users without forcing an Orvix account.
  static const _guestFunctionJwt =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwanVpc3hvZndxeGhibm5zeXpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2NTMxMDIsImV4cCI6MjEwNTIyOTEwMn0.cBlT4tgZW_WMlkmOagFo7PhtFXwS7ib9Yw9BECCrNew';
  static final Uri _translationEndpoint = Uri.parse(
    'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/translate-subtitle-si',
  );
  static final Uri _openSubtitlesExactEndpoint = Uri.parse(
    'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/opensubtitles-exact',
  );

  static bool get canTranslate => true;

  static bool isLikelySinhalaTranslation(
    String source,
    String translation,
  ) {
    final translated = translation.trim();
    if (translated.isEmpty) return false;

    final sourceWords = RegExp(r"[A-Za-z][A-Za-z'’-]*")
        .allMatches(source)
        .map((match) => match.group(0) ?? '')
        .where((word) => word.isNotEmpty)
        .toList(growable: false);

    // One/two-word cues are frequently names, interjections, acronyms or
    // intentionally untranslated terms. Longer English dialogue must contain
    // Sinhala script or it is not a usable Sinhala subtitle result.
    if (sourceWords.length < 3) return true;
    return RegExp(r'[\u0D80-\u0DFF]').hasMatch(translated);
  }

  static const _nativeCalibrationCacheVersion = 'native-cal-v1';

  static Future<AiPreparedSubtitle?> prepareTrustedTranscriptForNativeClock({
    required String title,
    required String videoUrl,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    void Function(String message)? onStatus,
  }) async {
    Future<AiPreparedSubtitle> prepareComplete({
      required String cacheKey,
      required String sourceUrl,
      required String sourceMatch,
      required List<AiSubtitleCue> cues,
      required String readyMessage,
    }) async {
      final cached = _preparedCache[cacheKey];
      if (cached != null && cached.translatedCount == cached.cues.length) {
        onStatus?.call('Cached exact transcript is ready.');
        return cached;
      }

      final prepared = AiPreparedSubtitle(
        key: cacheKey,
        title: title,
        sourceUrl: sourceUrl,
        cues: cues,
        sourceMatch: sourceMatch,
      );
      _preparedCache[cacheKey] = prepared;

      await _translateEntireSubtitle(
        prepared,
        onProgress: (done, total) {
          final percent =
              total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
          onStatus?.call(
            'Translating complete Sinhala transcript… $percent% ($done/$total)',
          );
        },
      );
      if (prepared.translatedCount != prepared.cues.length) {
        throw const AiSubtitleException(
          'The complete Sinhala transcript did not finish translating.',
        );
      }
      onStatus?.call(readyMessage);
      return prepared;
    }

    // Best source: the English subtitle file embedded in the exact P2P video.
    // This avoids OpenSubtitles selection entirely when stream-server can
    // expose the selected file's subtitle track.
    try {
      onStatus?.call(
        'Checking the selected video for its own English subtitle transcript…',
      );
      final embedded = await _fetchEmbeddedEnglishSubtitle(videoUrl);
      if (embedded != null) {
        final cues = _parseSubtitle(embedded.content);
        if (cues.length >= 8) {
          return prepareComplete(
            cacheKey: 'native-clock-v2|embedded|${embedded.identity}',
            sourceUrl: embedded.identity,
            sourceMatch: 'embedded-native-track',
            cues: cues,
            readyMessage:
                'Video-embedded English transcript translated. Native cue timing remains authoritative.',
          );
        }
      }
    } catch (_) {
      // Continue to exact-file OpenSubtitles lookup.
    }

    // Second best source: identify the actual video file by canonical
    // OpenSubtitles hash + exact byte size. We use that only to choose the
    // transcript text. Runtime timestamps still come exclusively from the
    // selected video's native English subtitle cue events.
    _VideoProbe? probe;
    try {
      onStatus?.call('Fingerprinting the actual selected video file…');
      probe = await _probeVideo(
        videoUrl,
        fallbackFileName: releaseHint,
        fallbackSize: expectedSizeBytes,
        expectedVideoHash: expectedVideoHash,
      );
    } catch (_) {
      probe = null;
    }

    final hash = probe?.hash;
    final size = probe?.size;
    if (hash != null && size != null && size > 0) {
      try {
        onStatus?.call(
          'Checking OpenSubtitles REST for this exact video fingerprint…',
        );
        final exactText = await _fetchExactRestSubtitle(
          movieHash: hash,
          movieByteSize: size,
        );
        if (exactText != null) {
          final cues = _parseSubtitle(exactText);
          if (cues.length >= 8) {
            return prepareComplete(
              cacheKey: 'native-clock-v2|rest-exact|$hash|$size',
              sourceUrl: 'opensubtitles-rest-v1://moviehash/$hash',
              sourceMatch: 'rest-exact-transcript-native-clock',
              cues: cues,
              readyMessage:
                  'Exact-file English transcript translated. Native cue timing remains authoritative.',
            );
          }
        }
      } catch (_) {
        // Exact lookup is an optimization/identity source. The caller may
        // still attempt a text-matched fallback without trusting online timing.
      }
    }

    return null;
  }

  static Future<AiPreparedSubtitle>
      prepareTranslatedTranscriptForNativeTiming({
    required String title,
    required String videoIdentity,
    required List<AiNativeCueSample> nativeSamples,
    required List<OnlineSubtitleResult> candidates,
    void Function(String message)? onStatus,
  }) async {
    final usableSamples = nativeSamples
        .where((sample) => _normalizeCue(sample.text).split(' ').length >= 3)
        .toList(growable: false);
    if (usableSamples.length < 3) {
      throw const AiSubtitleException(
        'Could not collect enough dialogue from the video’s synced English track.',
      );
    }

    final filteredEnglish = candidates
        .where(
          (entry) =>
              OnlineSubtitleService.normalizeLanguage(entry.language) == 'eng',
        )
        .where((entry) {
          final label = entry.label.toLowerCase();
          return !label.contains('forced') &&
              !label.contains('commentary') &&
              !label.contains('foreign only') &&
              !label.contains('signs');
        })
        .toList(growable: false);

    // Preserve provider diversity. A long OpenSubtitles list must not crowd
    // SubDL out of the bounded dialogue-matching pass.
    final primary = filteredEnglish
        .where((entry) => entry.provider.toLowerCase() != 'subdl')
        .take(18)
        .toList(growable: false);
    final subDl = filteredEnglish
        .where((entry) => entry.provider.toLowerCase() == 'subdl')
        .take(12)
        .toList(growable: false);
    final englishCandidates = <OnlineSubtitleResult>[];
    final rounds = math.max(primary.length, subDl.length);
    for (var i = 0; i < rounds; i++) {
      if (i < primary.length) englishCandidates.add(primary[i]);
      if (i < subDl.length) englishCandidates.add(subDl[i]);
    }

    if (englishCandidates.isEmpty) {
      throw const AiSubtitleException(
        'No configured subtitle provider returned an English transcript for this episode.',
      );
    }

    OnlineSubtitleResult? selectedCandidate;
    List<AiSubtitleCue>? selectedCues;
    var selectedMatches = -1;
    var selectedSimilarity = -1.0;

    for (var candidateIndex = 0;
        candidateIndex < englishCandidates.length;
        candidateIndex++) {
      final candidate = englishCandidates[candidateIndex];
      onStatus?.call(
        'Matching dialogue against English transcripts… ${candidateIndex + 1}/${englishCandidates.length}',
      );
      try {
        final text = await _downloadSubtitle(candidate.url);
        final cues = _parseSubtitle(text);
        if (cues.length < 8) continue;

        var searchFrom = 0;
        var matches = 0;
        var similarityTotal = 0.0;
        for (final sample in usableSamples) {
          final target = _normalizeCue(sample.text);
          var bestIndex = -1;
          var bestCount = 1;
          var bestSimilarity = 0.0;
          final upper = math.min(cues.length, searchFrom + 520);
          for (var i = searchFrom; i < upper; i++) {
            for (var count = 1;
                count <= 3 && i + count <= upper;
                count++) {
              final combined = _normalizeCue(
                cues
                    .sublist(i, i + count)
                    .map((cue) => cue.source)
                    .join(' '),
              );
              final similarity = _cueTextSimilarity(target, combined);
              if (similarity > bestSimilarity) {
                bestSimilarity = similarity;
                bestIndex = i;
                bestCount = count;
              }
              if (similarity >= .985) break;
            }
            if (bestSimilarity >= .985) break;
          }
          if (bestIndex < 0 || bestSimilarity < .60) continue;
          matches++;
          similarityTotal += bestSimilarity;
          searchFrom = bestIndex + bestCount;
        }

        if (matches > selectedMatches ||
            (matches == selectedMatches &&
                similarityTotal > selectedSimilarity)) {
          selectedCandidate = candidate;
          selectedCues = cues;
          selectedMatches = matches;
          selectedSimilarity = similarityTotal;
        }

        if (matches >= math.min(6, usableSamples.length) &&
            similarityTotal / matches >= .86) {
          break;
        }
      } catch (_) {
        continue;
      }
    }

    final candidate = selectedCandidate;
    final cues = selectedCues;
    if (candidate == null || cues == null || selectedMatches < 3) {
      throw const AiSubtitleException(
        'No English transcript matched the dialogue from the synced video subtitle track.',
      );
    }

    final cacheKey =
        'native-text|$videoIdentity|${candidate.id}|$selectedMatches|native-text-v1';
    final cached = _preparedCache[cacheKey];
    if (cached != null &&
        cached.translatedCount == cached.cues.length) {
      onStatus?.call('Cached native-timed Sinhala transcript is ready.');
      return cached;
    }

    final prepared = AiPreparedSubtitle(
      key: cacheKey,
      title: title,
      sourceUrl: candidate.url,
      cues: cues,
      sourceMatch: 'native-cue-text-oracle',
    );
    _preparedCache[cacheKey] = prepared;

    onStatus?.call(
      'Dialogue match verified ($selectedMatches cues). Translating the complete transcript before playback…',
    );
    await _translateEntireSubtitle(
      prepared,
      onProgress: (done, total) {
        final percent =
            total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
        onStatus?.call(
          'Translating complete Sinhala transcript… $percent% ($done/$total)',
        );
      },
    );
    if (prepared.translatedCount != prepared.cues.length) {
      throw const AiSubtitleException(
        'The complete Sinhala transcript did not finish translating.',
      );
    }

    onStatus?.call(
      'Sinhala transcript ready. The video’s own English cues will control every subtitle timestamp.',
    );
    return prepared;
  }

  static Future<AiGeneratedSubtitleFile>
      prepareGeneratedSinhalaFromNativeCalibration({
    required String title,
    required String videoIdentity,
    required List<AiNativeCueSample> nativeSamples,
    required List<OnlineSubtitleResult> candidates,
    void Function(String message)? onStatus,
  }) async {
    final usableSamples = nativeSamples
        .where((sample) => _normalizeCue(sample.text).split(' ').length >= 3)
        .toList(growable: false);
    if (usableSamples.length < 3) {
      throw const AiSubtitleException(
        'Could not collect enough English subtitle cues from the selected video track.',
      );
    }

    final englishCandidates = candidates
        .where(
          (entry) =>
              OnlineSubtitleService.normalizeLanguage(entry.language) == 'eng',
        )
        .where((entry) {
          final label = entry.label.toLowerCase();
          return !label.contains('forced') &&
              !label.contains('commentary') &&
              !label.contains('foreign only') &&
              !label.contains('signs');
        })
        .take(18)
        .toList(growable: false);

    if (englishCandidates.isEmpty) {
      throw const AiSubtitleException(
        'OpenSubtitles did not return any full English candidates to calibrate.',
      );
    }

    _SubtitleCalibration? best;
    for (var i = 0; i < englishCandidates.length; i++) {
      final candidate = englishCandidates[i];
      onStatus?.call(
        'Matching the video’s real English timing against OpenSubtitles… ${i + 1}/${englishCandidates.length}',
      );
      try {
        final text = await _downloadSubtitle(candidate.url);
        final cues = _parseSubtitle(text);
        if (cues.length < 8) continue;
        final calibration = _calibrateAgainstNativeSamples(
          candidate: candidate,
          cues: cues,
          samples: usableSamples,
        );
        if (calibration == null) continue;
        if (best == null || calibration.score > best.score) {
          best = calibration;
        }
        if (calibration.matches >= 6 &&
            calibration.medianResidualMs <= 220) {
          break;
        }
      } catch (_) {
        continue;
      }
    }

    final selected = best;
    if (selected == null ||
        selected.matches < 3 ||
        selected.medianResidualMs > 850) {
      throw const AiSubtitleException(
        'No OpenSubtitles file matched the English subtitles actually playing in this video closely enough.',
      );
    }

    final scaleKey = selected.scale.toStringAsFixed(7);
    final offsetKey = selected.offsetMs.round();
    final cacheKey =
        'native-cal|$videoIdentity|${selected.candidate.id}|$scaleKey|$offsetKey|$_nativeCalibrationCacheVersion';
    final cached = await _cachedGeneratedFile(cacheKey);
    if (cached != null) {
      onStatus?.call('Cached native-calibrated Sinhala subtitle is ready.');
      return AiGeneratedSubtitleFile(
        path: cached.path,
        source: 'native-calibrated-opensubtitles',
        label: selected.candidate.label,
        cacheHit: true,
      );
    }

    onStatus?.call(
      'Matched ${selected.matches} real video cues (median error ${selected.medianResidualMs.round()} ms). Translating the complete aligned subtitle…',
    );
    final alignedCues = selected.cues.map((cue) {
      final startMs =
          (cue.start.inMilliseconds * selected.scale + selected.offsetMs)
              .round()
              .clamp(0, 1 << 53)
              .toInt();
      final endMs =
          (cue.end.inMilliseconds * selected.scale + selected.offsetMs)
              .round()
              .clamp(startMs + 80, 1 << 53)
              .toInt();
      return AiSubtitleCue(
        start: Duration(milliseconds: startMs),
        end: Duration(milliseconds: endMs),
        source: cue.source,
      );
    }).toList(growable: false);

    final prepared = AiPreparedSubtitle(
      key: cacheKey,
      title: title,
      sourceUrl: selected.candidate.url,
      cues: alignedCues,
      sourceMatch: 'native-track-calibrated',
    );
    await _translateEntireSubtitle(
      prepared,
      onProgress: (done, total) {
        final percent =
            total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
        onStatus?.call(
          'Translating calibrated Sinhala subtitle… $percent% ($done/$total)',
        );
      },
    );
    if (prepared.translatedCount != prepared.cues.length) {
      throw const AiSubtitleException(
        'The calibrated Sinhala subtitle did not finish translating.',
      );
    }

    final file = await _writeGeneratedSrt(cacheKey, prepared);
    onStatus?.call('Native-timed Sinhala subtitle generated and cached.');
    return AiGeneratedSubtitleFile(
      path: file.path,
      source: 'native-calibrated-opensubtitles',
      label: selected.candidate.label,
      cacheHit: false,
    );
  }

  static _SubtitleCalibration? _calibrateAgainstNativeSamples({
    required OnlineSubtitleResult candidate,
    required List<AiSubtitleCue> cues,
    required List<AiNativeCueSample> samples,
  }) {
    final pairs = <(double candidateMs, double nativeMs)>[];
    var searchFrom = 0;

    for (final sample in samples) {
      final target = _normalizeCue(sample.text);
      if (target.isEmpty) continue;

      var bestIndex = -1;
      var bestSimilarity = 0.0;
      final upper = math.min(cues.length, searchFrom + 420);
      for (var i = searchFrom; i < upper; i++) {
        final similarity =
            _cueTextSimilarity(target, _normalizeCue(cues[i].source));
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
          bestIndex = i;
        }
        if (similarity >= .985) break;
      }
      if (bestIndex < 0 || bestSimilarity < .72) continue;

      pairs.add((
        cues[bestIndex].start.inMilliseconds.toDouble(),
        sample.start.inMilliseconds.toDouble(),
      ));
      searchFrom = bestIndex + 1;
    }

    if (pairs.length < 3) return null;

    var scale = 1.0;
    var offset = 0.0;
    final sourceSpan = pairs.last.$1 - pairs.first.$1;
    final nativeSpan = pairs.last.$2 - pairs.first.$2;

    if (pairs.length >= 4 &&
        sourceSpan.abs() >= 12000 &&
        nativeSpan.abs() >= 12000) {
      var sx = 0.0;
      var sy = 0.0;
      var sxx = 0.0;
      var sxy = 0.0;
      for (final pair in pairs) {
        sx += pair.$1;
        sy += pair.$2;
        sxx += pair.$1 * pair.$1;
        sxy += pair.$1 * pair.$2;
      }
      final n = pairs.length.toDouble();
      final denominator = n * sxx - sx * sx;
      if (denominator.abs() > 1) {
        scale = (n * sxy - sx * sy) / denominator;
      }
      if (!scale.isFinite || scale < .94 || scale > 1.06) {
        scale = 1.0;
      }
    }

    final offsets = pairs
        .map((pair) => pair.$2 - pair.$1 * scale)
        .toList(growable: false)
      ..sort();
    offset = offsets[offsets.length ~/ 2];

    final residuals = pairs
        .map((pair) => (pair.$2 - (pair.$1 * scale + offset)).abs())
        .toList(growable: false)
      ..sort();
    final medianResidual = residuals[residuals.length ~/ 2];

    final score = pairs.length * 10000.0 -
        medianResidual * 8 -
        (scale - 1.0).abs() * 30000 +
        candidate.score;

    return _SubtitleCalibration(
      candidate: candidate,
      cues: cues,
      scale: scale,
      offsetMs: offset,
      matches: pairs.length,
      medianResidualMs: medianResidual,
      score: score,
    );
  }

  static double _cueTextSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;

    final aw = a.split(' ').where((word) => word.isNotEmpty).toSet();
    final bw = b.split(' ').where((word) => word.isNotEmpty).toSet();
    if (aw.isEmpty || bw.isEmpty) return 0;

    final intersection = aw.intersection(bw).length.toDouble();
    final union = aw.union(bw).length.toDouble();
    final jaccard = union == 0 ? 0.0 : intersection / union;

    final shorter = a.length < b.length ? a : b;
    final longer = a.length < b.length ? b : a;
    final containment =
        longer.contains(shorter) ? shorter.length / longer.length : 0.0;
    return math.max(jaccard, containment).toDouble();
  }


  static const _generatedSubtitleCacheVersion = 'srt-v3-exact-video';

  static Future<AiGeneratedSubtitleFile>
      prepareGeneratedSinhalaFromOnlineSubtitle({
    required String title,
    required String subtitleUrl,
    required String subtitleIdentity,
    required String subtitleLabel,
    void Function(String message)? onStatus,
  }) async {
    final cleanUrl = subtitleUrl.trim();
    if (!cleanUrl.startsWith(RegExp(r'https?://'))) {
      throw const AiSubtitleException(
        'The selected English subtitle has no downloadable URL.',
      );
    }

    final cacheKey =
        'online|$subtitleIdentity|$cleanUrl|$_generatedSubtitleCacheVersion';
    final cached = await _cachedGeneratedFile(cacheKey);
    if (cached != null) {
      onStatus?.call('Cached Sinhala subtitle file is ready.');
      return AiGeneratedSubtitleFile(
        path: cached.path,
        source: 'opensubtitles-online',
        label: subtitleLabel,
        cacheHit: true,
      );
    }

    onStatus?.call('Downloading the selected English subtitle…');
    final text = await _downloadSubtitle(cleanUrl);
    final cues = _parseSubtitle(text);
    if (cues.length < 8) {
      throw const AiSubtitleException(
        'The selected English subtitle could not be parsed safely.',
      );
    }

    final prepared = AiPreparedSubtitle(
      key: cacheKey,
      title: title,
      sourceUrl: cleanUrl,
      cues: cues,
      sourceMatch: 'user-or-ranked-online-subtitle',
    );

    onStatus?.call(
      'English subtitle loaded. Translating the complete file to Sinhala…',
    );
    await _translateEntireSubtitle(
      prepared,
      onProgress: (done, total) {
        final percent =
            total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
        onStatus?.call(
          'Translating complete Sinhala subtitle… $percent% ($done/$total)',
        );
      },
    );

    if (prepared.translatedCount != prepared.cues.length) {
      throw const AiSubtitleException(
        'The complete Sinhala subtitle did not finish translating.',
      );
    }

    final file = await _writeGeneratedSrt(cacheKey, prepared);
    onStatus?.call('Sinhala subtitle file generated and cached.');
    return AiGeneratedSubtitleFile(
      path: file.path,
      source: 'opensubtitles-online',
      label: subtitleLabel,
      cacheHit: false,
    );
  }

  static Future<AiGeneratedSubtitleFile> prepareGeneratedSinhalaFile({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    void Function(String message)? onStatus,
  }) async {
    final title =
        episode == null ? item.title : '${item.title} ${episode.label}';

    onStatus?.call(
      'Reading the actual video file fingerprint (first + last 64 KiB)…',
    );
    final probe = await _probeVideo(
      videoUrl,
      fallbackFileName: releaseHint,
      fallbackSize: expectedSizeBytes,
      expectedVideoHash: expectedVideoHash,
    );

    if (probe.hash == null || probe.size == null || probe.size! <= 0) {
      throw const AiSubtitleException(
        'Orvix could not verify the actual video file hash and byte size. Automatic AI Sinhala was not started.',
      );
    }

    final exactKey =
        'exact-video|${probe.hash}|${probe.size}|$_generatedSubtitleCacheVersion';
    final cached = await _cachedGeneratedFile(exactKey);
    if (cached != null) {
      onStatus?.call('Cached exact-file Sinhala subtitle is ready.');
      return AiGeneratedSubtitleFile(
        path: cached.path,
        source: 'opensubtitles-rest-exact',
        label: 'Exact video-file match',
        cacheHit: true,
      );
    }

    onStatus?.call(
      'Searching OpenSubtitles REST with the actual movie hash + byte size…',
    );
    final exactText = await _fetchExactRestSubtitle(
      movieHash: probe.hash!,
      movieByteSize: probe.size!,
    );
    if (exactText == null) {
      throw const AiSubtitleException(
        'OpenSubtitles returned no subtitle for this exact video file. Automatic AI Sinhala will not guess another release.',
      );
    }

    final cues = _parseSubtitle(exactText);
    if (cues.length < 8) {
      throw const AiSubtitleException(
        'The exact-file English subtitle could not be parsed safely.',
      );
    }

    final prepared = AiPreparedSubtitle(
      key: exactKey,
      title: title,
      sourceUrl: 'opensubtitles-rest-v1://moviehash/${probe.hash}',
      cues: cues,
      sourceMatch: 'rest-moviehash+moviebytesize-generated-srt',
    );

    onStatus?.call(
      'Exact timing verified. Translating the complete subtitle to Sinhala…',
    );
    await _translateEntireSubtitle(
      prepared,
      onProgress: (done, total) {
        final percent =
            total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
        onStatus?.call(
          'Translating complete Sinhala subtitle… $percent% ($done/$total)',
        );
      },
    );
    if (prepared.translatedCount != prepared.cues.length) {
      throw const AiSubtitleException(
        'The complete Sinhala subtitle did not finish translating.',
      );
    }

    final file = await _writeGeneratedSrt(exactKey, prepared);
    onStatus?.call('Exact-file Sinhala subtitle generated and cached.');
    return AiGeneratedSubtitleFile(
      path: file.path,
      source: 'opensubtitles-rest-exact',
      label: 'Exact video-file match',
      cacheHit: false,
    );
  }

  static Future<_EmbeddedSubtitleSource?> _fetchEmbeddedEnglishSubtitle(
    String rawVideoUrl,
  ) async {
    final videoUri = Uri.tryParse(rawVideoUrl);
    if (videoUri == null ||
        !(videoUri.host == '127.0.0.1' || videoUri.host == 'localhost') ||
        videoUri.port != 11470) {
      return null;
    }

    // stream-server v0.1.8 extracts embedded subtitles from the largest
    // video file in the torrent. Only use that extractor when the selected
    // playback file is the same file, otherwise a season pack could translate
    // subtitles from a different episode.
    final identity = _parseLocalP2pFileIdentity(videoUri);
    if (identity == null) return null;
    final extractorFileIndex =
        await _guessStreamServerPrimaryVideoIndex(videoUri, identity.infoHash);
    if (extractorFileIndex == null ||
        extractorFileIndex != identity.fileIndex) {
      return null;
    }

    final tracksUri = videoUri.replace(
      path: '/subtitlesTracks',
      queryParameters: <String, String>{'subsUrl': videoUri.toString()},
      fragment: '',
    );

    dynamic decoded;
    try {
      final response = await http
          .get(tracksUri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (_) {
      return null;
    }

    final raw = decoded is Map ? decoded['result'] : null;
    if (raw is! List || raw.isEmpty) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final url = map['url']?.toString().trim() ?? '';
      final label = map['label']?.toString().trim() ?? '';
      if (url.isEmpty || label.isEmpty) continue;
      final score = _englishTrackScore(label);
      if (score <= 0) continue;
      map['_score'] = score;
      candidates.add(map);
    }
    candidates.sort(
      (a, b) => (b['_score'] as int).compareTo(a['_score'] as int),
    );

    for (final candidate in candidates) {
      final relativeUrl = candidate['url']?.toString() ?? '';
      final label = candidate['label']?.toString() ?? 'English';
      final subtitleUri = videoUri.resolve(relativeUrl);
      try {
        final response = await http
            .get(subtitleUri)
            .timeout(const Duration(seconds: 35));
        if (response.statusCode < 200 || response.statusCode >= 300) continue;
        final content =
            utf8.decode(response.bodyBytes, allowMalformed: true).trim();
        if (content.isEmpty || _parseSubtitle(content).length < 8) continue;
        return _EmbeddedSubtitleSource(
          content: content,
          identity: subtitleUri.toString(),
          label: label,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static _LocalP2pFileIdentity? _parseLocalP2pFileIdentity(Uri uri) {
    final parts = uri.pathSegments;
    for (var i = 0; i + 1 < parts.length; i++) {
      final hash = parts[i].toLowerCase();
      if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(hash)) continue;
      final index = int.tryParse(parts[i + 1]);
      if (index == null || index < 0) return null;
      return _LocalP2pFileIdentity(infoHash: hash, fileIndex: index);
    }
    return null;
  }

  static Future<int?> _guessStreamServerPrimaryVideoIndex(
    Uri videoUri,
    String infoHash,
  ) async {
    final endpoint = videoUri.replace(
      path: '/$infoHash/create',
      query: '',
      fragment: '',
    );
    try {
      final response = await http
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'stream': <String, dynamic>{'infoHash': infoHash},
              'guessFileIdx': true,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is! Map) return null;
      final raw = decoded['guessedFileIdx'];
      return raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  static int _englishTrackScore(String rawLabel) {
    final label = rawLabel.toLowerCase();
    var score = 0;
    if (label.contains('english')) score += 120;
    if (RegExp(r'(^|[^a-z])eng([^a-z]|$)').hasMatch(label)) score += 110;
    if (RegExp(r'(^|[^a-z])en([^a-z]|$)').hasMatch(label)) score += 80;
    if (label.contains('.en.') ||
        label.contains('_en.') ||
        label.contains('-en.')) {
      score += 80;
    }
    if (label.contains('commentary')) score -= 160;
    if (label.contains('forced') || label.contains('foreign')) score -= 90;
    if (label.contains('sign') || label.contains('song')) score -= 80;
    if (label.contains('sdh') || label.contains('hearing')) score -= 20;
    return score;
  }

  static Future<File?> _cachedGeneratedFile(String cacheKey) async {
    try {
      final file = await _generatedCacheFile(cacheKey);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length < 128) return null;
      final head = await file.openRead(0, math.min(length, 4096)).transform(utf8.decoder).join();
      if (!head.contains('-->')) return null;
      return file;
    } catch (_) {
      return null;
    }
  }

  static Future<File> _generatedCacheFile(String cacheKey) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}subtitle_cache${Platform.pathSeparator}si',
    );
    await directory.create(recursive: true);
    final digest = sha256.convert(utf8.encode(cacheKey)).toString();
    return File(
      '${directory.path}${Platform.pathSeparator}orvix_si_$digest.srt',
    );
  }

  static Future<File> _writeGeneratedSrt(
    String cacheKey,
    AiPreparedSubtitle prepared,
  ) async {
    final file = await _generatedCacheFile(cacheKey);
    final buffer = StringBuffer();
    for (var i = 0; i < prepared.cues.length; i++) {
      final cue = prepared.cues[i];
      final translated = cue.translation?.trim() ?? '';
      if (translated.isEmpty) {
        throw const AiSubtitleException(
          'A translated subtitle cue was unexpectedly empty.',
        );
      }
      buffer
        ..writeln(i + 1)
        ..writeln(
          '${_formatSrtTimestamp(cue.start)} --> ${_formatSrtTimestamp(cue.end)}',
        )
        ..writeln(translated)
        ..writeln();
    }
    await file.writeAsString(
      buffer.toString(),
      encoding: utf8,
      flush: true,
    );
    return file;
  }

  static String _formatSrtTimestamp(Duration value) {
    final totalMs = value.inMilliseconds < 0 ? 0 : value.inMilliseconds;
    final hours = totalMs ~/ 3600000;
    final minutes = (totalMs % 3600000) ~/ 60000;
    final seconds = (totalMs % 60000) ~/ 1000;
    final millis = totalMs % 1000;
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)},${three(millis)}';
  }

  static Future<AiPreparedSubtitle?> prepareExactFileFully({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    void Function(String message)? onStatus,
  }) async {
    onStatus?.call('Computing the exact video fingerprint…');
    final probe = await _probeVideo(
      videoUrl,
      fallbackFileName: releaseHint,
      fallbackSize: expectedSizeBytes,
      expectedVideoHash: expectedVideoHash,
    );

    if (probe.hash == null || probe.size == null || probe.size! <= 0) {
      throw const AiSubtitleException(
        'This source does not expose an exact OpenSubtitles file hash and size.',
      );
    }

    final key =
        '${_mediaKey(item, episode)}:strict:${probe.hash}:${probe.size}';
    final cached = _preparedCache[key];
    if (cached != null && cached.translatedCount == cached.cues.length) {
      onStatus?.call('Exact-file Sinhala subtitle is ready from cache.');
      return cached;
    }

    return _inFlight.putIfAbsent(key, () async {
      try {
        onStatus?.call('Finding the subtitle for this exact video file…');
        final exactText = await _fetchExactRestSubtitle(
          movieHash: probe.hash!,
          movieByteSize: probe.size!,
        );
        if (exactText == null) {
          throw const AiSubtitleException(
            'OpenSubtitles has no exact-file English subtitle for this source.',
          );
        }

        final cues = _parseSubtitle(exactText);
        if (cues.length < 8) {
          throw const AiSubtitleException(
            'The exact-file subtitle could not be parsed safely.',
          );
        }

        final prepared = AiPreparedSubtitle(
          key: key,
          title:
              episode == null ? item.title : '${item.title} ${episode.label}',
          sourceUrl: 'opensubtitles-rest-v1://moviehash/${probe.hash}',
          cues: cues,
          sourceMatch: 'rest-moviehash-full',
        );
        _preparedCache[key] = prepared;

        onStatus?.call(
          'Exact timing verified. Translating the complete subtitle before playback…',
        );
        await _translateEntireSubtitle(
          prepared,
          onProgress: (done, total) {
            final percent =
                total <= 0 ? 100 : ((done * 100) / total).round().clamp(0, 100);
            onStatus?.call(
              'Translating complete Sinhala subtitle… $percent% ($done/$total)',
            );
          },
        );

        if (prepared.translatedCount != prepared.cues.length) {
          throw const AiSubtitleException(
            'The complete Sinhala subtitle did not finish translating.',
          );
        }

        onStatus?.call(
          'Complete exact-file Sinhala subtitle ready — starting playback.',
        );
        return prepared;
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  static Future<void> _translateEntireSubtitle(
    AiPreparedSubtitle prepared, {
    void Function(int done, int total)? onProgress,
  }) async {
    final missing = <int>[
      for (var i = 0; i < prepared.cues.length; i++)
        if (!prepared.isTranslatedAt(i)) i,
    ];
    if (missing.isEmpty) {
      onProgress?.call(prepared.cues.length, prepared.cues.length);
      return;
    }

    const batchSize = 60;
    for (var cursor = 0; cursor < missing.length; cursor += batchSize) {
      final end = math.min(cursor + batchSize, missing.length);
      await _translateIndices(prepared, missing.sublist(cursor, end));
      onProgress?.call(
        prepared.translatedCount,
        prepared.cues.length,
      );
    }
  }

  static Future<AiPreparedSubtitle?> prepareBuffered({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    void Function(String message)? onStatus,
  }) async {
    final probe = await _probeVideo(
      videoUrl,
      fallbackFileName: releaseHint,
      fallbackSize: expectedSizeBytes,
      expectedVideoHash: expectedVideoHash,
    );
    final identity = probe.hash ??
        '${probe.size ?? 0}:${probe.fileName ?? Uri.tryParse(videoUrl)?.pathSegments.lastOrNull ?? 'unknown'}';
    final key = '${_mediaKey(item, episode)}:$identity';
    final cached = _preparedCache[key];
    if (cached != null &&
        cached.translatedCount >= math.min(96, cached.cues.length)) {
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

  static Future<AiPreparedSubtitle?> prepareForEmbeddedTiming({
    required MediaItem item,
    EpisodeItem? episode,
    void Function(String message)? onStatus,
  }) async {
    final key = '${_mediaKey(item, episode)}:embedded-text-timing';
    final cached = _preparedCache[key];
    if (cached != null &&
        cached.translatedCount >= math.min(96, cached.cues.length)) {
      return cached;
    }
    return _inFlight.putIfAbsent(key, () async {
      try {
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
        final endpoint = Uri.parse(
          'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix.json',
        );

        onStatus?.call(
          'Using the video embedded English track as the timing source…',
        );
        final candidates = await _subtitleCandidates(
          endpoint,
          item: item,
        );
        if (candidates.isEmpty) {
          throw const AiSubtitleException(
            'No English transcript was found for embedded subtitle timing.',
          );
        }

        List<AiSubtitleCue>? cues;
        String? sourceUrl;
        Object? lastError;
        for (final url in candidates.take(10)) {
          try {
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
                ? 'No usable English transcript was found.'
                : 'Could not prepare the English transcript.',
          );
        }

        final prepared = AiPreparedSubtitle(
          key: key,
          title:
              episode == null ? item.title : '${item.title} ${episode.label}',
          sourceUrl: sourceUrl,
          cues: cues,
          sourceMatch: 'embedded-text-timing',
        );
        _preparedCache[key] = prepared;

        final firstEnd = math.min(96, cues.length);
        onStatus?.call(
          'Translating Sinhala ahead while keeping embedded video timing…',
        );
        await _translateRange(prepared, 0, firstEnd);
        onStatus?.call('Embedded-timed Sinhala subtitles ready.');
        return prepared;
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
    final imdbId = item.id.trim();
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) {
      throw const AiSubtitleException(
        'This title does not have a compatible IMDb subtitle id.',
      );
    }

    final title = episode == null ? item.title : '${item.title} ${episode.label}';
    final suffix = item.kind == MediaKind.series && episode != null
        ? '$imdbId:${episode.season}:${episode.episode}'
        : imdbId;
    final type = item.kind == MediaKind.movie ? 'movie' : 'series';

    // Strongest downloadable timing source: OpenSubtitles REST v1 confirms
    // moviehash_match=true for the exact file hash + exact byte size. The API
    // key stays server-side in the Supabase Edge Function and is never shipped
    // in Orvix.
    if (probe.hash != null && probe.size != null && probe.size! > 0) {
      onStatus?.call('Checking an exact OpenSubtitles file-hash match…');
      final exactText = await _fetchExactRestSubtitle(
        movieHash: probe.hash!,
        movieByteSize: probe.size!,
      );
      if (exactText != null) {
        final exactCues = _parseSubtitle(exactText);
        if (exactCues.length >= 8) {
          final prepared = AiPreparedSubtitle(
            key: key,
            title: title,
            sourceUrl: 'opensubtitles-rest-v1://moviehash/${probe.hash}',
            cues: exactCues,
            sourceMatch: 'rest-moviehash',
          );
          _preparedCache[key] = prepared;
          final firstEnd = math.min(96, exactCues.length);
          onStatus?.call('Exact-file timing verified — translating Sinhala…');
          await _translateRange(prepared, 0, firstEnd);
          onStatus?.call('Exact-timed Sinhala subtitles ready.');
          return prepared;
        }
      }
    }

    // Zero-config fallback: OpenSubtitles v3. Exact-hash responses must carry
    // explicit hash-match evidence (m=h / hashMatch / moviehash_match). If not,
    // do not pretend they are exact. A filename+size release match may then be
    // used, but only when release-specific tokens are present.
    final endpoints = <({Uri uri, String match})>[];
    if (probe.hash != null) {
      final exactExtras = <String>[
        'videoHash=${Uri.encodeComponent(probe.hash!)}',
        if (probe.size != null && probe.size! > 0) 'videoSize=${probe.size}',
        if (probe.fileName?.isNotEmpty == true)
          'filename=${Uri.encodeComponent(probe.fileName!)}',
      ];
      endpoints.add((
        uri: Uri.parse(
          'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix/${exactExtras.join('&')}.json',
        ),
        match: 'video-hash',
      ));
    }
    if (probe.size != null &&
        probe.size! > 0 &&
        probe.fileName?.isNotEmpty == true) {
      final releaseExtras = <String>[
        'videoSize=${probe.size}',
        'filename=${Uri.encodeComponent(probe.fileName!)}',
      ];
      endpoints.add((
        uri: Uri.parse(
          'https://opensubtitles-v3.strem.io/subtitles/$type/$suffix/${releaseExtras.join('&')}.json',
        ),
        match: 'filename-size',
      ));
    }

    if (endpoints.isEmpty) {
      throw const AiSubtitleException(
        'This stream does not expose enough release metadata for safe AI Sinhala subtitles.',
      );
    }

    List<AiSubtitleCue>? cues;
    String? sourceUrl;
    var sourceMatch = endpoints.first.match;
    Object? lastError;

    for (final endpoint in endpoints) {
      onStatus?.call(
        endpoint.match == 'video-hash'
            ? 'Checking verified exact-hash subtitle candidates…'
            : 'Matching subtitles to this exact release…',
      );

      List<String> candidates = const [];
      try {
        candidates = await _subtitleCandidates(
          endpoint.uri,
          preferredFileName: probe.fileName,
          item: item,
          requireReleaseEvidence: endpoint.match == 'filename-size',
          preserveProviderOrder: endpoint.match == 'video-hash',
          requireHashEvidence: endpoint.match == 'video-hash',
        );
      } catch (error) {
        lastError = error;
        continue;
      }
      if (candidates.isEmpty) continue;

      for (final url in candidates.take(6)) {
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
    }

    if (cues == null || sourceUrl == null) {
      throw AiSubtitleException(
        lastError == null
            ? 'No trusted timing match was found for this exact video release.'
            : 'Could not prepare a trusted English subtitle for this video.',
      );
    }

    final prepared = AiPreparedSubtitle(
      key: key,
      title: title,
      sourceUrl: sourceUrl,
      cues: cues,
      sourceMatch: sourceMatch,
    );
    _preparedCache[key] = prepared;

    final firstEnd = math.min(96, cues.length);
    onStatus?.call('Translating a stable opening Sinhala buffer…');
    await _translateRange(prepared, 0, firstEnd);
    onStatus?.call('Sinhala subtitles ready.');
    return prepared;
  }

  static Future<String?> _fetchExactRestSubtitle({
    required String movieHash,
    required int movieByteSize,
  }) async {
    final body = <String, dynamic>{
      'moviehash': movieHash,
      'moviebytesize': movieByteSize,
      'language': 'en',
    };

    try {
      dynamic data;
      int status;
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        final response = await Supabase.instance.client.functions.invoke(
          'opensubtitles-exact',
          body: body,
        );
        status = response.status;
        data = response.data;
      } else {
        final response = await http
            .post(
              _openSubtitlesExactEndpoint,
              headers: const {
                'Authorization': 'Bearer $_guestFunctionJwt',
                'apikey': _guestFunctionJwt,
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 35));
        status = response.statusCode;
        try {
          data = jsonDecode(
            utf8.decode(response.bodyBytes, allowMalformed: true),
          );
        } catch (_) {
          data = null;
        }
      }

      if (status < 200 || status >= 300 || data is! Map) return null;
      if (data['moviehash_match'] != true) return null;
      final subtitle = data['subtitle']?.toString().trim() ?? '';
      return subtitle.isEmpty ? null : subtitle;
    } catch (_) {
      // REST v1 is the preferred exact resolver, but an outage/missing server
      // key must not break playback. Safe v3 exact/release matching continues.
      return null;
    }
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
    required MediaItem item,
    bool requireReleaseEvidence = false,
    bool preserveProviderOrder = false,
    bool requireHashEvidence = false,
  }) async {
    final response = await _httpGetWithRetry(endpoint);
    if (response.statusCode < 200 || response.statusCode >= 300)
      return const [];
    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    final entries = decoded is Map ? decoded['subtitles'] : null;
    if (entries is! List) return const [];

    if (preserveProviderOrder) {
      // A hash-qualified request is only considered exact when the provider
      // explicitly marks the candidate as a hash match. This avoids silently
      // accepting a generic IMDb/episode result from the same response.
      final exactRegular = <String>[];
      final exactForced = <String>[];
      final regular = <String>[];
      final forced = <String>[];
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
        final searchable =
            '${entry['label'] ?? ''} ${entry['id'] ?? ''} $url'.toLowerCase();
        final forcedOnly = searchable.contains('forced');
        final marker = (entry['m'] ?? '').toString().trim().toLowerCase();
        final hashMatched = marker == 'h' ||
            entry['hashMatch'] == true ||
            entry['hash_match'] == true ||
            entry['moviehash_match'] == true;
        if (hashMatched) {
          (forcedOnly ? exactForced : exactRegular).add(url);
        } else {
          (forcedOnly ? forced : regular).add(url);
        }
      }
      if (exactRegular.isNotEmpty || exactForced.isNotEmpty) {
        return <String>[...exactRegular, ...exactForced];
      }
      if (requireHashEvidence) return const [];
      return <String>[...regular, ...forced];
    }

    final preferredTokens = _releaseTokens(preferredFileName);
    final titleTokens = _releaseTokens(item.title);
    final specificTokens = <String>{...preferredTokens}
      ..removeAll(titleTokens)
      ..removeWhere((token) =>
          RegExp(r'^(?:19|20)\d{2}$').hasMatch(token) ||
          RegExp(r'^s\d{1,2}e\d{1,3}$').hasMatch(token) ||
          RegExp(r'^\d{1,2}x\d{1,3}$').hasMatch(token));
    if (requireReleaseEvidence && specificTokens.isEmpty) {
      return const [];
    }

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
      var specificMatches = 0;
      for (final token in preferredTokens) {
        if (searchable.contains(token)) score += token.length >= 5 ? 3 : 1;
      }
      for (final token in specificTokens) {
        if (searchable.contains(token)) {
          specificMatches++;
          score += token.length >= 5 ? 12 : 6;
        }
      }
      if (specificMatches > 0) score += 30;
      if (requireReleaseEvidence &&
          specificTokens.isNotEmpty &&
          specificMatches == 0) {
        continue;
      }
      if (searchable.contains('forced')) score -= 12;
      ranked.add((url: url, score: score));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked.map((entry) => entry.url).toList(growable: false);
  }

  static Future<void> ensureTranslatedAround(
    AiPreparedSubtitle prepared,
    Duration position, {
    int lookBehind = 4,
    int lookAhead = 72,
  }) async {
    if (!canTranslate || prepared.cues.isEmpty) return;

    for (var pass = 0; pass < 2; pass++) {
      final center = prepared.cueIndexNear(position);
      if (center < 0) return;
      final start = math.max(0, center - lookBehind);
      final end = math.min(prepared.cues.length, center + lookAhead + 1);
      final missing = <int>[
        for (var i = start; i < end; i++)
          if (!prepared.isTranslatedAt(i)) i,
      ];
      if (missing.isEmpty) return;

      final existing = _translationWork[prepared.key];
      if (existing != null) {
        await existing;
        continue;
      }

      final future = _translateMissingIndices(prepared, missing);
      _translationWork[prepared.key] = future;
      try {
        await future;
      } finally {
        if (identical(_translationWork[prepared.key], future)) {
          _translationWork.remove(prepared.key);
        }
      }
      return;
    }
  }

  static Future<void> _translateMissingIndices(
    AiPreparedSubtitle prepared,
    List<int> indices,
  ) async {
    const batchSize = 36;
    for (var cursor = 0; cursor < indices.length; cursor += batchSize) {
      final end = math.min(cursor + batchSize, indices.length);
      await _translateIndices(prepared, indices.sublist(cursor, end));
    }
  }

  static Future<void> _translateRange(
    AiPreparedSubtitle prepared,
    int start,
    int end,
  ) async {
    if (start >= end) return;
    final indices = <int>[
      for (var i = start; i < end; i++)
        if (!prepared.isTranslatedAt(i)) i,
    ];
    if (indices.isEmpty) return;

    // The translation Edge Function deliberately caps a single batch at
    // 80 subtitle cues. Opening preflight currently translates up to 96 cues,
    // so sending the whole range in one request made normal TV episodes fail
    // with invalid_segments every time. Reuse the chunked path here.
    await _translateMissingIndices(prepared, indices);
  }

  static Future<void> _translateIndices(
    AiPreparedSubtitle prepared,
    List<int> indices,
  ) async {
    if (indices.isEmpty) return;
    final segments = indices
        .map((index) => prepared.cues[index].source)
        .toList(growable: false);

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _invokeTranslation(<String, dynamic>{
          'title': prepared.title,
          'segments': segments,
        });
        final data = response.data;
        if (response.status == 429 ||
            (data is Map && data['error'] == 'rate_limited')) {
          throw const AiSubtitleException(
            'AI Sinhala subtitle limit reached.',
            rateLimited: true,
          );
        }
        if (response.status < 200 || response.status >= 300) {
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 500 * (attempt + 1)),
            );
            continue;
          }
          throw const AiSubtitleException(
            'Could not translate subtitle buffer.',
          );
        }

        final raw = data is Map ? data['translations'] : null;
        if (raw is! List || raw.length != indices.length) {
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 500 * (attempt + 1)),
            );
            continue;
          }
          throw const AiSubtitleException(
            'AI subtitle buffer was incomplete.',
          );
        }

        final values = <String>[
          for (final value in raw) value?.toString().trim() ?? '',
        ];
        var invalid = false;
        for (var i = 0; i < values.length; i++) {
          final source = prepared.cues[indices[i]].source;
          if (!isLikelySinhalaTranslation(source, values[i])) {
            invalid = true;
            break;
          }
        }
        if (invalid) {
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 500 * (attempt + 1)),
            );
            continue;
          }
          throw const AiSubtitleException(
            'AI returned an incomplete or non-Sinhala subtitle buffer.',
          );
        }

        for (var i = 0; i < indices.length; i++) {
          prepared.cues[indices[i]].translation = values[i];
        }
        return;
      } on AiSubtitleException catch (error) {
        if (error.rateLimited || attempt == 2) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (attempt + 1)),
        );
      } catch (_) {
        if (attempt == 2) {
          throw const AiSubtitleException(
            'Could not translate subtitle buffer.',
          );
        }
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (attempt + 1)),
        );
      }
    }
  }

  static Future<String> translateCue({
    required String title,
    required String text,
    List<String> context = const <String>[],
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return '';
    final cacheKey = '$title|$clean';
    final cached = _liveCueCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _invokeTranslation(<String, dynamic>{
          'title': title,
          'text': clean,
          'context': context.reversed
              .take(6)
              .toList(growable: false)
              .reversed
              .toList(growable: false),
        });
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
            await Future<void>.delayed(const Duration(milliseconds: 400));
            continue;
          }
          throw const AiSubtitleException(
            'Could not translate the current subtitle cue.',
          );
        }
        final translated =
            data is Map ? data['translation']?.toString().trim() ?? '' : '';
        if (!isLikelySinhalaTranslation(clean, translated)) {
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            continue;
          }
          throw const AiSubtitleException(
            'AI returned an empty or non-Sinhala subtitle cue.',
          );
        }
        _liveCueCache[cacheKey] = translated;
        return translated;
      } on AiSubtitleException catch (error) {
        if (error.rateLimited || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } catch (_) {
        if (attempt == 1) {
          throw const AiSubtitleException(
            'Could not translate the current subtitle cue.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw const AiSubtitleException(
      'Could not translate the current subtitle cue.',
    );
  }

  static Future<_VideoProbe> _probeVideo(
    String rawUrl, {
    String? fallbackFileName,
    int? fallbackSize,
    String? expectedVideoHash,
  }) async {
    final uri = Uri.tryParse(rawUrl);
    final fallbackName = fallbackFileName?.trim().isNotEmpty == true
        ? fallbackFileName!.trim()
        : uri == null
            ? null
            : _fileNameFromUri(uri);
    final suppliedHash = _normalizeVideoHash(expectedVideoHash);

    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return _VideoProbe(
        fileName: fallbackName,
        size: fallbackSize,
        hash: suppliedHash,
      );
    }

    final localP2p =
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
            uri.port == 11470;

    if (localP2p) {
      // stream-server v0.1.8 exposes /opensubHash and computes the canonical
      // OpenSubtitles hash from the EXACT selected torrent file index.
      // LocalTorrentService.resolve() creates the engine before returning this
      // URL, so this endpoint is safe to call before libmpv opens the media.
      // Never fall back to addon metadata for local P2P if this exact probe
      // fails; guessing would recreate the sync bug.
      return _probeLocalOpenSubtitlesHash(
        uri,
        fallbackFileName: fallbackName,
        fallbackSize: fallbackSize,
      );
    }

    // Direct/cloud URLs do not have the native hash endpoint, so compute the
    // canonical hash from byte ranges on the actual selected URL.
    final client = http.Client();
    try {
      final first = await _readRangeWithRetry(
        client,
        uri,
        0,
        65535,
        attempts: 4,
        requirePartial: true,
      );
      if (first != null && first.statusCode == 206) {
        final fileName = _fileNameFromHeaders(first.headers) ?? fallbackName;
        final size = _totalSize(first.statusCode, first.headers) ?? fallbackSize;
        if (size != null &&
            size >= 131072 &&
            first.bytes.length >= 65536) {
          final tail = await _readRangeWithRetry(
            client,
            uri,
            size - 65536,
            size - 1,
            attempts: 5,
            requirePartial: true,
          );
          if (tail != null &&
              tail.statusCode == 206 &&
              tail.bytes.length >= 65536) {
            return _VideoProbe(
              fileName: fileName,
              size: size,
              hash: _openSubtitlesHash(size, first.bytes, tail.bytes),
            );
          }
        }
      }
    } catch (_) {
      // Fall through to provider metadata only for non-local direct/cloud
      // sources where byte-range fingerprinting is genuinely unavailable.
    } finally {
      client.close();
    }

    return _VideoProbe(
      fileName: fallbackName,
      size: fallbackSize,
      hash: suppliedHash,
    );
  }

  static Future<_VideoProbe> _probeLocalOpenSubtitlesHash(
    Uri videoUri, {
    required String? fallbackFileName,
    required int? fallbackSize,
  }) async {
    final endpoint = videoUri.replace(
      path: '/opensubHash',
      queryParameters: <String, String>{'videoUrl': videoUri.toString()},
      fragment: '',
    );

    // The native route calls engine.get_opensub_hash(fileIdx), which reads the
    // selected file's first + last 64 KiB at internal priority 255 and returns
    // both the canonical hash and exact byte size.
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final response =
            await http.get(endpoint).timeout(const Duration(seconds: 45));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(
            utf8.decode(response.bodyBytes, allowMalformed: true),
          );
          final result = decoded is Map ? decoded['result'] : null;
          if (result is Map) {
            final hash = _normalizeVideoHash(result['hash']?.toString());
            final rawSize = result['size'];
            final nativeSize = rawSize is num
                ? rawSize.toInt()
                : int.tryParse(rawSize?.toString() ?? '');
            if (hash != null && nativeSize != null && nativeSize > 0) {
              return _VideoProbe(
                fileName: fallbackFileName,
                size: nativeSize,
                hash: hash,
              );
            }
          }
        }
      } catch (_) {}

      if (attempt < 3) {
        await Future<void>.delayed(
          Duration(milliseconds: 800 * (attempt + 1)),
        );
      }
    }

    return _VideoProbe(
      fileName: fallbackFileName,
      size: null,
      hash: null,
    );
  }

  static Future<_RangeRead?> _readRangeWithRetry(
    http.Client client,
    Uri uri,
    int start,
    int end, {
    int attempts = 3,
    bool requirePartial = false,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final value = await _readRange(client, uri, start, end);
        final expected = end - start + 1;
        final usable = value != null &&
            value.bytes.length >= expected &&
            (!requirePartial || value.statusCode == 206);
        if (usable) return value;
      } catch (_) {}
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(
          Duration(milliseconds: 650 * (attempt + 1)),
        );
      }
    }
    return null;
  }

  static Future<_RangeRead?> _readRange(
    http.Client client,
    Uri uri,
    int start,
    int end,
  ) async {
    final localP2p =
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
            uri.port == 11470;
    final request = http.Request('GET', uri)
      ..headers['Range'] = 'bytes=$start-$end'
      ..headers['Accept-Encoding'] = 'identity';
    if (localP2p) {
      // stream-server v0.1.8 treats priority 255 as InternalProbe and
      // prioritizes the exact pieces required for the hash.
      request.headers['enginefs-prio'] = '255';
    }
    final response = await client
        .send(request)
        .timeout(Duration(seconds: localP2p ? 35 : 12));
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

  static String? _normalizeVideoHash(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null || !RegExp(r'^[a-f0-9]{16}$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  static Future<String> _downloadSubtitle(String url) async {
    final response = await _httpGetWithRetry(
      Uri.parse(url),
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AiSubtitleException('Subtitle download failed.');
    }
    List<int> bytes = response.bodyBytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = gzip.decode(bytes);
    }

    // SubDL serves many subtitles as ZIP archives. The provider is only used
    // as a transcript fallback, so unpack the safest text subtitle member and
    // let native video cues remain the runtime timing authority.
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08)) {
      try {
        final archive = ZipDecoder().decodeBytes(bytes, verify: true);
        final files = archive.files
            .where((entry) {
              if (!entry.isFile) return false;
              final name = entry.name.toLowerCase();
              if (name.startsWith('__macosx/') ||
                  name.split('/').last.startsWith('._')) {
                return false;
              }
              return name.endsWith('.srt') ||
                  name.endsWith('.vtt') ||
                  name.endsWith('.ass') ||
                  name.endsWith('.ssa');
            })
            .toList(growable: false)
          ..sort((a, b) {
            int rank(String name) {
              final lower = name.toLowerCase();
              if (lower.endsWith('.srt')) return 0;
              if (lower.endsWith('.vtt')) return 1;
              if (lower.endsWith('.ass')) return 2;
              return 3;
            }

            final ext = rank(a.name).compareTo(rank(b.name));
            if (ext != 0) return ext;
            return b.size.compareTo(a.size);
          });
        for (final file in files) {
          final content = file.readBytes();
          if (content == null || content.isEmpty) continue;
          final text = utf8.decode(content, allowMalformed: true);
          if (_parseSubtitle(text).length >= 8) return text;
        }
        throw const AiSubtitleException(
          'Subtitle archive did not contain a usable text subtitle.',
        );
      } catch (error) {
        if (error is AiSubtitleException) rethrow;
        throw const AiSubtitleException(
          'Could not unpack the subtitle archive safely.',
        );
      }
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

  static Future<_TranslationResponse> _invokeTranslation(
    Map<String, dynamic> body,
  ) async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      final response = await Supabase.instance.client.functions.invoke(
        'translate-subtitle-si',
        body: body,
      );
      return _TranslationResponse(
        status: response.status,
        data: response.data,
      );
    }

    final response = await http
        .post(
          _translationEndpoint,
          headers: const {
            'Authorization': 'Bearer $_guestFunctionJwt',
            'apikey': _guestFunctionJwt,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));

    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (_) {
      data = <String, dynamic>{'error': 'invalid_function_response'};
    }
    return _TranslationResponse(status: response.statusCode, data: data);
  }

  static void clearPreparedCache() {
    _preparedCache.clear();
    _translationWork.clear();
    _liveCueCache.clear();
  }
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

double _cueTextSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;

  final aw = a.split(' ').where((word) => word.isNotEmpty).toSet();
  final bw = b.split(' ').where((word) => word.isNotEmpty).toSet();
  if (aw.isEmpty || bw.isEmpty) return 0;

  final intersection = aw.intersection(bw).length.toDouble();
  final union = aw.union(bw).length.toDouble();
  final jaccard = union == 0 ? 0.0 : intersection / union;

  final shorter = a.length < b.length ? a : b;
  final longer = a.length < b.length ? b : a;
  final containment =
      longer.contains(shorter) ? shorter.length / longer.length : 0.0;
  return math.max(jaccard, containment).toDouble();
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

class _TranslationResponse {
  const _TranslationResponse({
    required this.status,
    required this.data,
  });

  final int status;
  final dynamic data;
}

class AiSubtitleException implements Exception {
  const AiSubtitleException(this.message, {this.rateLimited = false});

  final String message;
  final bool rateLimited;

  @override
  String toString() => message;
}
