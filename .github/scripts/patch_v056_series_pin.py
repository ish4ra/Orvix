from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f'Marker not found: {label}')
    return text.replace(old, new, 1)


p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')

s = replace_once(
    s,
    """    this.torrentFileIndex,
    this.fileNameHint,
  });
""",
    """    this.torrentFileIndex,
    this.fileNameHint,
    this.bingeGroup,
  });
""",
    'SourceResult constructor binge group',
)

s = replace_once(
    s,
    """  final String? fileNameHint;

  int get qualityRank {
""",
    """  final String? fileNameHint;

  /// Stable Stremio stream-family identifier when the addon provides one.
  /// Torrentio/other addons can keep this stable across episodes, which makes
  /// a series-wide pin possible without guessing from filenames.
  final String? bingeGroup;

  int get qualityRank {
""",
    'SourceResult binge group field',
)

s = replace_once(
    s,
    """  String sourceTargetKey(MediaItem item, {EpisodeItem? episode}) {
    final base = '${item.kind.name}:${item.id}';
    if (episode == null) return base;
    return '$base:${episode.season}:${episode.episode}';
  }

  String sourceIdentity(SourceResult result) {
    final provider = result.provider.trim().toLowerCase();
    if (result.isMagnet) {
      final match = RegExp(
        r'xt=urn:btih:([a-z0-9]+)',
        caseSensitive: false,
      ).firstMatch(result.resource);
      final hash = match?.group(1)?.toLowerCase();
      if (hash != null && hash.isNotEmpty) {
        return '$provider|btih:$hash|idx:${result.torrentFileIndex ?? -1}';
      }
    }

    final fileName = result.fileNameHint?.trim();
    final raw = fileName != null && fileName.isNotEmpty
        ? fileName
        : result.title.split('\\n').last.trim();
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (normalized.isNotEmpty) return '$provider|title:$normalized';
    return '$provider|resource:${result.resource}';
  }

  bool matchesPinned(SourceResult result, String? pinnedIdentity) {
    if (pinnedIdentity == null || pinnedIdentity.isEmpty) return false;
    return sourceIdentity(result) == pinnedIdentity;
  }
""",
    """  String sourceTargetKey(MediaItem item, {EpisodeItem? episode}) {
    // Movies keep one exact pin per title. TV keeps one source-family pin per
    // series, matching Debrify's source binding model while avoiding a separate
    // preference for every episode.
    return '${item.kind.name}:${item.id}';
  }

  String sourceIdentity(SourceResult result, {bool seriesWide = false}) {
    final provider = result.provider.trim().toLowerCase();

    final bingeGroup = result.bingeGroup?.trim();
    if (seriesWide && bingeGroup != null && bingeGroup.isNotEmpty) {
      final normalizedGroup = bingeGroup
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (normalizedGroup.isNotEmpty) {
        return '$provider|binge:$normalizedGroup';
      }
    }

    if (result.isMagnet) {
      final match = RegExp(
        r'xt=urn:btih:([a-z0-9]+)',
        caseSensitive: false,
      ).firstMatch(result.resource);
      final hash = match?.group(1)?.toLowerCase();
      if (hash != null && hash.isNotEmpty) {
        // A season/series pack has one infohash but a different file index for
        // each episode. Ignore the index for a series-wide pin so the same pack
        // stays preferred as the user moves through episodes.
        return seriesWide
            ? '$provider|btih:$hash'
            : '$provider|btih:$hash|idx:${result.torrentFileIndex ?? -1}';
      }
    }

    final fileName = result.fileNameHint?.trim();
    final raw = fileName != null && fileName.isNotEmpty
        ? fileName
        : result.title.split('\\n').last.trim();
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (normalized.isNotEmpty) return '$provider|title:$normalized';
    return '$provider|resource:${result.resource}';
  }

  bool matchesPinned(
    SourceResult result,
    String? pinnedIdentity, {
    bool seriesWide = false,
  }) {
    if (pinnedIdentity == null || pinnedIdentity.isEmpty) return false;
    return sourceIdentity(result, seriesWide: seriesWide) == pinnedIdentity;
  }
""",
    'series-aware pin identity',
)

