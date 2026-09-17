from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f'Patch anchor not found: {label}')
    return text.replace(old, new, 1)


# --- Source ranking service -------------------------------------------------
service_path = Path('lib/services/source_provider_service.dart')
service = service_path.read_text(encoding='utf-8')
free_streaming_methods = r'''

  /// Playback ordering aimed at users who are not relying on a paid debrid
  /// cache. Seeder HEALTH is the strongest signal, but raw seeder counts do
  /// not grow forever: once a swarm is healthy, release quality and resolution
  /// decide the order so a heavily-seeded low-quality encode cannot dominate.
  List<SourceResult> sortForFreeStreaming(Iterable<SourceResult> results) {
    final out = results.toList();
    out.sort(_compareFreeStreaming);
    return out;
  }

  int _compareFreeStreaming(SourceResult a, SourceResult b) {
    final scoreCmp = _freeStreamingScore(b).compareTo(_freeStreamingScore(a));
    if (scoreCmp != 0) return scoreCmp;

    // Inside the same health/quality bucket, prefer the stronger swarm.
    final seedCmp = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
    if (seedCmp != 0) return seedCmp;

    // Then prefer the smaller payload as a final bandwidth-friendly tie break.
    final aSize = a.sizeBytes;
    final bSize = b.sizeBytes;
    if (aSize != null && bSize != null && aSize != bSize) {
      return aSize.compareTo(bSize);
    }
    if (aSize != null && bSize == null) return -1;
    if (aSize == null && bSize != null) return 1;

    return a.title.compareTo(b.title);
  }

  int _freeStreamingScore(SourceResult result) {
    final seedHealth = _freeSeederHealthRank(result.seeders);
    final release = _freeReleaseRank(result);
    final resolution = _freeResolutionRank(result);
    final size = _freeSizeEfficiencyRank(result);
    final compatibility = result.compatibilityFriendly ? 1 : 0;

    // Seeder health dominates. The remaining factors refine results within a
    // health tier instead of allowing a 300-seeder CAM/480p row to win merely
    // because its raw seeder number is enormous.
    return seedHealth * 100000 +
        release * 1000 +
        resolution * 100 +
        size * 10 +
        compatibility;
  }

  int _freeSeederHealthRank(int? seeders) {
    final value = seeders ?? 0;
    if (value >= 100) return 6;
    if (value >= 50) return 5;
    if (value >= 25) return 4;
    if (value >= 10) return 3;
    if (value >= 3) return 2;
    if (value >= 1) return 1;
    return 0;
  }

  int _freeReleaseRank(SourceResult result) {
    var rank = switch (result.releaseQuality?.toUpperCase()) {
      'WEB-DL' => 8,
      'WEBRIP' => 7,
      'BLURAY' => 7,
      'HDTV' => 5,
      // Remux is excellent quality but commonly too large for free real-time
      // torrent playback, so it deliberately sits below efficient encodes.
      'REMUX' => 4,
      'DVD' => 2,
      'CAM' => 0,
      _ => 3,
    };
    if (result.preferredGroup) rank += 1;
    return rank;
  }

  int _freeResolutionRank(SourceResult result) {
    switch (result.quality?.toUpperCase()) {
      case '1080P':
        return 6;
      case '720P':
        return 5;
      case '1440P':
        return 4;
      case '2160P':
      case '4K':
        return 3;
      case '480P':
        return 1;
      default:
        return 2;
    }
  }

  int _freeSizeEfficiencyRank(SourceResult result) {
    final bytes = result.sizeBytes;
    if (bytes == null || bytes <= 0) return 3;
    const gb = 1024 * 1024 * 1024;
    if (bytes < 150 * 1024 * 1024) return 1;
    if (bytes <= 8 * gb) return 5;
    if (bytes <= 15 * gb) return 4;
    if (bytes <= 30 * gb) return 2;
    return 0;
  }
'''
service = replace_once(
    service,
    '\n  Future<void> addAddonUrl(String raw) async {\n',
    free_streaming_methods + '\n  Future<void> addAddonUrl(String raw) async {\n',
    'insert free streaming ranking',
)
service_path.write_text(service, encoding='utf-8')


