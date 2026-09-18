from pathlib import Path

def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"patch target not found: {label}")
    return text.replace(old, new, 1)

def replace_between(text, start, end, new_block, label):
    a = text.find(start)
    if a < 0:
        raise SystemExit(f"start target not found: {label}")
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"end target not found: {label}")
    return text[:a] + new_block + text[b:]

# source_provider_service.dart
path = Path("lib/services/source_provider_service.dart")
text = path.read_text(encoding="utf-8")
pref_class = """class PinnedSourcePreference {
  const PinnedSourcePreference({
    required this.identity,
    required this.provider,
    required this.label,
    this.bingeGroup,
  });

  final String identity;
  final String provider;
  final String label;
  final String? bingeGroup;
}

"""
text = replace_once(text, "class SourceProviderService {", pref_class + "class SourceProviderService {", "pinned preference class")

old = """  Future<String?> getPinnedSourceIdentity(String targetKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pinPreferenceKey(targetKey));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final identity = decoded['identity']?.toString().trim();
        return identity == null || identity.isEmpty ? null : identity;
      }
    } catch (_) {
      // A future migration can still accept a legacy plain identity value.
      return raw.trim();
    }
    return null;
  }
"""
new = """  Future<PinnedSourcePreference?> getPinnedSourcePreference(
    String targetKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pinPreferenceKey(targetKey));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final identity = decoded['identity']?.toString().trim() ?? '';
        if (identity.isEmpty) return null;
        final provider = decoded['provider']?.toString().trim();
        final label = decoded['label']?.toString().trim();
        return PinnedSourcePreference(
          identity: identity,
          provider: provider == null || provider.isEmpty
              ? identity.split('|').first
              : provider,
          label: label == null || label.isEmpty ? 'Pinned release' : label,
          bingeGroup: decoded['bingeGroup']?.toString(),
        );
      }
    } catch (_) {
      final identity = raw.trim();
      if (identity.isEmpty) return null;
      return PinnedSourcePreference(
        identity: identity,
        provider: identity.split('|').first,
        label: 'Pinned release',
      );
    }
    return null;
  }

  Future<String?> getPinnedSourceIdentity(String targetKey) async =>
      (await getPinnedSourcePreference(targetKey))?.identity;
"""
text = replace_once(text, old, new, "pinned preference reader")
text = replace_once(
    text,
    "    final label = result.title.split('\\n').last.trim();\n",
    "    final fileName = result.fileNameHint?.trim();\n    final label = fileName != null && fileName.isNotEmpty\n        ? fileName\n        : result.title.split('\\n').last.trim();\n",
    "pin label uses release filename",
)
path.write_text(text, encoding="utf-8")

# ai_sinhala_preferences_service.dart
path = Path("lib/services/ai_sinhala_preferences_service.dart")
text = path.read_text(encoding="utf-8")
text = text.replace("milliseconds.clamp(-15000, 15000).toInt()", "milliseconds.clamp(-120000, 120000).toInt()")
path.write_text(text, encoding="utf-8")

