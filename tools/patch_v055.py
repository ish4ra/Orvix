from pathlib import Path

# Smart read-ahead buffering + reconnect for Windows/libmpv.
p = Path('lib/services/playback_service.dart')
s = p.read_text(encoding='utf-8')
s = s.replace("import 'package:media_kit/media_kit.dart';", "import 'dart:io';\n\nimport 'package:media_kit/media_kit.dart';")
s = s.replace(
"class PlaybackService {\n  PlaybackService() : player = Player() {\n    // Preserve the patched media_kit platform defaults. In particular, do not\n    // force a global cache/reconnect profile: PikPak's signed media URLs are\n    // already VOD-optimized and mpv's defaults are more reliable across\n    // original files and cloud renditions.\n    controller = VideoController(player);\n  }",
"class PlaybackService {\n  PlaybackService()\n      : player = Player(\n          configuration: const PlayerConfiguration(\n            bufferSize: 512 * 1024 * 1024,\n          ),\n        ) {\n    controller = VideoController(player);\n  }"
)
s = s.replace(
"  Future<void> open(\n    String url, {\n    String? title,\n    Map<String, String>? httpHeaders,\n  }) async {\n    await player.open(",
"  Future<void> open(\n    String url, {\n    String? title,\n    Map<String, String>? httpHeaders,\n  }) async {\n    await _applySmartBuffer();\n    await player.open("
)
marker = "  Future<void> stop() => player.stop();"
insert = """  Future<void> _applySmartBuffer() async {
    if (!Platform.isWindows) return;
    try {
      await player.handle;
      final dynamic platform = player.platform;
      if (platform == null) return;
      await platform.setProperty('demuxer-max-bytes', '${512 * 1024 * 1024}', waitForInitialization: false);
      await platform.setProperty('demuxer-max-back-bytes', '${128 * 1024 * 1024}', waitForInitialization: false);
      await platform.setProperty('demuxer-readahead-secs', '180', waitForInitialization: false);
      await platform.setProperty('cache-secs', '180', waitForInitialization: false);
      await platform.setProperty('network-timeout', '90', waitForInitialization: false);
      await platform.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',
        waitForInitialization: false,
      );
    } catch (_) {
      // Keep playback functional if a backend ignores one of the tuning knobs.
    }
  }

"""
if insert not in s:
    s = s.replace(marker, insert + marker)
p.write_text(s, encoding='utf-8')

# Compatibility score. Large HEVC/x265/REMUX files remain compatible.
p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')
marker = "  /// Auto-pick follows the same default priority shown in Source Engine:"
insert = r"""  int get compatibilityScore {
    final name = title.toLowerCase();
    var score = 100;
    if (RegExp(r'\b(?:4320p|8k)\b').hasMatch(name)) score -= 45;
    if (RegExp(r'\b(?:vvc|h[ ._-]?266)\b').hasMatch(name)) score -= 55;
    if (RegExp(r'\bav1\b').hasMatch(name)) score -= 30;
    if (RegExp(r'\bvp9\b').hasMatch(name)) score -= 20;
    if (RegExp(r'\bhi10p\b').hasMatch(name)) score -= 15;
    if (RegExp(r'\b(?:dolby[ ._-]?vision|dovi)\b').hasMatch(name) &&
        !RegExp(r'\b(?:hdr10|hdr)\b').hasMatch(name)) {
      score -= 20;
    }
    return score.clamp(0, 100).toInt();
  }

  bool get compatibilityFriendly => compatibilityScore >= 70;

"""
if insert not in s:
    s = s.replace(marker, insert + marker)
p.write_text(s, encoding='utf-8')

