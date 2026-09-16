from pathlib import Path

# PikPak stream selection: match Debrify's established ordering.
p = Path('lib/services/pikpak_transfer_service.dart')
text = p.read_text(encoding='utf-8')
start_marker = '  /// Pick a streaming-optimized PikPak media rendition.'
end_marker = '  String? _mediaUrl(Map<String, dynamic> media) {'
start = text.index(start_marker)
end = text.index(end_marker, start)
replacement = '''  /// Follow PikPak/Debrify streaming semantics: prefer the media entry that
  /// PikPak itself marks as default, then the origin rendition, then the first
  /// usable media entry. Do not invent a quality ranking here: PikPak's
  /// `is_default` choice is the provider-selected playback path.
  String? _selectMediaUrl(Map<String, dynamic> decoded) {
    final medias = decoded['medias'];
    if (medias is! List || medias.isEmpty) return null;

    final entries = medias
        .whereType<Map<String, dynamic>>()
        .where((media) => _mediaUrl(media) != null)
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

'''
text = text[:start] + replacement + text[end:]
p.write_text(text, encoding='utf-8')

# Player: Debrify's Standard VOD path leaves mpv network/cache properties alone.
p = Path('lib/services/playback_service.dart')
p.write_text("""import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
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

# Detect the exact 0:00/0:00 failure mode instead of spinning forever.
p = Path('lib/screens/player_screen.dart')
text = p.read_text(encoding='utf-8')
old = "  Timer? _nextTimer;\n  StreamSubscription<bool>? _completedSubscription;"
new = "  Timer? _nextTimer;\n  Timer? _startupTimer;\n  StreamSubscription<bool>? _completedSubscription;"
if old not in text:
    raise SystemExit('player field marker not found')
text = text.replace(old, new, 1)

old = "      await widget.playback.open(widget.url, title: widget.title);\n      final currentVolume = widget.playback.player.state.volume;"
new = """      await widget.playback.open(widget.url, title: widget.title);
      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted) return;
        final state = widget.playback.player.state;
        if (state.duration <= Duration.zero &&
            state.position <= Duration.zero) {
          setState(() {
            _error = 'PikPak stream did not initialize (still 0:00/0:00 after 12 seconds). '
                'This is a stream-start failure, not normal buffering.';
          });
        }
      });
      final currentVolume = widget.playback.player.state.volume;"""
if old not in text:
    raise SystemExit('player open marker not found')
text = text.replace(old, new, 1)

old = "    _nextTimer?.cancel();\n    _completedSubscription?.cancel();"
new = "    _nextTimer?.cancel();\n    _startupTimer?.cancel();\n    _completedSubscription?.cancel();"
if old not in text:
    raise SystemExit('player dispose marker not found')
text = text.replace(old, new, 1)
p.write_text(text, encoding='utf-8')

# Version/changelog.
p = Path('pubspec.yaml')
text = p.read_text(encoding='utf-8')
if 'version: 0.3.3+7' not in text:
    raise SystemExit('unexpected pubspec version')
p.write_text(text.replace('version: 0.3.3+7', 'version: 0.3.4+8', 1), encoding='utf-8')

p = Path('CHANGELOG.md')
text = p.read_text(encoding='utf-8')
marker = 'This file tracks user-visible changes to Pikora. GitHub Releases are published automatically for new packaged versions starting with v0.3.2.\n'
section = """

## v0.3.4 — Debrify-aligned PikPak playback

- Reworked PikPak rendition selection to follow Debrify/PikPak semantics: `is_default` first, then `is_origin`, then the first usable media link, with `web_content_link` only as fallback.
- Removed Pikora's custom "highest transcode up to 1080p" selection that could choose a non-default/broken PikPak rendition.
- Removed always-on mpv cache/reconnect overrides. The default playback path now uses stock media_kit/libmpv behavior, matching Debrify's `Standard` network preset.
- Removed the custom forced `hwdec` VideoController configuration from the default path and returned to the stock controller setup used by Debrify on desktop.
- Added a 12-second startup watchdog: a VOD stream that remains at `0:00 / 0:00` is reported as a stream-start failure instead of showing an endless buffering spinner.
- Kept v0.3.3's exact `fileIdx`/torrent-child routing, so this playback alignment does not reintroduce cross-source or wrong-episode matching.
"""
if '## v0.3.4 ' not in text:
    if marker not in text:
        raise SystemExit('changelog marker not found')
    text = text.replace(marker, marker + section, 1)
p.write_text(text, encoding='utf-8')
