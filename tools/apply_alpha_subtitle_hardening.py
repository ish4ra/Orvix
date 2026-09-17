from pathlib import Path
import re


def must_sub(pattern: str, replacement: str, text: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.S)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 replacement, got {count}')
    return updated


# --- Player: use embedded English text OR bitmap timing as the authoritative clock. ---
player_path = Path('lib/screens/player_screen.dart')
player = player_path.read_text(encoding='utf-8')
player = player.replace(
    "  Timer? _startupTimer;\n",
    "  Timer? _startupTimer;\n  Timer? _nativeSubtitleClockTimer;\n",
    1,
)
player = player.replace(
    "  bool _timingTrackSelected = false;\n  String _aiDisplaySubtitle = '';\n  int _autoSyncOffsetMs = 0;\n  int _manualSyncOffsetMs = 0;\n  final List<int> _autoSyncSamples = <int>[];\n",
    "  bool _timingTrackSelected = false;\n  bool _timingTrackIsText = false;\n  String _aiDisplaySubtitle = '';\n  int _autoSyncOffsetMs = 0;\n  int _manualSyncOffsetMs = 0;\n  int? _lastNativeSubtitleStartMs;\n  final List<int> _autoSyncSamples = <int>[];\n  final Map<int, int> _bitmapOffsetVotes = <int, int>{};\n",
    1,
)

new_timing_block = r'''  Future<void> _ensureEnglishTimingTrack() async {
    if (!_aiSinhalaEnabled) return;
    final player = widget.playback.player;
    for (var attempt = 0; attempt < 12 && mounted; attempt++) {
      final current = player.state.track.subtitle;
      dynamic chosen;
      if (current.id.toLowerCase() != 'no' && _isEnglishTrack(current)) {
        chosen = current;
      } else {
        final tracks = player.state.tracks.subtitle
            .where((track) => track.id.toLowerCase() != 'no')
            .where(_isEnglishTrack)
            .toList(growable: false)
          ..sort((a, b) {
            final aBitmap = _isImageSubtitleTrack(a) ? 1 : 0;
            final bBitmap = _isImageSubtitleTrack(b) ? 1 : 0;
            return aBitmap.compareTo(bBitmap);
          });
        if (tracks.isNotEmpty) {
          chosen = tracks.first;
          await player.setSubtitleTrack(chosen);
        }
      }

      if (chosen != null) {
        _timingTrackSelected = true;
        _timingTrackIsText = !_isImageSubtitleTrack(chosen);
        await _hideNativeTimingSubtitle();
        _startNativeSubtitleClock();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  bool _isEnglishTrack(dynamic track) {
    final language = (track.language ?? '').toString().trim().toLowerCase();
    final title = (track.title ?? '').toString().trim().toLowerCase();
    return language == 'en' ||
        language == 'eng' ||
        language.startsWith('en-') ||
        language.contains('english') ||
        title.contains('english') ||
        title == 'eng';
  }

  bool _isImageSubtitleTrack(dynamic track) {
    final codec = (track.codec ?? '').toString().trim().toLowerCase();
    return codec.contains('pgs') ||
        codec.contains('hdmv') ||
        codec.contains('dvd') ||
        codec.contains('dvb') ||
        codec.contains('vob');
  }

  bool _isEnglishTextTrack(dynamic track) =>
      _isEnglishTrack(track) && !_isImageSubtitleTrack(track);

  Future<void> _hideNativeTimingSubtitle() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      // mpv keeps the selected subtitle decoded while hiding its native render.
      // That lets Orvix use both text and PGS/bitmap cue timing as a sync clock.
      await platform.setProperty(
        'sub-visibility',
        'no',
        waitForInitialization: false,
      );
    } catch (_) {
      // The AI overlay still works even if a platform does not expose this.
    }
  }

  void _startNativeSubtitleClock() {
    _nativeSubtitleClockTimer?.cancel();
    _nativeSubtitleClockTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(_pollNativeSubtitleClock()),
    );
  }

  Future<int?> _nativeSubtitleStartMs() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return null;
    try {
      final raw = (await platform.getProperty(
        'sub-start/full',
        waitForInitialization: false,
      ))
          .trim();
      if (raw.isEmpty || raw == 'null' || raw == 'N/A') return null;
      final seconds = double.tryParse(raw);
      if (seconds == null || !seconds.isFinite || seconds < 0) return null;
      return (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  Future<void> _pollNativeSubtitleClock() async {
    if (!_aiSinhalaEnabled || !_timingTrackSelected || !mounted) return;
    final startMs = await _nativeSubtitleStartMs();
    if (startMs == null || !mounted) return;
    final previous = _lastNativeSubtitleStartMs;
    if (previous != null && (startMs - previous).abs() < 40) return;
    _lastNativeSubtitleStartMs = startMs;
    if (!_timingTrackIsText) {
      _voteBitmapTiming(startMs);
    }
  }

  void _acceptAutoSyncSample(int sample) {
    if (sample.abs() > 15000 || !mounted) return;
    _autoSyncSamples.add(sample);
    if (_autoSyncSamples.length > 7) _autoSyncSamples.removeAt(0);
    final ordered = [..._autoSyncSamples]..sort();
    final median = ordered[ordered.length ~/ 2];
    if ((median - _autoSyncOffsetMs).abs() < 40) return;
    setState(() => _autoSyncOffsetMs = median);
    _refreshAiSubtitle();
  }

  void _voteBitmapTiming(int sourceStartMs) {
    final prepared = widget.aiSubtitle;
    if (prepared == null || prepared.cues.isEmpty) return;

    // PGS/VobSub carries timing but no text. Build a small histogram of the
    // difference between source cue starts and nearby OpenSubtitles cue starts.
    // The real release offset repeats across many cues; accidental neighbours do not.
    const windowMs = 12000;
    for (final cue in prepared.cues) {
      final cueStart = cue.start.inMilliseconds;
      if (cueStart < sourceStartMs - windowMs) continue;
      if (cueStart > sourceStartMs + windowMs) break;
      final diff = sourceStartMs - cueStart;
      final bucket = (diff / 100).round() * 100;
      _bitmapOffsetVotes[bucket] = (_bitmapOffsetVotes[bucket] ?? 0) + 1;
    }

    if (_bitmapOffsetVotes.length < 2) return;
    final ranked = _bitmapOffsetVotes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final secondVotes = ranked.length > 1 ? ranked[1].value : 0;
    if (best.value >= 4 && best.value - secondVotes >= 2) {
      _acceptAutoSyncSample(best.key);
    }
  }

  void _onEmbeddedSubtitleCue(List<String> lines) {
    unawaited(_handleEmbeddedSubtitleCue(lines));
  }

  Future<void> _handleEmbeddedSubtitleCue(List<String> lines) async {
    if (!_aiSinhalaEnabled || !_timingTrackSelected || !mounted) return;
    final prepared = widget.aiSubtitle;
    if (prepared == null || !_timingTrackIsText) return;
    final source = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
    if (source.isEmpty) return;
    final matched = prepared.matchSourceCue(source);
    if (matched == null) return;
    final nativeStart = await _nativeSubtitleStartMs();
    if (!mounted) return;
    final sourceStart = nativeStart ?? widget.playback.player.state.position.inMilliseconds;
    _acceptAutoSyncSample(sourceStart - matched.start.inMilliseconds);
  }

'''

