from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"Marker not found: {label}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Source preferences: result limit + per-title/episode pinned source identity.
# ---------------------------------------------------------------------------
p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')

s = replace_once(
    s,
    "  static const _preferredGroupsKey = 'orvix_preferred_release_groups_v1';\n",
    "  static const _preferredGroupsKey = 'orvix_preferred_release_groups_v1';\n"
    "  static const _resultLimitKey = 'orvix_source_result_limit_v1';\n"
    "  static const _pinnedSourcePrefix = 'orvix_pinned_source_v1_';\n"
    "  static const defaultResultLimit = 0; // 0 = show all\n"
    "  static const resultLimitOptions = <int>[25, 50, 100, 200, 0];\n",
    'source preference keys',
)

marker = """  Future<void> setPreferredGroups(List<String> values) async {
    final cleaned = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final v = value.trim();
      if (v.isEmpty) continue;
      final key = v.toLowerCase();
      if (seen.add(key)) cleaned.add(v);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_preferredGroupsKey, cleaned);
  }

"""
insert = marker + r'''  Future<int> getResultLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_resultLimitKey) ?? defaultResultLimit;
    return value < 0 ? defaultResultLimit : value.clamp(0, 500).toInt();
  }

  Future<void> setResultLimit(int value) async {
    final normalized = value < 0 ? defaultResultLimit : value.clamp(0, 500).toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_resultLimitKey, normalized);
  }

  String sourceTargetKey(MediaItem item, {EpisodeItem? episode}) {
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
        : result.title.split('\n').last.trim();
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

  String _pinPreferenceKey(String targetKey) => '$_pinnedSourcePrefix$targetKey';

  Future<String?> getPinnedSourceIdentity(String targetKey) async {
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

  Future<void> pinSource(String targetKey, SourceResult result) async {
    final prefs = await SharedPreferences.getInstance();
    final label = result.title.split('\n').last.trim();
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

  Future<void> unpinSource(String targetKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinPreferenceKey(targetKey));
  }

'''
s = replace_once(s, marker, insert, 'source preference methods')
p.write_text(s, encoding='utf-8')


# ---------------------------------------------------------------------------
# Source picker: persistent result count selector + pin/unpin button.
# ---------------------------------------------------------------------------
p = Path('lib/screens/details_screen.dart')
s = p.read_text(encoding='utf-8')

s = replace_once(
    s,
    "      final chosen = await _chooseSource(results);\n",
    "      final chosen = await _chooseSource(results, item, episode);\n",
    'choose source call',
)

s = replace_once(
    s,
    """  Future<SourceResult?> _chooseSource(List<SourceResult> results) async {
    var priority = await widget.sources.getPriorityOrder();
    var compatibilityOnly = false;
    if (!mounted) return null;
""",
    """  Future<SourceResult?> _chooseSource(
    List<SourceResult> results,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    var priority = await widget.sources.getPriorityOrder();
    var resultLimit = await widget.sources.getResultLimit();
    var compatibilityOnly = false;
    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
    var pinnedIdentity = await widget.sources.getPinnedSourceIdentity(pinKey);
    if (!mounted) return null;
""",
    'choose source signature',
)

s = replace_once(
    s,
    """          final ranked = widget.sources.sortResults(results, priority);
          final sorted = compatibilityOnly
              ? ranked.where((result) => result.compatibilityFriendly).toList(growable: false)
              : ranked;
          final hiddenCount = ranked.length - sorted.length;
          final best = sorted.isEmpty ? null : sorted.first;
          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
""",
    """          final ranked = widget.sources.sortResults(results, priority);
          final filtered = compatibilityOnly
              ? ranked.where((result) => result.compatibilityFriendly).toList(growable: false)
              : [...ranked];
          final compatibilityHiddenCount = ranked.length - filtered.length;

          final ordered = [...filtered];
          if (pinnedIdentity != null) {
            final pinnedIndex = ordered.indexWhere(
              (result) => widget.sources.matchesPinned(result, pinnedIdentity),
            );
            if (pinnedIndex > 0) {
              final pinned = ordered.removeAt(pinnedIndex);
              ordered.insert(0, pinned);
            }
          }

          final totalAfterFilter = ordered.length;
          final sorted = resultLimit > 0 && ordered.length > resultLimit
              ? ordered.take(resultLimit).toList(growable: false)
              : ordered;
          final limitHiddenCount = totalAfterFilter - sorted.length;
          final best = sorted.isEmpty ? null : sorted.first;
          final bestIsPinned = best != null &&
              widget.sources.matchesPinned(best, pinnedIdentity);
          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
          final summaryParts = <String>[
            resultLimit > 0
                ? 'Showing ${sorted.length} of $totalAfterFilter results'
                : '${sorted.length} result${sorted.length == 1 ? '' : 's'} shown',
            if (compatibilityHiddenCount > 0)
              '$compatibilityHiddenCount risky hidden',
            if (limitHiddenCount > 0) '$limitHiddenCount beyond limit',
          ];
""",
    'source picker result derivation',
)

