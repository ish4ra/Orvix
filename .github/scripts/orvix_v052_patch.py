from pathlib import Path
import base64
import re


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)

service_path = Path("lib/services/source_provider_service.dart")
s = service_path.read_text(encoding="utf-8")

s = replace_once(
    s,
    "enum SourceSortCriterion { releaseQuality, resolution, seeders, fileSize }",
    "enum SourceSortCriterion { cache, releaseQuality, resolution, fileSize, seeders }",
    "criterion enum",
)

s = replace_once(
    s,
    """extension SourceSortCriterionLabel on SourceSortCriterion {
  String get label {
    switch (this) {
      case SourceSortCriterion.releaseQuality:
        return 'Source type';
      case SourceSortCriterion.resolution:
        return 'Resolution';
      case SourceSortCriterion.seeders:
        return 'Seeders';
      case SourceSortCriterion.fileSize:
        return 'File size';
    }
  }
}""",
    """extension SourceSortCriterionLabel on SourceSortCriterion {
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
}""",
    "criterion labels",
)

s = replace_once(
    s,
    """    this.releaseQuality,
    this.preferredGroup = false,
    this.seeders,""",
    """    this.releaseQuality,
    this.preferredGroup = false,
    this.cached = false,
    this.seeders,""",
    "SourceResult constructor",
)

s = replace_once(
    s,
    """  final String? releaseQuality;
  final bool preferredGroup;
  final int? seeders;""",
    """  final String? releaseQuality;
  final bool preferredGroup;
  final bool cached;
  final int? seeders;""",
    "SourceResult cached field",
)

preference_pattern = re.compile(
    r"""  /// Ranking is deliberately lexicographic rather than a vague weighted mix\.\n"""
    r"""  /// Quality mode means exactly: quality > seeders > size\.\n"""
    r"""  int get preferenceScore \{.*?\n  \}\n\}""",
    re.S,
)
replacement = """  /// Auto-pick follows the same default priority shown in Source Engine:
  /// cache -> quality/source type -> resolution -> size -> seeders.
  int get preferenceScore {
    final cacheRank = cached ? 1 : 0;
    final seederRank = (seeders ?? -1).clamp(-1, 999999).toInt() + 1;
    final sizeMb = ((sizeBytes ?? 0) ~/ (1024 * 1024))
        .clamp(0, 999999)
        .toInt();

    return cacheRank * 1000000000000000000 +
        releaseQualityRank * 1000000000000000 +
        qualityRank * 1000000000000 +
        sizeMb * 1000000 +
        seederRank;
  }
}"""
s, count = preference_pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit(f"preferenceScore: expected 1 match, found {count}")

s = replace_once(
    s,
    "static const _priorityKey = 'orvix_source_priority_v4';",
    "static const _priorityKey = 'orvix_source_priority_v5';",
    "priority key",
)

s = replace_once(
    s,
    """  static const defaultPriority = <SourceSortCriterion>[
    SourceSortCriterion.releaseQuality,
    SourceSortCriterion.resolution,
    SourceSortCriterion.seeders,
    SourceSortCriterion.fileSize,
  ];""",
    """  static const defaultPriority = <SourceSortCriterion>[
    SourceSortCriterion.cache,
    SourceSortCriterion.releaseQuality,
    SourceSortCriterion.resolution,
    SourceSortCriterion.fileSize,
    SourceSortCriterion.seeders,
  ];""",
    "default priority",
)

s = replace_once(
    s,
    """    switch (criterion) {
      case SourceSortCriterion.releaseQuality:""",
    """    switch (criterion) {
      case SourceSortCriterion.cache:
        return result.cached ? 1 : 0;
      case SourceSortCriterion.releaseQuality:""",
    "criterion comparator",
)

metadata_anchor = """        final metadataText = <String>[
          raw['name']?.toString() ?? '',
          rawTitle,
          fileNameHint ?? '',
        ].where((value) => value.trim().isNotEmpty).join('\\n');
        if (!show3D && _is3DRelease(metadataText)) continue;"""
metadata_new = """        final metadataText = <String>[
          raw['name']?.toString() ?? '',
          rawTitle,
          fileNameHint ?? '',
        ].where((value) => value.trim().isNotEmpty).join('\\n');
        final cached = _guessCached(raw, metadataText);
        if (!show3D && _is3DRelease(metadataText)) continue;"""
s = replace_once(s, metadata_anchor, metadata_new, "cached detection")