player = must_sub(
    r"  Future<void> _ensureEnglishTimingTrack\(\) async \{.*?(?=  Widget _aiSubtitleOverlay\(\))",
    new_timing_block,
    player,
    'player timing block',
)
player = player.replace(
    "Auto-synced from this video’s embedded English timing. Adjust only if it still looks off.",
    "Auto-synced from this video’s embedded English subtitle timing. Adjust only if it still looks off.",
)
player = player.replace(
    "    _startupTimer?.cancel();\n",
    "    _startupTimer?.cancel();\n    _nativeSubtitleClockTimer?.cancel();\n",
    1,
)
player_path.write_text(player, encoding='utf-8')


# --- Subtitle preparation: exact-match first, but never get stuck on one bad result. ---
service_path = Path('lib/services/ai_sinhala_subtitle_service.dart')
service = service_path.read_text(encoding='utf-8')

new_prepare_selection = r'''    List<AiSubtitleCue>? cues;
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

      for (final url in candidates.take(endpoint.match == 'title-episode' ? 10 : 6)) {
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

'''
service = must_sub(
    r"    List<String> candidates = const \[\];.*?(?=    final prepared = AiPreparedSubtitle\()",
    new_prepare_selection,
    service,
    'subtitle source selection',
)

new_candidate_function = r'''  static Future<http.Response> _httpGetWithRetry(
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
    throw lastError ?? const AiSubtitleException('Subtitle service is unavailable.');
  }

  static Set<String> _releaseTokens(String? fileName) {
    if (fileName == null || fileName.trim().isEmpty) return const <String>{};
    final normalized = fileName
        .toLowerCase()
        .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    const ignored = <String>{
      '1080p', '2160p', '720p', '480p', '4k', 'uhd', 'hdr', 'hdr10',
      'bluray', 'brrip', 'webrip', 'web', 'webdl', 'x264', 'x265', 'h264',
      'h265', 'hevc', 'avc', 'aac', 'dts', 'atmos', 'remux', 'proper',
      'repack', 'multi', 'mkv', 'mp4', 'avi', '10bit', '8bit',
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
    if (response.statusCode < 200 || response.statusCode >= 300) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
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

'''
service = must_sub(
    r"  static Future<List<String>> _subtitleCandidates\(Uri endpoint\) async \{.*?(?=  static Future<void> _translateRemaining\()",
    new_candidate_function,
    service,
    'subtitle candidates',
)

new_translate_range = r'''  static Future<void> _translateRange(
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
          throw const AiSubtitleException('Could not translate subtitle buffer.');
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
          throw const AiSubtitleException('Could not translate subtitle buffer.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 550));
      }
    }
  }

'''
service = must_sub(
    r"  static Future<void> _translateRange\(.*?(?=  static Future<_VideoProbe> _probeVideo\()",
    new_translate_range,
    service,
    'translation retry',
)
service = service.replace(
    "    final response =\n        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));\n",
    "    final response = await _httpGetWithRetry(\n      Uri.parse(url),\n      timeout: const Duration(seconds: 15),\n    );\n",
    1,
)
service_path.write_text(service, encoding='utf-8')


# --- Details: don't present a transient provider miss as a scary hard error. ---
details_path = Path('lib/screens/details_screen.dart')
details = details_path.read_text(encoding='utf-8')
details = details.replace(
    "AI Sinhala could not be prepared for this title. Playing with normal subtitle options.",
    "AI Sinhala was not ready for this source after automatic retries. Playing normally; you can retry this title at any time.",
    1,
)
details_path.write_text(details, encoding='utf-8')

print('Applied alpha subtitle hardening patch.')
