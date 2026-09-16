from pathlib import Path
import re


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f'missing replacement target: {label}')
    return text.replace(old, new, 1)

# Version
p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8')
s = replace_once(s, 'version: 0.4.1+17', 'version: 0.4.2+18', 'pubspec version')
p.write_text(s, encoding='utf-8')

# Playback: restore native/standard mpv network behavior. The forced v0.4.1
# network profile regressed files that PikPak itself already streams smoothly.
Path('lib/services/playback_service.dart').write_text("""import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    // Preserve the patched media_kit platform defaults. In particular, do not
    // force a global cache/reconnect profile: PikPak's signed media URLs are
    // already VOD-optimized and mpv's defaults are more reliable across
    // original files and cloud renditions.
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
    await player.open(
      Media(
        url,
        httpHeaders: httpHeaders,
        extras: {
          if (title != null) 'title': title,
        },
      ),
      play: true,
    );
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
""", encoding='utf-8')

# PikPak media selection: undo v0.4.1's size-based forced transcode. Match the
# proven Debrify/PikPak behavior: is_default first, then origin, then first URL.
p = Path('lib/services/pikpak_transfer_service.dart')
s = p.read_text(encoding='utf-8')
s = re.sub(r"\n  static const _hugeFileThreshold = .*?\n  static const _ultraHugeThreshold = .*?;\n", "\n", s, count=1, flags=re.S)
pattern = re.compile(r"  /// Auto playback follows PikPak's own media renditions, but avoids pushing a\n.*?\n  int _mediaHeight\(", re.S)
replacement = """  /// Follow PikPak's own rendition choice. The provider's `is_default` media
  /// is the closest match to playback in the official client; forcing a lower
  /// transcode based on file size caused buffering regressions on large remuxes.
  String? _selectMediaUrl(Map<String, dynamic> decoded) {
    final medias = decoded['medias'];
    if (medias is! List || medias.isEmpty) return null;

    final entries = medias
        .whereType<Map<String, dynamic>>()
        .where((media) => _mediaUrl(media) != null)
        .where((media) => media['need_more_quota'] != true)
        .where((media) =>
            !media.containsKey('is_visible') || media['is_visible'] != false)
        .toList(growable: false);
    if (entries.isEmpty) return null;

    for (final media in entries) {
      if (media['is_default'] == true) return _mediaUrl(media);
    }
    for (final media in entries) {
      if (media['is_origin'] == true) return _mediaUrl(media);
    }
    return _mediaUrl(entries.first);
  }

  int _mediaHeight("""
s2, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit('missing replacement target: pikpak media selector')
p.write_text(s2, encoding='utf-8')