# ai_sinhala_subtitle_service.dart
path = Path("lib/services/ai_sinhala_subtitle_service.dart")
text = path.read_text(encoding="utf-8")
text = replace_once(
    text,
    """  static Future<AiPreparedSubtitle?> prepareBuffered({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    void Function(String message)? onStatus,
  }) async {
    final probe = await _probeVideo(videoUrl);
""",
    """  static Future<AiPreparedSubtitle?> prepareBuffered({
    required MediaItem item,
    required String videoUrl,
    EpisodeItem? episode,
    String? releaseHint,
    int? expectedSizeBytes,
    void Function(String message)? onStatus,
  }) async {
    final probe = await _probeVideo(
      videoUrl,
      fallbackFileName: releaseHint,
      fallbackSize: expectedSizeBytes,
    );
""",
    "AI prepare release hints",
)
text = replace_once(
    text,
    """        candidates = await _subtitleCandidates(
          endpoint.uri,
          preferredFileName: probe.fileName,
        );
""",
    """        candidates = await _subtitleCandidates(
          endpoint.uri,
          preferredFileName: probe.fileName,
          item: item,
        );
""",
    "subtitle candidates item context",
)
text = replace_once(
    text,
    """  static Future<List<String>> _subtitleCandidates(
    Uri endpoint, {
    String? preferredFileName,
  }) async {
""",
    """  static Future<List<String>> _subtitleCandidates(
    Uri endpoint, {
    String? preferredFileName,
    required MediaItem item,
  }) async {
""",
    "candidate signature",
)
text = replace_once(
    text,
    """    final preferredTokens = _releaseTokens(preferredFileName);
    final ranked = <({String url, int score})>[];
""",
    """    final preferredTokens = _releaseTokens(preferredFileName);
    final titleTokens = _releaseTokens(item.title);
    final specificTokens = <String>{...preferredTokens}
      ..removeAll(titleTokens)
      ..removeWhere((token) => RegExp(r'^(?:19|20)\\d{2}$').hasMatch(token));
    final ranked = <({String url, int score})>[];
""",
    "release-specific token ranking",
)
text = replace_once(
    text,
    """      var score = 0;
      for (final token in preferredTokens) {
        if (searchable.contains(token)) score += token.length >= 5 ? 3 : 1;
      }
      if (searchable.contains('forced')) score -= 3;
""",
    """      var score = 0;
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
      if (searchable.contains('forced')) score -= 12;
""",
    "strong release match ranking",
)
old_probe = """  static Future<_VideoProbe> _probeVideo(String rawUrl) async {
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
"""
new_probe = """  static Future<_VideoProbe> _probeVideo(
    String rawUrl, {
    String? fallbackFileName,
    int? fallbackSize,
  }) async {
    final uri = Uri.tryParse(rawUrl);
    final fallbackName = fallbackFileName?.trim().isNotEmpty == true
        ? fallbackFileName!.trim()
        : uri == null
            ? null
            : _fileNameFromUri(uri);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return _VideoProbe(fileName: fallbackName, size: fallbackSize);
    }
    final client = http.Client();
    try {
      final first = await _readRange(client, uri, 0, 65535);
      if (first == null) {
        return _VideoProbe(fileName: fallbackName, size: fallbackSize);
      }
      final fileName = _fileNameFromHeaders(first.headers) ?? fallbackName;
      final size = _totalSize(first.statusCode, first.headers) ?? fallbackSize;
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
      return _VideoProbe(fileName: fallbackName, size: fallbackSize);
    } finally {
      client.close();
    }
  }
"""
text = replace_once(text, old_probe, new_probe, "video probe fallbacks")
path.write_text(text, encoding="utf-8")

# player_screen.dart
path = Path("lib/screens/player_screen.dart")
text = path.read_text(encoding="utf-8")
text = replace_once(text, """    this.aiSubtitle,
    this.nextEpisodeLabel,
""", """    this.aiSubtitle,
    this.releaseHint,
    this.expectedSizeBytes,
    this.nextEpisodeLabel,
""", "player ctor release hints")
text = replace_once(text, """  final AiPreparedSubtitle? aiSubtitle;
  final String? nextEpisodeLabel;
""", """  final AiPreparedSubtitle? aiSubtitle;
  final String? releaseHint;
  final int? expectedSizeBytes;
  final String? nextEpisodeLabel;
""", "player fields release hints")
text = replace_once(text, """  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
""", """  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  StreamSubscription<String>? _playbackErrorSubscription;
  final FocusNode _focusNode = FocusNode();
  AiPreparedSubtitle? _preparedAiSubtitle;
  bool _aiSinhalaEnabled = false;
  bool _aiSubtitleLoading = false;
  bool _aiSubtitleUnavailable = false;
""", "player state async AI")
text = replace_once(text, """    _aiSinhalaEnabled = widget.aiSubtitle != null;
    if (_aiSinhalaEnabled) {
""", """    _preparedAiSubtitle = widget.aiSubtitle;
    _aiSinhalaEnabled = _preparedAiSubtitle != null;
    _playbackErrorSubscription =
        widget.playback.player.stream.error.listen(_onPlaybackError);
    if (_aiSinhalaEnabled) {
""", "player init AI and errors")
text = text.replace("widget.aiSubtitle", "_preparedAiSubtitle")
text = replace_once(text, """      await widget.playback.open(widget.url, title: widget.title);
      if (_aiSinhalaEnabled) {
        unawaited(_ensureEnglishTimingTrack());
      }
""", """      await widget.playback.open(widget.url, title: widget.title);
      if (_aiSinhalaEnabled) {
        unawaited(_ensureEnglishTimingTrack());
      } else {
        unawaited(_prepareAiSinhalaAfterPlaybackStarts());
      }
""", "start AI after playback")
text = text.replace("PikPak stream did not initialize (still 0:00/0:00 after 12 seconds).", "The video stream did not initialize (still 0:00/0:00 after 12 seconds).")