# Compatibility filter toggle in source picker.
p = Path('lib/screens/details_screen.dart')
s = p.read_text(encoding='utf-8')
s = s.replace(
    "    var priority = await widget.sources.getPriorityOrder();\n    if (!mounted) return null;",
    "    var priority = await widget.sources.getPriorityOrder();\n    var compatibilityOnly = false;\n    if (!mounted) return null;"
)
s = s.replace(
    "          final sorted = widget.sources.sortResults(results, priority);\n          final best = sorted.isEmpty ? null : sorted.first;",
    "          final filtered = compatibilityOnly\n              ? results.where((result) => result.compatibilityFriendly).toList(growable: false)\n              : results;\n          final sorted = widget.sources.sortResults(filtered, priority);\n          final best = sorted.isEmpty ? null : sorted.first;"
)
s = s.replace(
    "                                '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',",
    "                                compatibilityOnly\n                                    ? '${sorted.length} compatible of ${results.length} results'\n                                    : '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',"
)
old = """                        OutlinedButton.icon(
                          onPressed: () => customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),"""
new = """                        FilterChip(
                          selected: compatibilityOnly,
                          onSelected: (value) => setSheetState(() => compatibilityOnly = value),
                          avatar: Icon(
                            compatibilityOnly ? Icons.verified_rounded : Icons.shield_outlined,
                            size: 18,
                          ),
                          label: const Text('Compatibility'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () => customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),"""
if old not in s:
    raise SystemExit('source-picker button patch target not found')
s = s.replace(old, new)
s = s.replace(
    "                            trailing: index == 0\n                                ? const Chip(label: Text('Best'))\n                                : const Icon(Icons.chevron_right_rounded),",
    "                            trailing: index == 0\n                                ? const Chip(label: Text('Best'))\n                                : result.compatibilityFriendly\n                                    ? const Icon(Icons.verified_outlined, size: 20)\n                                    : const Icon(Icons.warning_amber_rounded, size: 20),"
)
p.write_text(s, encoding='utf-8')

# Actual buffered-ahead progress beneath the seek bar.
p = Path('lib/screens/player_screen.dart')
s = p.read_text(encoding='utf-8')
old = """                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3.5,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: actualMs,
                              max: maxMs,
                              onChangeStart: (_) {
                                _hideTimer?.cancel();
                                setState(() => _seeking = true);
                              },
                              onChanged: (value) => setState(() => _seekPreviewMs = value),
                              onChangeEnd: (value) async {
                                await player.seek(Duration(milliseconds: value.round()));
                                if (!mounted) return;
                                setState(() {
                                  _seeking = false;
                                  _seekPreviewMs = null;
                                });
                                _scheduleHide();
                              },
                            ),
                          ),"""
new = """                          StreamBuilder<Duration>(
                            stream: player.stream.buffer,
                            initialData: player.state.buffer,
                            builder: (context, bufferSnapshot) {
                              final buffered = bufferSnapshot.data ?? Duration.zero;
                              final bufferedMs = buffered.inMilliseconds
                                  .clamp(0, maxMs.round())
                                  .toDouble();
                              return Stack(
                                alignment: Alignment.center,
                                children: [
                                  Positioned.fill(
                                    left: 10,
                                    right: 10,
                                    child: Center(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(99),
                                        child: LinearProgressIndicator(
                                          minHeight: 3.5,
                                          value: maxMs <= 1 ? 0 : bufferedMs / maxMs,
                                          backgroundColor: Colors.white24,
                                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white38),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3.5,
                                      inactiveTrackColor: Colors.transparent,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                    ),
                                    child: Slider(
                                      value: actualMs,
                                      max: maxMs,
                                      onChangeStart: (_) {
                                        _hideTimer?.cancel();
                                        setState(() => _seeking = true);
                                      },
                                      onChanged: (value) => setState(() => _seekPreviewMs = value),
                                      onChangeEnd: (value) async {
                                        await player.seek(Duration(milliseconds: value.round()));
                                        if (!mounted) return;
                                        setState(() {
                                          _seeking = false;
                                          _seekPreviewMs = null;
                                        });
                                        _scheduleHide();
                                      },
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),"""
if old not in s:
    raise SystemExit('player seek-bar patch target not found')
s = s.replace(old, new)
p.write_text(s, encoding='utf-8')

p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8').replace('version: 0.5.4+24', 'version: 0.5.5+25')
p.write_text(s, encoding='utf-8')