# Source provider: default-hide stereoscopic encodes and add generic preferred
# release-group highlighting without hard-coding any third-party piracy groups.
p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    "    this.releaseQuality,\n    this.seeders,",
    "    this.releaseQuality,\n    this.preferredGroup = false,\n    this.seeders,",
    'SourceResult constructor',
)
s = replace_once(
    s,
    "  final String? releaseQuality;\n  final int? seeders;",
    "  final String? releaseQuality;\n  final bool preferredGroup;\n  final int? seeders;",
    'SourceResult fields',
)
s = replace_once(
    s,
    "  static const _priorityKey = 'pikora_source_priority_v1';",
    "  static const _priorityKey = 'pikora_source_priority_v1';\n  static const _show3DKey = 'pikora_show_3d_sources_v1';\n  static const _preferredGroupsKey = 'pikora_preferred_release_groups_v1';",
    'source preference keys',
)
marker = "  Future<void> setPriorityOrder(List<SourceSortCriterion> order) async {"
insert = """  Future<bool> getShow3D() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_show3DKey) ?? false;
  }

  Future<void> setShow3D(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_show3DKey, value);
  }

  Future<List<String>> getPreferredGroups() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_preferredGroupsKey) ?? const <String>[])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> setPreferredGroups(List<String> values) async {
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
if marker not in s:
    raise SystemExit('missing replacement target: setPriorityOrder marker')
s = s.replace(marker, insert + marker, 1)

s = replace_once(
    s,
    "    final priority = await getPriorityOrder();\n\n    final type =",
    "    final priority = await getPriorityOrder();\n    final show3D = await getShow3D();\n    final preferredGroups = await getPreferredGroups();\n\n    final type =",
    'resolve preferences',
)
s = replace_once(
    s,
    "      addons.map((addon) => _resolveAddon(addon, type, mediaId, sortMode)),",
    "      addons.map((addon) => _resolveAddon(\n            addon, type, mediaId, sortMode, show3D, preferredGroups)),",
    'resolve addon call',
)
s = replace_once(
    s,
    "    String mediaId,\n    SourceSortMode sortMode,\n  ) async {",
    "    String mediaId,\n    SourceSortMode sortMode,\n    bool show3D,\n    List<String> preferredGroups,\n  ) async {",
    'resolve addon signature',
)
s = replace_once(
    s,
    "        ].where((value) => value.trim().isNotEmpty).join('\\n');\n        final quality = _guessQuality(metadataText);",
    "        ].where((value) => value.trim().isNotEmpty).join('\\n');\n        if (!show3D && _is3DRelease(metadataText)) continue;\n        final preferredGroup = _matchesPreferredGroup(metadataText, preferredGroups);\n        final quality = _guessQuality(metadataText);",
    '3D filter',
)
s = replace_once(
    s,
    "        final statParts = <String>[\n          if (releaseQuality != null) '🎞 $releaseQuality',",
    "        final statParts = <String>[\n          if (preferredGroup) '⭐ Preferred',\n          if (releaseQuality != null) '🎞 $releaseQuality',",
    'preferred stat',
)
s = replace_once(
    s,
    "            releaseQuality: releaseQuality,\n            seeders: seeders,",
    "            releaseQuality: releaseQuality,\n            preferredGroup: preferredGroup,\n            seeders: seeders,",
    'preferred result field',
)

helper_marker = "  String? _guessReleaseQuality(String value) {"
helpers = r"""  bool _is3DRelease(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'(^|[\s._\-\[\(])(3d|sbs|hsbs|h-sbs|half[ ._-]?sbs|full[ ._-]?sbs|tab|top[ ._-]?and[ ._-]?bottom)(?=$|[\s._\-\]\)])')
        .hasMatch(lower)) {
      return true;
    }
    // MVC is predominantly used by frame-packed Blu-ray 3D releases. Require
    // a Blu-ray/3D context so an unrelated token cannot hide a normal file.
    return RegExp(r'\bmvc\b').hasMatch(lower) &&
        (lower.contains('bluray') || lower.contains('blu-ray') || lower.contains('3d'));
  }

  bool _matchesPreferredGroup(String value, List<String> groups) {
    if (groups.isEmpty) return false;
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    for (final group in groups) {
      final token = group
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (token.isNotEmpty && (' $normalized ').contains(' $token ')) return true;
    }
    return false;
  }

