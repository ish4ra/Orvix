from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"Expected block not found in {path}: {old[:100]!r}")
    text = text.replace(old, new, 1)
    p.write_text(text, encoding="utf-8")


# Make the Orvix brand mark clearly visible in the sidebar instead of relying
# on the wordmark alone. Keep the existing bundled icon asset so branding is
# consistent with the installer/window icon.
replace_once(
    "lib/app.dart",
    """                    ClipRRect(\n                      borderRadius: BorderRadius.circular(12),\n                      child: Image.asset(\n                        'assets/branding/orvix_icon.png',\n                        width: 40,\n                        height: 40,\n                        fit: BoxFit.cover,\n                      ),\n                    ),""",
    """                    Container(\n                      width: 52,\n                      height: 52,\n                      padding: const EdgeInsets.all(3),\n                      decoration: BoxDecoration(\n                        color: const Color(0xFF081008),\n                        borderRadius: BorderRadius.circular(16),\n                        border: Border.all(\n                          color: const Color(0xFF8FD43D),\n                          width: .8,\n                        ),\n                        boxShadow: const [\n                          BoxShadow(\n                            color: Color(0x443CFF00),\n                            blurRadius: 16,\n                            spreadRadius: 1,\n                          ),\n                        ],\n                      ),\n                      child: ClipRRect(\n                        borderRadius: BorderRadius.circular(13),\n                        child: Image.asset(\n                          'assets/branding/orvix_icon.png',\n                          fit: BoxFit.cover,\n                        ),\n                      ),\n                    ),""",
)

replace_once(
    "lib/app.dart",
    """                      const Text(\n                        'ORVIX',\n                        style: TextStyle(\n                          fontWeight: FontWeight.w900,\n                          letterSpacing: 1.6,\n                          fontSize: 18,\n                        ),\n                      ),""",
    """                      const Text(\n                        'ORVIX',\n                        style: TextStyle(\n                          fontWeight: FontWeight.w900,\n                          letterSpacing: 2.1,\n                          fontSize: 20,\n                        ),\n                      ),""",
)

replace_once(
    "lib/app.dart",
    "'Orvix v0.7'",
    "'Orvix v0.7.3-alpha.1'",
)

# Playback should not require PikPak/TorBox when a source provider already
# returned a direct HTTP stream. Debrid/cloud remains necessary for magnets.
replace_once(
    "lib/screens/details_screen.dart",
    "_status = 'Checking your PikPak library for an exact match…';",
    "_status = 'Checking connected libraries and playable sources…';",
)

replace_once(
    "lib/screens/details_screen.dart",
    """      SourceResult? chosen;\n      if (autoUsePinned) {""",
    """      final pikpakConnected = await widget.pikpak.isSignedIn;\n      final torboxConnected = await widget.torbox.isConnected;\n      final hasCloudConnection = pikpakConnected || torboxConnected;\n      final directResults = results\n          .where((result) => !result.isMagnet)\n          .toList(growable: false);\n\n      SourceResult? chosen;\n      if (autoUsePinned) {""",
)

replace_once(
    "lib/screens/details_screen.dart",
    """      chosen ??= await _chooseSource(results, item, episode);\n      if (chosen == null || !mounted) return;\n      final cloud = await _chooseCloudProvider();""",
    """      // A user without a cloud/debrid account should still get a one-click\n      // path when an addon returned a direct/free stream. Normal Play prefers\n      // the best direct result in that case; Find Sources still lets the user\n      // choose manually.\n      if (autoUsePinned &&\n          !hasCloudConnection &&\n          (chosen == null || chosen.isMagnet) &&\n          directResults.isNotEmpty) {\n        chosen = directResults.first;\n      }\n\n      chosen ??= await _chooseSource(results, item, episode);\n      if (chosen == null || !mounted) return;\n\n      if (!chosen.isMagnet) {\n        setState(() {\n          _resolving = true;\n          _resolveProgress = null;\n          _status = 'Opening direct stream…';\n        });\n        await _openPlayerUrl(chosen.resource, item, episode);\n        return;\n      }\n\n      final cloud = await _chooseCloudProvider();""",
)

replace_once(
    "lib/screens/details_screen.dart",
    """            content: Text('Connect PikPak or TorBox from Clouds first.'),""",
    """            content: Text(\n              'This torrent source needs PikPak or TorBox. Direct / Free sources play without a debrid account.',\n            ),""",
)

replace_once(
    "lib/screens/details_screen.dart",
    """              ? 'This title is not in your PikPak library. Configure a Stremio-compatible source provider, then Orvix can send a returned source to your selected cloud service and play it when ready.'""",
    """              ? 'Configure a Stremio-compatible source provider. Direct / Free HTTP streams can play immediately without a cloud account; torrent or magnet sources still require PikPak or TorBox.'""",
)

print("Applied Orvix logo + direct/free playback patch.")