s = replace_once(
    s,
    """  Future<void> pinSource(String targetKey, SourceResult result) async {
    final prefs = await SharedPreferences.getInstance();
    final label = result.title.split('\\n').last.trim();
    await prefs.setString(
      _pinPreferenceKey(targetKey),
      jsonEncode({
        'identity': sourceIdentity(result),
        'provider': result.provider,
        'label': label,
        'pinnedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }
""",
    """  Future<void> pinSource(
    String targetKey,
    SourceResult result, {
    bool seriesWide = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final label = result.title.split('\\n').last.trim();
    await prefs.setString(
      _pinPreferenceKey(targetKey),
      jsonEncode({
        'identity': sourceIdentity(result, seriesWide: seriesWide),
        'provider': result.provider,
        'label': label,
        if (result.bingeGroup != null) 'bingeGroup': result.bingeGroup,
        'pinnedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }
""",
    'series-aware pin storage',
)

s = replace_once(
    s,
    """        final fileNameHint = _nonEmpty(hints?['filename']?.toString());
        final torrentFileIndex = _parseInt(
""",
    """        final fileNameHint = _nonEmpty(hints?['filename']?.toString());
        final bingeGroup = _nonEmpty(
          hints?['bingeGroup']?.toString() ?? hints?['binge_group']?.toString(),
        );
        final torrentFileIndex = _parseInt(
""",
    'parse binge group',
)

s = replace_once(
    s,
    """            torrentFileIndex: torrentFileIndex,
            fileNameHint: fileNameHint,
          ),
""",
    """            torrentFileIndex: torrentFileIndex,
            fileNameHint: fileNameHint,
            bingeGroup: bingeGroup,
          ),
""",
    'store binge group',
)

p.write_text(s, encoding='utf-8')


p = Path('lib/screens/details_screen.dart')
s = p.read_text(encoding='utf-8')

s = replace_once(
    s,
    """    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
    var pinnedIdentity = await widget.sources.getPinnedSourceIdentity(pinKey);
""",
    """    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
    final seriesWidePin = item.kind == MediaKind.series;
    var pinnedIdentity = await widget.sources.getPinnedSourceIdentity(pinKey);
""",
    'series pin state',
)

s = s.replace(
    "widget.sources.matchesPinned(result, pinnedIdentity)",
    "widget.sources.matchesPinned(\n                result,\n                pinnedIdentity,\n                seriesWide: seriesWidePin,\n              )",
)

# The itemBuilder call is formatted across lines rather than as the one-liner above.
s = replace_once(
    s,
    """                          final isPinned = widget.sources.matchesPinned(
                            result,
                            pinnedIdentity,
                          );
""",
    """                          final isPinned = widget.sources.matchesPinned(
                            result,
                            pinnedIdentity,
                            seriesWide: seriesWidePin,
                          );
""",
    'row pin match',
)

s = replace_once(
    s,
    """                                      await widget.sources.pinSource(pinKey, result);
                                      final identity = widget.sources.sourceIdentity(result);
""",
    """                                      await widget.sources.pinSource(
                                        pinKey,
                                        result,
                                        seriesWide: seriesWidePin,
                                      );
                                      final identity = widget.sources.sourceIdentity(
                                        result,
                                        seriesWide: seriesWidePin,
                                      );
""",
    'pin action series-wide',
)

p.write_text(s, encoding='utf-8')


p = Path('CHANGELOG.md')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    '- Added per-title/per-episode source pinning. A pinned result is remembered, moved to the top when it is returned again, and becomes Quick Play\'s first choice.\n- Pin identity uses torrent infohash + file index when available, avoiding fragile display-text matching for multi-file torrents.\n',
    '- Added per-title source pinning for movies and series-wide source-family pinning for TV. A pinned result is remembered, moved to the top when it is returned again, and becomes Quick Play\'s first choice.\n- Series pins prefer Stremio `bingeGroup` when available and otherwise reuse the same torrent-pack infohash across episode file indexes, following Debrify-style source binding without guessing the wrong episode.\n',
    'changelog pin wording',
)
p.write_text(s, encoding='utf-8')
