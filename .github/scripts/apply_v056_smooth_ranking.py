from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


source_path = Path('lib/services/source_provider_service.dart')
source = source_path.read_text(encoding='utf-8')

sort_anchor = """  List<SourceResult> sortResults(
    Iterable<SourceResult> results,
    List<SourceSortCriterion> priority,
  ) {
    final out = results.toList();
    out.sort((a, b) => compareResults(a, b, priority));
    return out;
  }

  Future<void> addAddonUrl(String raw) async {
"""

sort_replacement = """  List<SourceResult> sortResults(
    Iterable<SourceResult> results,
    List<SourceSortCriterion> priority,
  ) {
    final out = results.toList();
    out.sort((a, b) => compareResults(a, b, priority));
    return out;
  }

  /// Optional playback-focused ordering for users who care more about a
  /// stream starting and staying smooth than about the normal release-size
  /// preference. Nothing is hidden here; this only changes the order.
  ///
  /// The order deliberately favors common 1080p/720p playback targets,
  /// efficient HEVC/x265 encodes, healthy swarms, then smaller files. Cache is
  /// still useful, but it is not allowed to dominate playback characteristics.
  List<SourceResult> sortForSmoothPlayback(Iterable<SourceResult> results) {
    final out = results.toList();
    out.sort(_compareSmoothPlayback);
    return out;
  }

  int _compareSmoothPlayback(SourceResult a, SourceResult b) {
    final riskCmp = a.compatibilityRisk.compareTo(b.compatibilityRisk);
    if (riskCmp != 0) return riskCmp;

    final resolutionCmp =
        _smoothResolutionRank(b).compareTo(_smoothResolutionRank(a));
    if (resolutionCmp != 0) return resolutionCmp;

    final codecCmp = _smoothCodecRank(b).compareTo(_smoothCodecRank(a));
    if (codecCmp != 0) return codecCmp;

    final seedCmp = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
    if (seedCmp != 0) return seedCmp;

    final aSize = a.sizeBytes;
    final bSize = b.sizeBytes;
    if (aSize != null && bSize != null && aSize != bSize) {
      return aSize.compareTo(bSize);
    }
    if (aSize != null && bSize == null) return -1;
    if (aSize == null && bSize != null) return 1;

    final cacheCmp = (b.cached ? 1 : 0).compareTo(a.cached ? 1 : 0);
    if (cacheCmp != 0) return cacheCmp;

    final releaseCmp = b.releaseQualityRank.compareTo(a.releaseQualityRank);
    if (releaseCmp != 0) return releaseCmp;

    return a.title.compareTo(b.title);
  }

  int _smoothResolutionRank(SourceResult result) {
    switch (result.quality?.toUpperCase()) {
      case '1080P':
        return 600;
      case '720P':
        return 560;
      case '1440P':
        return 520;
      case '2160P':
      case '4K':
        return 480;
      case '480P':
        return 300;
      default:
        return 200;
    }
  }

  int _smoothCodecRank(SourceResult result) {
    final text = '${result.title} ${result.fileNameHint ?? ''}'.toLowerCase();
    if (RegExp(r'\\b(?:x265|h[ ._-]?265|hevc)\\b').hasMatch(text)) {
      return 300;
    }
    if (RegExp(r'\\b(?:x264|h[ ._-]?264|avc)\\b').hasMatch(text)) {
      return 250;
    }
    if (RegExp(r'\\b(?:av1|av01)\\b').hasMatch(text)) {
      return 100;
    }
    return 180;
  }

  Future<void> addAddonUrl(String raw) async {
"""

source = replace_once(
    source,
    sort_anchor,
    sort_replacement,
    'source smooth sorting insertion',
)
source_path.write_text(source, encoding='utf-8')


details_path = Path('lib/screens/details_screen.dart')
details = details_path.read_text(encoding='utf-8')

details = replace_once(
    details,
    """    var resultLimit = await widget.sources.getResultLimit();
    var compatibilityOnly = false;
    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
""",
    """    var resultLimit = await widget.sources.getResultLimit();
    var compatibilityOnly = false;
    var smoothRanking = false;
    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
""",
    'smooth state',
)