marker = "  Future<void> _persistProgress() async {"
new_methods = """  void _onPlaybackError(String message) {
    if (!mounted || message.trim().isEmpty) return;
    final state = widget.playback.player.state;
    if (state.duration <= Duration.zero &&
        state.position < const Duration(seconds: 1)) {
      setState(() => _error = 'Playback engine: ${message.trim()}');
    }
  }

  Future<void> _prepareAiSinhalaAfterPlaybackStarts() async {
    if (_preparedAiSubtitle != null || widget.item == null) return;
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    if (!enabled || !mounted) return;
    if (!AiSinhalaSubtitleService.canTranslate) {
      if (mounted) setState(() => _aiSubtitleUnavailable = true);
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _aiSubtitleLoading = true;
      _aiSubtitleUnavailable = false;
    });
    try {
      final prepared = await AiSinhalaSubtitleService.prepareBuffered(
        item: widget.item!,
        episode: widget.episode,
        videoUrl: widget.url,
        releaseHint: widget.releaseHint,
        expectedSizeBytes: widget.expectedSizeBytes,
      );
      if (!mounted) return;
      if (prepared == null) {
        setState(() {
          _aiSubtitleLoading = false;
          _aiSubtitleUnavailable = true;
        });
        return;
      }
      setState(() {
        _preparedAiSubtitle = prepared;
        _aiSinhalaEnabled = true;
        _aiSubtitleLoading = false;
        _aiSubtitleUnavailable = false;
      });
      _positionSubscription ??=
          widget.playback.player.stream.position.listen(_onPosition);
      _subtitleTimingSubscription ??=
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
      await _loadManualSync();
      if (!mounted) return;
      await _ensureEnglishTimingTrack();
      _refreshAiSubtitle();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _aiSubtitleLoading = false;
        _aiSubtitleUnavailable = true;
      });
    }
  }

"""
text = replace_once(text, marker, new_methods + marker, "player async AI methods")
text = text.replace("(_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-15000, 15000).toInt()", "(_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-120000, 120000).toInt()")
text = text.replace("(_manualSyncOffsetMs + deltaMs).clamp(-15000, 15000).toInt()", "(_manualSyncOffsetMs + deltaMs).clamp(-120000, 120000).toInt()")
text = text.replace("if (sample.abs() > 15000 || !mounted) return;", "if (sample.abs() > 120000 || !mounted) return;")
text = text.replace("const windowMs = 12000;", "const windowMs = 120000;")

old_tracks = """        final tracks = player.state.tracks.subtitle
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
"""
new_tracks = """        final allTracks = player.state.tracks.subtitle
            .where((track) => track.id.toLowerCase() != 'no')
            .toList(growable: false);
        final tracks = allTracks.where(_isEnglishTrack).toList(growable: false)
          ..sort((a, b) {
            final aBitmap = _isImageSubtitleTrack(a) ? 1 : 0;
            final bBitmap = _isImageSubtitleTrack(b) ? 1 : 0;
            return aBitmap.compareTo(bBitmap);
          });
        if (tracks.isNotEmpty) {
          chosen = tracks.first;
          await player.setSubtitleTrack(chosen);
        } else {
          final unknownText = allTracks.where((track) {
            if (_isImageSubtitleTrack(track)) return false;
            final language = (track.language ?? '').toString().trim();
            final title = (track.title ?? '').toString().trim();
            return language.isEmpty && title.isEmpty;
          }).toList(growable: false);
          if (unknownText.length == 1) {
            chosen = unknownText.first;
            await player.setSubtitleTrack(chosen);
          }
        }
"""
text = replace_once(text, old_tracks, new_tracks, "unknown embedded subtitle fallback")

status_marker = """                const SizedBox(height: 8),
                if (_aiSinhalaEnabled && _preparedAiSubtitle != null) ...[
"""
status_new = """                const SizedBox(height: 8),
                if (_aiSubtitleLoading)
                  const _EmptyTrackMessage(
                    'AI Sinhala is matching this exact release in the background. Playback is not blocked.',
                  )
                else if (_aiSubtitleUnavailable)
                  const _EmptyTrackMessage(
                    'AI Sinhala could not confidently prepare subtitles for this release. Playback is unaffected.',
                  ),
                if ((_aiSubtitleLoading || _aiSubtitleUnavailable) &&
                    _aiSinhalaEnabled == false)
                  const SizedBox(height: 12),
                if (_aiSinhalaEnabled && _preparedAiSubtitle != null) ...[
"""
text = replace_once(text, status_marker, status_new, "AI status in track sheet")
text = replace_once(text, """    _subtitleTimingSubscription?.cancel();
    _persistProgress();
""", """    _subtitleTimingSubscription?.cancel();
    _playbackErrorSubscription?.cancel();
    _persistProgress();
""", "cancel playback error subscription")
path.write_text(text, encoding="utf-8")

