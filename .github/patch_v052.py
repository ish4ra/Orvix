from pathlib import Path

source_path = Path('lib/services/source_provider_service.dart')
lines = source_path.read_text(encoding='utf-8').splitlines()

def find_line(text, start=0):
    for i in range(start, len(lines)):
        if lines[i].strip() == text:
            return i
    raise SystemExit(f'Line not found: {text}')

# Source priority enum + labels.
i = find_line('enum SourceSortCriterion { releaseQuality, resolution, seeders, fileSize }')
lines[i] = 'enum SourceSortCriterion { cache, releaseQuality, resolution, fileSize, seeders }'

start = find_line('extension SourceSortCriterionLabel on SourceSortCriterion {')
end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == '}' and lines[i - 1].strip() == '}')
lines[start:end + 1] = '''extension SourceSortCriterionLabel on SourceSortCriterion {
  String get label {
    switch (this) {
      case SourceSortCriterion.cache:
        return 'Cache';
      case SourceSortCriterion.releaseQuality:
        return 'Quality';
      case SourceSortCriterion.resolution:
        return 'Resolution';
      case SourceSortCriterion.fileSize:
        return 'Size';
      case SourceSortCriterion.seeders:
        return 'Seeders';
    }
  }
}'''.splitlines()

for i in range(len(lines) - 1):
    if lines[i].strip() == 'case SourceSortMode.quality:' and lines[i + 1].strip() == "return 'Source type';":
        lines[i + 1] = "        return 'Quality';"
        break

# Cache field on SourceResult.
i = find_line('this.preferredGroup = false,')
lines.insert(i + 1, '    this.cached = false,')
i = find_line('final bool preferredGroup;')
lines.insert(i + 1, '  final bool cached;')

# New default order and preference key migration.
i = find_line("static const _priorityKey = 'orvix_source_priority_v4';")
lines[i] = "  static const _priorityKey = 'orvix_source_priority_v5';"
i = find_line('static const defaultPriority = <SourceSortCriterion>[')
end = next(j for j in range(i + 1, len(lines)) if lines[j].strip() == '];')
lines[i:end + 1] = '''  static const defaultPriority = <SourceSortCriterion>[
    SourceSortCriterion.cache,
    SourceSortCriterion.releaseQuality,
    SourceSortCriterion.resolution,
    SourceSortCriterion.fileSize,
    SourceSortCriterion.seeders,
  ];'''.splitlines()

# Lexicographic comparator used by the source browser.
i = find_line('int _criterionValue(SourceResult result, SourceSortCriterion criterion) {')
switch_i = find_line('switch (criterion) {', i)
end = next(j for j in range(switch_i + 1, len(lines)) if lines[j].strip() == '}' and j + 1 < len(lines) and lines[j + 1].strip() == '}')
lines[switch_i:end + 1] = '''    switch (criterion) {
      case SourceSortCriterion.cache:
        return result.cached ? 1 : 0;
      case SourceSortCriterion.releaseQuality:
        return result.releaseQualityRank + (result.preferredGroup ? 50 : 0);
      case SourceSortCriterion.resolution:
        return result.qualityRank;
      case SourceSortCriterion.fileSize:
        return result.sizeBytes ?? 0;
      case SourceSortCriterion.seeders:
        return result.seeders ?? -1;
    }'''.splitlines()

# Resolve cache/instant metadata.
i = find_line('final sizeBytes = _guessSizeBytes(raw, metadataText);')
indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
lines.insert(i + 1, indent + 'final cacheHint = _guessCached(raw, hints, metadataText);')

i = find_line('if (resource == null) continue;')
indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
lines.insert(i + 1, indent + 'final cached = cacheHint || !isMagnet;')