"""
if helper_marker not in s:
    raise SystemExit('missing replacement target: helper marker')
s = s.replace(helper_marker, helpers + helper_marker, 1)
p.write_text(s, encoding='utf-8')

# Source settings UI: 3D toggle + preferred release-group list; make it clear
# that all configured providers are queried in parallel.
p = Path('lib/screens/sources_screen.dart')
s = p.read_text(encoding='utf-8')
s = replace_once(
    s,
    "  final _controller = TextEditingController();",
    "  final _controller = TextEditingController();\n  final _preferredGroupsController = TextEditingController();",
    'preferred groups controller',
)
s = replace_once(
    s,
    "  bool _busy = true;\n  String? _message;",
    "  bool _busy = true;\n  bool _show3D = false;\n  String? _message;",
    'show3D state',
)
s = replace_once(
    s,
    "    _controller.dispose();\n    super.dispose();",
    "    _controller.dispose();\n    _preferredGroupsController.dispose();\n    super.dispose();",
    'dispose preferred controller',
)
s = replace_once(
    s,
    "    final torrentio = await widget.sources.getIntegratedTorrentioUrl();\n    if (!mounted) return;",
    "    final torrentio = await widget.sources.getIntegratedTorrentioUrl();\n    final show3D = await widget.sources.getShow3D();\n    final preferredGroups = await widget.sources.getPreferredGroups();\n    if (!mounted) return;",
    'reload extra prefs',
)
s = replace_once(
    s,
    "      _torrentioUrl = torrentio;\n      _busy = false;",
    "      _torrentioUrl = torrentio;\n      _show3D = show3D;\n      _preferredGroupsController.text = preferredGroups.join(', ');\n      _busy = false;",
    'reload state',
)
method_marker = "  Future<void> _add() async {"
methods = """  Future<void> _setShow3D(bool value) async {
    setState(() => _show3D = value);
    await widget.sources.setShow3D(value);
  }

  Future<void> _savePreferredGroups() async {
    final groups = _preferredGroupsController.text
        .split(RegExp(r'[,;\\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    await widget.sources.setPreferredGroups(groups);
    if (!mounted) return;
    setState(() => _message = groups.isEmpty
        ? 'Preferred release groups cleared.'
        : 'Preferred release groups saved. Matching rows will be highlighted.');
  }

"""
if method_marker not in s:
    raise SystemExit('missing replacement target: source settings methods')
s = s.replace(method_marker, methods + method_marker, 1)

s = replace_once(
    s,
    "        _sortCard(context),\n        const SizedBox(height: 26),\n        Text(\n          'Advanced providers',",
    "        _sortCard(context),\n        const SizedBox(height: 18),\n        _resultPreferencesCard(context),\n        const SizedBox(height: 26),\n        Text(\n          'Provider pool',",
    'insert result preferences card',
)
s = replace_once(
    s,
    "          'Optional: add another Stremio-compatible provider you are authorized to use. A saved Torrentio-compatible endpoint is promoted into the integrated slot automatically.',",
    "          'Add multiple Stremio-compatible providers you are authorized to use. Pikora queries the configured provider pool in parallel, merges the returned streams, then de-duplicates exact rows.',",
    'provider pool copy',
)

card_marker = "  Widget _advancedProviderCard(BuildContext context) {"
card = """  Widget _resultPreferencesCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1118),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF242A39)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.filter_alt_outlined),
              SizedBox(width: 10),
              Text(
                'Result preferences',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _show3D,
            onChanged: _busy ? null : _setShow3D,
            title: const Text('Show 3D / SBS releases'),
            subtitle: const Text(
              'Off by default. Hides SBS/HSBS/3D/top-bottom encodes that otherwise appear as a double image on a normal display.',
            ),
          ),
          const Divider(height: 26),
          Text(
            'Preferred release groups',
            style: TextStyle(
              color: color.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Optional. Enter group names separated by commas. Matching source rows get a ⭐ Preferred badge; this does not invent sources that a provider did not return.',
            style: TextStyle(color: color.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _preferredGroupsController,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _savePreferredGroups(),
                  decoration: const InputDecoration(
                    hintText: 'GROUP-A, GROUP-B',
                    prefixIcon: Icon(Icons.star_outline_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _savePreferredGroups,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

"""
if card_marker not in s:
    raise SystemExit('missing replacement target: result preferences card marker')
s = s.replace(card_marker, card + card_marker, 1)
p.write_text(s, encoding='utf-8')

# Changelog
p = Path('CHANGELOG.md')
s = p.read_text(encoding='utf-8')
entry = """## v0.4.2 — PikPak playback rollback, 3D filtering & source preferences

- Reverted the v0.4.1 size-based PikPak transcode override. Playback now follows PikPak's `is_default` media rendition first, then origin, matching the proven official-client/Debrify selection order.
- Removed the global forced mpv cache/reconnect profile; PikPak VOD now uses the patched media_kit/mpv platform defaults.
- 3D/SBS/HSBS/top-bottom releases are hidden by default to prevent accidental side-by-side double-image playback; users can opt in from Source Engine settings.
- Added user-defined Preferred release groups. Matching rows receive a visible ⭐ badge without changing or fabricating provider results.
- Renamed Advanced providers to Provider pool and clarified that every configured Stremio-compatible provider is queried in parallel and merged.
- Kept the strict default ranking: release quality → resolution → seeders → file size.

"""
anchor = '# Pikora Changelog\n\n'
if anchor not in s:
    raise SystemExit('missing changelog anchor')
s = s.replace(anchor, anchor + entry, 1)
p.write_text(s, encoding='utf-8')

print('v0.4.2 patch applied')
