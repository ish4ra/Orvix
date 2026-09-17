from pathlib import Path

def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f'patch target not found: {label}')
    return text.replace(old, new, 1)

details_path = Path('lib/screens/details_screen.dart')
details = details_path.read_text(encoding='utf-8')

details = replace_once(
    details,
    "import '../services/cloud_preferences_service.dart';\n",
    "import '../services/cloud_preferences_service.dart';\nimport '../services/local_torrent_service.dart';\n",
    'details import',
)

details = replace_once(
    details,
    "      final hasCloudConnection = pikpakConnected || torboxConnected;\n      final directResults =\n          results.where((result) => !result.isMagnet).toList(growable: false);\n",
    "      final hasCloudConnection = pikpakConnected || torboxConnected;\n",
    'remove direct-only subset',
)

old = '''      // A user without a cloud/debrid account should still get a one-click
      // path when an addon returned a direct/free stream. Normal Play prefers
      // the best direct result in that case; Find Sources still lets the user
      // choose manually.
      if (autoUsePinned &&
          !hasCloudConnection &&
          (chosen == null || chosen.isMagnet) &&
          directResults.isNotEmpty) {
        chosen = directResults.first;
      }
'''
new = '''      // With no debrid/cloud connection, Normal Play behaves like a
      // Stremio-style free path: rank direct and torrent/P2P results together
      // and pick the healthiest source automatically. Find Sources remains
      // fully manual.
      if (autoUsePinned && !hasCloudConnection && chosen == null) {
        final freeResults = widget.sources.sortForFreeStreaming(results);
        if (freeResults.isNotEmpty) chosen = freeResults.first;
      }
'''
details = replace_once(details, old, new, 'free P2P auto-pick')

old = '''      if (!chosen.isMagnet) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status = 'Opening direct stream…';
        });
        await _openPlayerUrl(chosen.resource, item, episode);
        return;
      }

      final cloud = await _chooseCloudProvider();
'''
new = '''      if (!chosen.isMagnet) {
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
'''
details = replace_once(details, old, new, 'local torrent playback branch')

details = replace_once(
    details,
    "? 'Configure a Stremio-compatible source provider. Direct / Free HTTP streams can play immediately without a cloud account; torrent or magnet sources still require PikPak or TorBox.'",
    "? 'Configure a Stremio-compatible source provider. Direct HTTP streams play immediately, and torrent/magnet sources can use Orvix built-in local P2P engine on Windows. PikPak/TorBox are optional cloud paths.'",
    'no sources message',
)

details = details.replace(
    "result.isMagnet ? ' • cloud source' : ' • direct URL'",
    "result.isMagnet ? ' • torrent / P2P' : ' • direct URL'",
)

details_path.write_text(details, encoding='utf-8')

app_path = Path('lib/app.dart')
app = app_path.read_text(encoding='utf-8')
app = replace_once(
    app,
    "import 'services/cloud_preferences_service.dart';\n",
    "import 'services/cloud_preferences_service.dart';\nimport 'services/local_torrent_service.dart';\n",
    'app import',
)
app = replace_once(
    app,
    "    _torbox.dispose();\n    _playback.dispose();\n",
    "    _torbox.dispose();\n    LocalTorrentService.instance.dispose();\n    _playback.dispose();\n",
    'dispose torrent engine',
)
app = app.replace("Orvix v0.7.3-alpha.1", "Orvix v0.7.3-alpha.2")
app = replace_once(
    app,
    "              const _FeatureLine(Icons.hub_outlined,\n                  'User-configured Stremio-compatible source providers'),\n",
    "              const _FeatureLine(Icons.hub_outlined,\n                  'User-configured Stremio-compatible source providers'),\n              const _FeatureLine(Icons.hub_rounded,\n                  'Built-in local BitTorrent/P2P streaming on Windows when no debrid account is connected'),\n",
    'about P2P feature',
)
app_path.write_text(app, encoding='utf-8')