details = replace_once(
    details,
    """          final ranked = widget.sources.sortResults(results, priority);
          final filtered = compatibilityOnly
              ? ranked.where((result) => result.compatibilityFriendly).toList(growable: false)
              : [...ranked];
          final compatibilityHiddenCount = ranked.length - filtered.length;
""",
    """          final ranked = smoothRanking
              ? widget.sources.sortForSmoothPlayback(results)
              : widget.sources.sortResults(results, priority);
          final filtered = compatibilityOnly
              ? ranked
                  .where((result) => result.compatibilityFriendly)
                  .toList(growable: false)
              : [...ranked];
          final compatibilityHiddenCount = ranked.length - filtered.length;
""",
    'smooth ranked list',
)

details = replace_once(
    details,
    """          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
          final summaryParts = <String>[
""",
    """          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
          final rankingText = smoothRanking
              ? 'Smooth: compatibility → 1080/720 → efficient codec → seeders → smaller files → cache'
              : 'Priority: $priorityText';
          final summaryParts = <String>[
""",
    'smooth ranking label',
)

details = replace_once(
    details,
    """            if (compatibilityHiddenCount > 0)
              '$compatibilityHiddenCount risky hidden',
            if (limitHiddenCount > 0) '$limitHiddenCount beyond limit',
""",
    """            if (smoothRanking) 'smooth ranking on',
            if (compatibilityHiddenCount > 0)
              '$compatibilityHiddenCount risky hidden',
            if (limitHiddenCount > 0) '$limitHiddenCount beyond limit',
""",
    'smooth summary',
)

compatibility_block = """                        FilterChip(
                          selected: compatibilityOnly,
                          avatar: Icon(
                            compatibilityOnly
                                ? Icons.verified_rounded
                                : Icons.verified_outlined,
                            size: 18,
                          ),
                          label: const Text('Compatibility'),
                          tooltip: 'Hide known-risk formats such as AV1, 8K, Hi10P and Dolby Vision-only releases. File size is not used.',
                          onSelected: (value) =>
                              setSheetState(() => compatibilityOnly = value),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
"""

compatibility_replacement = """                        FilterChip(
                          selected: compatibilityOnly,
                          avatar: Icon(
                            compatibilityOnly
                                ? Icons.verified_rounded
                                : Icons.verified_outlined,
                            size: 18,
                          ),
                          label: const Text('Compatibility'),
                          tooltip: 'Hide known-risk formats such as AV1, 8K, Hi10P and Dolby Vision-only releases. File size is not used.',
                          onSelected: (value) =>
                              setSheetState(() => compatibilityOnly = value),
                        ),
                        const SizedBox(width: 10),
                        FilterChip(
                          selected: smoothRanking,
                          avatar: Icon(
                            smoothRanking
                                ? Icons.speed_rounded
                                : Icons.speed_outlined,
                            size: 18,
                          ),
                          label: const Text('Smooth'),
                          tooltip: 'Prioritize likely smoother playback: compatible formats, 1080p/720p, efficient x265/HEVC encodes, stronger seed counts and then smaller files. Results are reordered, not hidden.',
                          onSelected: (value) =>
                              setSheetState(() => smoothRanking = value),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
"""

details = replace_once(
    details,
    compatibility_block,
    compatibility_replacement,
    'smooth chip',
)

details = replace_once(
    details,
    """                              'Priority: $priorityText',
""",
    """                              rankingText,
""",
    'ranking banner',
)

details = replace_once(
    details,
    """                                else if (index == 0)
                                  const Chip(label: Text('Best')),
""",
    """                                else if (index == 0)
                                  Chip(
                                    label: Text(
                                      smoothRanking ? 'Smooth' : 'Best',
                                    ),
                                  ),
""",
    'first result chip',
)

details_path.write_text(details, encoding='utf-8')


changelog_path = Path('CHANGELOG.md')
changelog = changelog_path.read_text(encoding='utf-8')
changelog = replace_once(
    changelog,
    """## v0.5.6 — customizable source browser

- Added a persistent result-count selector in the source picker: Top 25 / 50 / 100 / 200 / All.
""",
    """## v0.5.6 — customizable source browser

- Added a **Smooth** source-ranking toggle that prioritizes likely easier-to-stream results instead of the normal size-descending priority: compatible formats first, then 1080p/720p, efficient x265/HEVC encodes, stronger seed counts, smaller files and cache. It only reorders results; it does not hide large releases.
- Added a persistent result-count selector in the source picker: Top 25 / 50 / 100 / 200 / All.
""",
    'changelog smooth bullet',
)
changelog_path.write_text(changelog, encoding='utf-8')