s = replace_once(
    s,
    """        final statParts = <String>[
          if (preferredGroup) '⭐ Preferred',""",
    """        final statParts = <String>[
          if (cached) '⚡ Cached',
          if (preferredGroup) '⭐ Preferred',""",
    "cached badge",
)

s = replace_once(
    s,
    """            releaseQuality: releaseQuality,
            preferredGroup: preferredGroup,
            seeders: seeders,""",
    """            releaseQuality: releaseQuality,
            preferredGroup: preferredGroup,
            cached: cached,
            seeders: seeders,""",
    "cached SourceResult value",
)

helper_anchor = """  String? _guessReleaseQuality(String value) {"""
helper = r"""  bool _guessCached(Map<String, dynamic> raw, String value) {
    final hints = raw['behaviorHints'];
    final candidates = <dynamic>[
      raw['cached'],
      raw['isCached'],
      raw['is_cached'],
      if (hints is Map<String, dynamic>) hints['cached'],
      if (hints is Map<String, dynamic>) hints['isCached'],
      if (hints is Map<String, dynamic>) hints['is_cached'],
    ];

    for (final candidate in candidates) {
      if (candidate is bool) return candidate;
      final normalized = candidate?.toString().trim().toLowerCase();
      if (normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'cached') {
        return true;
      }
    }

    return RegExp(
      r'(^|[\s|•\[\(])(cached|rd\+|ad\+|tb\+|pm\+)(?=$|[\s|•\]\)])',
      caseSensitive: false,
    ).hasMatch(value);
  }

  String? _guessReleaseQuality(String value) {"""
s = replace_once(s, helper_anchor, helper, "cached helper")
service_path.write_text(s, encoding="utf-8")

screen_path = Path("lib/screens/sources_screen.dart")
screen = screen_path.read_text(encoding="utf-8")
screen = replace_once(
    screen,
    "Default is resolution → source type → file size → seeders.",
    "Default is cache → quality → resolution → file size → seeders.",
    "source priority help text",
)
screen_path.write_text(screen, encoding="utf-8")

pubspec_path = Path("pubspec.yaml")
pubspec = pubspec_path.read_text(encoding="utf-8")
pubspec = replace_once(pubspec, "version: 0.5.1+21", "version: 0.5.2+22", "pubspec version")
pubspec_path.write_text(pubspec, encoding="utf-8")

installer_path = Path("installer/orvix.iss")
installer = installer_path.read_text(encoding="utf-8")
installer = replace_once(installer, '#define MyAppVersion "0.5.0"', '#define MyAppVersion "0.5.2"', "installer version")
installer = replace_once(
    installer,
    'Name: "{autoprograms}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"',
    'Name: "{autoprograms}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\\{#MyAppExeName}"',
    "start menu icon",
)
installer = replace_once(
    installer,
    'Name: "{autodesktop}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon',
    'Name: "{autodesktop}\\Orvix"; Filename: "{app}\\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\\{#MyAppExeName}"; Tasks: desktopicon',
    "desktop icon",
)
installer_path.write_text(installer, encoding="utf-8")

changelog_path = Path("CHANGELOG.md")
changelog = changelog_path.read_text(encoding="utf-8")
entry = """# Orvix Changelog

## v0.5.2 — cache-first source ordering & refreshed icon

- Source ranking now defaults to Cache → Quality → Resolution → Size → Seeders.
- Added cache detection from structured add-on metadata and common cached debrid stream labels, plus a visible ⚡ Cached badge.
- Auto-pick ranking follows the same cache-first order as the Source Engine list.
- Replaced the packaged Orvix app icon with the supplied green Orvix artwork and regenerated Windows executable/installer icon assets.
- Reset the stored source-priority key so existing installs receive the new default order once.

"""
if "## v0.5.2 — cache-first source ordering & refreshed icon" not in changelog:
    if not changelog.startswith("# Orvix Changelog\n"):
        raise SystemExit("CHANGELOG header not found")
    changelog = entry + changelog[len("# Orvix Changelog\n"):]
changelog_path.write_text(changelog, encoding="utf-8")

icon_b64 = Path(".github/scripts/orvix_icon_256.b64").read_text(encoding="ascii").strip()
Path("assets/branding/orvix_icon.png").write_bytes(base64.b64decode(icon_b64))

for helper_path in [
    Path(".github/scripts/orvix_v052_patch.py"),
    Path(".github/scripts/orvix_icon_256.b64"),
    Path(".github/workflows/orvix-v052-once.yml"),
]:
    if helper_path.exists():
        helper_path.unlink()