i = find_line('final statParts = <String>[')
end = next(j for j in range(i + 1, len(lines)) if lines[j].strip() == '];')
indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
inner = indent + '  '
lines[i:end + 1] = [
    indent + 'final statParts = <String>[',
    inner + "if (cached) '⚡ Cached',",
    inner + "if (releaseQuality != null) '🎞 $releaseQuality',",
    inner + "if (quality != null) '📺 $quality',",
    inner + "'💾 ${_formatSize(sizeBytes) ?? 'size unknown'}',",
    inner + "'👥 ${seeders?.toString() ?? '—'} seeders',",
    inner + "if (preferredGroup) '⭐ Preferred',",
    indent + '];',
]

assignments = [i for i, line in enumerate(lines) if line.strip() == 'preferredGroup: preferredGroup,']
if not assignments:
    raise SystemExit('SourceResult assignment not found')
i = assignments[-1]
indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
lines.insert(i + 1, indent + 'cached: cached,')

# Helper supports common Stremio/debrid cache hints and direct streams.
i = find_line('String? _guessReleaseQuality(String value) {')
helper = '''  bool _guessCached(
    Map<String, dynamic> raw,
    Map<String, dynamic>? hints,
    String value,
  ) {
    final candidates = <dynamic>[
      raw['cached'],
      raw['isCached'],
      raw['is_cached'],
      raw['instant'],
      raw['instantAvailability'],
      raw['instant_availability'],
      hints?['cached'],
      hints?['isCached'],
      hints?['is_cached'],
      hints?['instant'],
      hints?['instantAvailability'],
      hints?['instant_availability'],
    ];
    for (final candidate in candidates) {
      if (_truthy(candidate)) return true;
    }
    final lower = value.toLowerCase();
    if (lower.contains('cached')) return true;
    return RegExp(
      r'(^|[\\s._\\-\\[\\(])(?:rd|ad|tb|pm)\\+(?=$|[\\s._\\-\\]\\)])',
      caseSensitive: false,
    ).hasMatch(value);
  }

  bool _truthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value > 0;
    final normalized = value?.toString().trim().toLowerCase();
    return const {'true', '1', 'yes', 'cached', 'instant', 'available'}
        .contains(normalized);
  }
'''.splitlines()
lines[i:i] = helper

source_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')

# Source screen text.
p = Path('lib/screens/sources_screen.dart')
t = p.read_text(encoding='utf-8')
old = 'Drag to choose exactly how sources are ranked. Default is resolution → source type → file size → seeders.'
new = 'Drag to choose exactly how sources are ranked. Default is cache → quality → resolution → size → seeders.'
if old not in t:
    raise SystemExit('Source priority help text not found')
p.write_text(t.replace(old, new, 1), encoding='utf-8')

# Version bump.
p = Path('pubspec.yaml')
t = p.read_text(encoding='utf-8')
if 'version: 0.5.1+21' not in t:
    raise SystemExit('pubspec version not found')
p.write_text(t.replace('version: 0.5.1+21', 'version: 0.5.2+22', 1), encoding='utf-8')

# Installer: setup already points at generated ICO; make shortcuts explicit too.
p = Path('installer/orvix.iss')
t = p.read_text(encoding='utf-8')
t = t.replace('#define MyAppVersion "0.5.0"', '#define MyAppVersion "0.5.2"', 1)
t = t.replace('Name: "{autoprograms}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"',
              'Name: "{autoprograms}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\\{#MyAppExeName}"', 1)
t = t.replace('Name: "{autodesktop}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon',
              'Name: "{autodesktop}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\\{#MyAppExeName}"; Tasks: desktopicon', 1)
p.write_text(t, encoding='utf-8')

# Changelog.
p = Path('CHANGELOG.md')
t = p.read_text(encoding='utf-8')
marker = '# Orvix Changelog\n\n'
entry = '''## v0.5.2 — source priority & app icon\n\n- Default source ranking is now **Cache → Quality → Resolution → Size → Seeders**.\n- Added cache/instant metadata detection and an ⚡ Cached source badge.\n- Replaced the Orvix branding source with the supplied app icon and wired it through the Windows executable, installer and shortcuts.\n- Bumped the app to 0.5.2+22.\n\n'''
if '## v0.5.2 — source priority & app icon' not in t:
    p.write_text(t.replace(marker, marker + entry, 1), encoding='utf-8')