# details_screen.dart
path = Path("lib/screens/details_screen.dart")
text = path.read_text(encoding="utf-8")
text = text.replace("import '../services/ai_sinhala_preferences_service.dart';\n", "")
text = text.replace("import '../services/ai_sinhala_subtitle_service.dart';\n", "")

new_meta = """  Widget _metadataSection(MediaItem item) {
    final hasCredits = item.cast.isNotEmpty || item.directors.isNotEmpty;
    final hasFacts = item.country?.trim().isNotEmpty == true ||
        item.certification?.trim().isNotEmpty == true ||
        item.genres.isNotEmpty;
    final pinKey = widget.sources.sourceTargetKey(item);

    return FutureBuilder<PinnedSourcePreference?>(
      future: widget.sources.getPinnedSourcePreference(pinKey),
      builder: (context, snapshot) {
        final pinned = snapshot.data;
        if (!hasCredits && !hasFacts && pinned == null) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(40, 18, 40, 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pinned != null) ...[
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: item.kind == MediaKind.movie
                          ? () => _playPinnedRelease(item)
                          : null,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 15,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D150F),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2D492F)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin_rounded),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.kind == MediaKind.series
                                        ? 'Pinned release family'
                                        : 'Pinned release',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    pinned.label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    item.kind == MediaKind.movie
                                        ? '${pinned.provider} • Click to play this exact pinned release'
                                        : '${pinned.provider} • This release family is preferred when you choose an episode',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (item.kind == MediaKind.movie)
                              const Icon(Icons.play_arrow_rounded),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (hasCredits || hasFacts) ...[
                  Text(
                    'Details',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  if (item.directors.isNotEmpty)
                    Text(
                      'Director${item.directors.length > 1 ? 's' : ''}  •  ${item.directors.join(', ')}',
                      style: const TextStyle(fontSize: 15, height: 1.5),
                    ),
                  if (item.country?.trim().isNotEmpty == true ||
                      item.certification?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (item.country?.trim().isNotEmpty == true)
                          item.country!.trim(),
                        if (item.certification?.trim().isNotEmpty == true)
                          'Rated ${item.certification!.trim()}',
                      ].join('  •  '),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (item.cast.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Cast',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: item.cast
                          .take(24)
                          .map(
                            (name) => Chip(
                              avatar: const Icon(
                                Icons.person_outline_rounded,
                                size: 17,
                              ),
                              label: Text(name),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

"""
text = replace_between(text, "  Widget _metadataSection(MediaItem item) {", "  Widget _episodeSection(MediaItem item) {", new_meta, "metadata section")

old_tail = """      chosen ??= await _chooseSource(results, item, episode);
      if (chosen == null || !mounted) return;

      if (!chosen.isMagnet) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status = 'Opening direct stream…';
        });
        await _openPlayerUrl(chosen.resource, item, episode);
        return;
      }

      if (!hasCloudConnection) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status = 'Starting local P2P torrent stream…';
        });
        final localUrl = await LocalTorrentService.instance.resolve(chosen);
        if (!mounted) return;
        setState(() => _status = 'Torrent metadata ready — opening player…');
        await _openPlayerUrl(localUrl, item, episode);
        return;
      }

      final cloud = await _chooseCloudProvider();
      if (cloud == null || !mounted) return;
      if (cloud == CloudProvider.torbox) {
        await _sendSourceToTorBox(chosen, item, episode);
      } else {
        await _sendSourceToPikPak(chosen, item, episode);
      }
"""
new_tail = """      chosen ??= await _chooseSource(results, item, episode);
      if (chosen == null || !mounted) return;
      await _playSourceResult(
        chosen,
        item,
        episode,
        hasCloudConnection: hasCloudConnection,
      );
"""
text = replace_once(text, old_tail, new_tail, "reuse source playback")