s = replace_once(
    s,
    """                              Text(
                                compatibilityOnly
                                    ? '${sorted.length} compatible result${sorted.length == 1 ? '' : 's'}${hiddenCount > 0 ? ' • $hiddenCount risky hidden' : ''}'
                                    : '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',
                                style: TextStyle(color: color.onSurfaceVariant),
                              ),
""",
    """                              Text(
                                summaryParts.join(' • '),
                                style: TextStyle(color: color.onSurfaceVariant),
                              ),
""",
    'result summary text',
)

s = replace_once(
    s,
    """                        FilterChip(
                          selected: compatibilityOnly,
""",
    """                        PopupMenuButton<int>(
                          tooltip: 'Results shown',
                          initialValue: resultLimit,
                          onSelected: (value) async {
                            await widget.sources.setResultLimit(value);
                            if (!context.mounted) return;
                            setSheetState(() => resultLimit = value);
                          },
                          itemBuilder: (context) => [
                            for (final value in SourceProviderService.resultLimitOptions)
                              PopupMenuItem<int>(
                                value: value,
                                child: Row(
                                  children: [
                                    Icon(
                                      value == resultLimit
                                          ? Icons.check_rounded
                                          : Icons.format_list_numbered_rounded,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(value == 0 ? 'Show all results' : 'Show top $value'),
                                  ],
                                ),
                              ),
                          ],
                          child: Chip(
                            avatar: const Icon(Icons.format_list_numbered_rounded, size: 18),
                            label: Text(resultLimit == 0 ? 'All results' : 'Top $resultLimit'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilterChip(
                          selected: compatibilityOnly,
""",
    'result limit menu',
)

s = replace_once(
    s,
    """                            label: Text('Quick Play ${best.quality ?? ''}'.trim()),
""",
    """                            label: Text(
                              bestIsPinned
                                  ? 'Quick Play Pinned'
                                  : 'Quick Play ${best.quality ?? ''}'.trim(),
                            ),
""",
    'quick play pinned label',
)

s = replace_once(
    s,
    """                        itemBuilder: (context, index) {
                          final result = sorted[index];
                          return ListTile(
""",
    """                        itemBuilder: (context, index) {
                          final result = sorted[index];
                          final isPinned = widget.sources.matchesPinned(
                            result,
                            pinnedIdentity,
                          );
                          return ListTile(
""",
    'source row pinned state',
)

s = replace_once(
    s,
    """                            trailing: index == 0
                                ? const Chip(label: Text('Best'))
                                : const Icon(Icons.chevron_right_rounded),
                            onTap: () => Navigator.pop(sheetContext, result),
""",
    """                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isPinned)
                                  const Chip(
                                    avatar: Icon(Icons.push_pin_rounded, size: 16),
                                    label: Text('Pinned'),
                                  )
                                else if (index == 0)
                                  const Chip(label: Text('Best')),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: isPinned ? 'Unpin source' : 'Pin source',
                                  icon: Icon(
                                    isPinned
                                        ? Icons.push_pin_rounded
                                        : Icons.push_pin_outlined,
                                  ),
                                  onPressed: () async {
                                    if (isPinned) {
                                      await widget.sources.unpinSource(pinKey);
                                      if (!context.mounted) return;
                                      setSheetState(() => pinnedIdentity = null);
                                    } else {
                                      await widget.sources.pinSource(pinKey, result);
                                      final identity = widget.sources.sourceIdentity(result);
                                      if (!context.mounted) return;
                                      setSheetState(() => pinnedIdentity = identity);
                                    }
                                  },
                                ),
                              ],
                            ),
                            onTap: () => Navigator.pop(sheetContext, result),
""",
    'source row pin action',
)

p.write_text(s, encoding='utf-8')


# ---------------------------------------------------------------------------
# Version/changelog. Do not touch any Windows icon resources.
# ---------------------------------------------------------------------------
p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8')
s = replace_once(s, 'version: 0.5.5+25', 'version: 0.5.6+26', 'pubspec version')
p.write_text(s, encoding='utf-8')

p = Path('installer/orvix.iss')
s = p.read_text(encoding='utf-8')
s = replace_once(s, '#define MyAppVersion "0.5.5"', '#define MyAppVersion "0.5.6"', 'installer version')
p.write_text(s, encoding='utf-8')

p = Path('CHANGELOG.md')
s = p.read_text(encoding='utf-8')
entry = """# Orvix Changelog

## v0.5.6 — customizable source browser

- Added a persistent result-count selector in the source picker: Top 25 / 50 / 100 / 200 / All.
- Added per-title/per-episode source pinning. A pinned result is remembered, moved to the top when it is returned again, and becomes Quick Play's first choice.
- Pin identity uses torrent infohash + file index when available, avoiding fragile display-text matching for multi-file torrents.
- Compatibility filtering and the existing Cache → Quality → Resolution → Size → Seeders priority continue to apply; pinning only reorders results that survive the active filter.
- Kept the manually fixed Windows icon resources untouched.

"""
s = replace_once(s, '# Orvix Changelog\n\n', entry, 'changelog heading')
p.write_text(s, encoding='utf-8')