# --- Source Engine settings -------------------------------------------------
settings_path = Path('lib/screens/sources_screen.dart')
settings = settings_path.read_text(encoding='utf-8')
settings = replace_once(
    settings,
    '  bool _showLowQuality = false;\n  String? _message;\n',
    '  bool _showLowQuality = false;\n  int _resultLimit = SourceProviderService.defaultResultLimit;\n  String? _message;\n',
    'settings result limit state',
)
settings = replace_once(
    settings,
    '    final showLowQuality = await widget.sources.getShowLowQuality();\n    if (!mounted) return;\n',
    '    final showLowQuality = await widget.sources.getShowLowQuality();\n    final resultLimit = await widget.sources.getResultLimit();\n    if (!mounted) return;\n',
    'load result limit',
)
settings = replace_once(
    settings,
    '      _showLowQuality = showLowQuality;\n      _preferredGroupsController.text = preferredGroups.join(\', \');\n',
    '      _showLowQuality = showLowQuality;\n      _resultLimit = resultLimit;\n      _preferredGroupsController.text = preferredGroups.join(\', \');\n',
    'store result limit state',
)
settings = replace_once(
    settings,
    '''  Future<void> _setShowLowQuality(bool value) async {
    setState(() => _showLowQuality = value);
    await widget.sources.setShowLowQuality(value);
  }

''',
    '''  Future<void> _setShowLowQuality(bool value) async {
    setState(() => _showLowQuality = value);
    await widget.sources.setShowLowQuality(value);
  }

  Future<void> _setResultLimit(int value) async {
    setState(() => _resultLimit = value);
    await widget.sources.setResultLimit(value);
  }

''',
    'result limit setter',
)
settings = replace_once(
    settings,
    '''          const SizedBox(height: 10),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _show3D,
''',
    '''          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Results shown in source picker',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose how many ranked sources are displayed when you open the source picker.',
                      style: TextStyle(
                        color: color.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              DropdownButton<int>(
                value: _resultLimit,
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final value in SourceProviderService.resultLimitOptions)
                    DropdownMenuItem<int>(
                      value: value,
                      child: Text(value == 0 ? 'All results' : 'Top $value'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) _setResultLimit(value);
                      },
              ),
            ],
          ),
          const Divider(height: 26),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _show3D,
''',
    'settings result limit control',
)
settings_path.write_text(settings, encoding='utf-8')


# --- Source picker ----------------------------------------------------------
details_path = Path('lib/screens/details_screen.dart')
details = details_path.read_text(encoding='utf-8')
details = replace_once(
    details,
    '    var compatibilityOnly = false;\n    var smoothRanking = false;\n',
    '    var compatibilityOnly = false;\n    var smoothRanking = false;\n    var freeStreamingRanking = false;\n',
    'free streaming modal state',
)
details = replace_once(
    details,
    '''          final ranked = smoothRanking
              ? widget.sources.sortForSmoothPlayback(results)
              : widget.sources.sortResults(results, priority);
''',
    '''          final ranked = freeStreamingRanking
              ? widget.sources.sortForFreeStreaming(results)
              : smoothRanking
                  ? widget.sources.sortForSmoothPlayback(results)
                  : widget.sources.sortResults(results, priority);
''',
    'free streaming sorter',
)
details = replace_once(
    details,
    '''          final rankingText = smoothRanking
              ? 'Smooth: compatibility → 1080/720 → efficient codec → seeders → smaller files → cache'
              : 'Priority: $priorityText';
''',
    '''          final rankingText = freeStreamingRanking
              ? 'Free Streaming: seed health → quality → resolution → efficient size → compatibility'
              : smoothRanking
                  ? 'Smooth: compatibility → 1080/720 → efficient codec → seeders → smaller files → cache'
                  : 'Priority: $priorityText';
''',
    'free streaming ranking label',
)
details = replace_once(
    details,
    "            if (smoothRanking) 'smooth ranking on',\n",
    "            if (freeStreamingRanking) 'free streaming ranking on',\n            if (smoothRanking) 'smooth ranking on',\n",
    'free streaming summary',
)
start_marker = '                        PopupMenuButton<int>(\n'
end_marker = '                        FilterChip(\n                          selected: compatibilityOnly,\n'
start = details.find(start_marker)
end = details.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('Patch anchor not found: result-limit popup')
free_chip = '''                        FilterChip(
                          selected: freeStreamingRanking,
                          avatar: const Icon(Icons.bolt_rounded, size: 18),
                          label: const Text('Free Streaming'),
                          tooltip: 'Prioritize sources likely to stream smoothly without a paid debrid service: healthy seed swarms first, then quality, resolution, manageable size and compatibility.',
                          onSelected: (value) => setSheetState(() {
                            freeStreamingRanking = value;
                            if (value) smoothRanking = false;
                          }),
                        ),
                        const SizedBox(width: 10),
'''
details = details[:start] + free_chip + details[end:]
details = replace_once(
    details,
    '''                          onSelected: (value) =>
                              setSheetState(() => smoothRanking = value),
''',
    '''                          onSelected: (value) => setSheetState(() {
                            smoothRanking = value;
                            if (value) freeStreamingRanking = false;
                          }),
''',
    'mutually exclusive smooth/free streaming',
)
details = replace_once(
    details,
    "                                      smoothRanking ? 'Smooth' : 'Best',\n",
    "                                      freeStreamingRanking\n                                          ? 'Free Stream'\n                                          : smoothRanking\n                                              ? 'Smooth'\n                                              : 'Best',\n",
    'free streaming best badge',
)
details_path.write_text(details, encoding='utf-8')


# --- Version ----------------------------------------------------------------
pubspec_path = Path('pubspec.yaml')
pubspec = pubspec_path.read_text(encoding='utf-8')
pubspec = replace_once(
    pubspec,
    'version: 0.5.8+28',
    'version: 0.5.9+29',
    'version bump',
)
pubspec_path.write_text(pubspec, encoding='utf-8')

# The helper/workflow are intentionally one-shot and must not land on main.
for temporary in [
    Path('tool/v059_patch.py'),
    Path('.github/workflows/orvix-v059-release-once.yml'),
]:
    if temporary.exists():
        temporary.unlink()