helper_marker = "  Future<void> _showNoSourcesDialog("
helpers = """  String _sourceReleaseHint(SourceResult source) {
    final fileName = source.fileNameHint?.trim();
    if (fileName != null && fileName.isNotEmpty) return fileName;
    return source.title.split('\\n').last.trim();
  }

  Future<void> _playSourceResult(
    SourceResult chosen,
    MediaItem item,
    EpisodeItem? episode, {
    bool? hasCloudConnection,
  }) async {
    final cloudConnected = hasCloudConnection ??
        ((await widget.pikpak.isSignedIn) || (await widget.torbox.isConnected));
    final releaseHint = _sourceReleaseHint(chosen);

    if (!chosen.isMagnet) {
      if (!mounted) return;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Opening direct stream…';
      });
      await _openPlayerUrl(
        chosen.resource,
        item,
        episode,
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
      );
      return;
    }

    if (!cloudConnected) {
      if (!mounted) return;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Starting local P2P torrent stream…';
      });
      final localUrl = await LocalTorrentService.instance.resolve(chosen);
      if (!mounted) return;
      setState(() => _status = 'Torrent metadata ready — opening player…');
      await _openPlayerUrl(
        localUrl,
        item,
        episode,
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
      );
      return;
    }

    final cloud = await _chooseCloudProvider();
    if (cloud == null || !mounted) return;
    if (cloud == CloudProvider.torbox) {
      await _sendSourceToTorBox(chosen, item, episode);
    } else {
      await _sendSourceToPikPak(chosen, item, episode);
    }
  }

  Future<void> _playPinnedRelease(MediaItem item) async {
    if (_resolving || !mounted) return;
    final pinKey = widget.sources.sourceTargetKey(item);
    final pinned = await widget.sources.getPinnedSourcePreference(pinKey);
    if (pinned == null || !mounted) return;
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = 'Finding pinned release: ${pinned.label}…';
    });
    try {
      final results = await widget.sources.resolve(item);
      if (!mounted) return;
      SourceResult? match;
      for (final result in results) {
        if (widget.sources.matchesPinned(result, pinned.identity)) {
          match = result;
          break;
        }
      }
      if (match == null) {
        setState(() {
          _resolving = false;
          _resolveProgress = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Pinned release is not being returned by the current source providers right now: ${pinned.label}',
            ),
          ),
        );
        return;
      }
      await _playSourceResult(match, item, null);
    } catch (error) {
      _showPlayError(error);
    }
  }

"""
text = replace_once(text, helper_marker, helpers + helper_marker, "source playback helpers")

# exact file names flow into subtitle matching
text = replace_once(
    text,
    "    await _openPlayerUrl(url, item, episode);\n  }\n\n  Future<PikPakFile?> _findInPikPak(",
    """    await _openPlayerUrl(
      url,
      item,
      episode,
      releaseHint: file.name,
      expectedSizeBytes: file.size,
    );
  }

  Future<PikPakFile?> _findInPikPak(""",
    "TorBox existing item release hint",
)
text = replace_once(
    text,
    "      await _openPlayerUrl(url, item, episode);\n      return;\n    }\n    throw const TorBoxException(",
    """      await _openPlayerUrl(
        url,
        item,
        episode,
        releaseHint: file.name,
        expectedSizeBytes: file.size,
      );
      return;
    }
    throw const TorBoxException(""",
    "TorBox prepared release hint",
)
text = replace_once(
    text,
    "    await _openPlayerUrl(url, item, episode);\n  }\n\n  Future<void> _openPlayerUrl(",
    """    await _openPlayerUrl(
      url,
      item,
      episode,
      releaseHint: file.name,
    );
  }

  Future<void> _openPlayerUrl(""",
    "PikPak release hint",
)

new_open = """  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode, {
    String? releaseHint,
    int? expectedSizeBytes,
  }) async {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });

    final title = episode == null
        ? item.title
        : '${item.title} • ${episode.label} ${episode.title}';
    final next = _nextEpisode(item, episode);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          playback: widget.playback,
          url: url,
          title: title,
          mediaState: widget.mediaState,
          item: item,
          episode: episode,
          releaseHint: releaseHint,
          expectedSizeBytes: expectedSizeBytes,
          nextEpisodeLabel: next == null ? null : '${next.label} ${next.title}',
          onNext: next == null
              ? null
              : () async {
                  if (!mounted) return;
                  await _play(item, episode: next);
                },
        ),
      ),
    );
  }

"""
text = replace_between(text, "  Future<void> _openPlayerUrl(", "  EpisodeItem? _nextEpisode(", new_open, "open player no blocking AI")
path.write_text(text, encoding="utf-8")

# app/version
path = Path("lib/app.dart")
text = path.read_text(encoding="utf-8").replace("Orvix v0.7.3-alpha.2", "Orvix v0.7.3-alpha.3")
path.write_text(text, encoding="utf-8")

path = Path("pubspec.yaml")
text = path.read_text(encoding="utf-8").replace("version: 0.7.3-alpha.2+37", "version: 0.7.3-alpha.3+38")
path.write_text(text, encoding="utf-8")
