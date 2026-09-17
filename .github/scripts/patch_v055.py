from pathlib import Path

p = Path('lib/services/playback_service.dart')
p.write_text("""import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService()
      : player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 512 * 1024 * 1024,
          ),
        ) {
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> _applySmartStreamingProfile() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    const properties = <String, String>{
      'cache': 'yes',
      'demuxer-readahead-secs': '180',
      'cache-secs': '180',
      'network-timeout': '90',
      'stream-lavf-o':
          'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',
    };
    for (final entry in properties.entries) {
      try {
        await platform.setProperty(
          entry.key,
          entry.value,
          waitForInitialization: false,
        );
      } catch (_) {
        // An unsupported mpv/ffmpeg option must never block playback.
      }
    }
  }

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
    await _applySmartStreamingProfile();
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

p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')
marker = "  String? get sizeLabel {\n"
insert = r'''  int get compatibilityRisk {
    final text = '$title ${fileNameHint ?? ''}'.toLowerCase();
    var risk = 0;

    // File size is intentionally NOT a compatibility signal. Very large
    // remuxes can still be excellent when the stream path is healthy.
    if (RegExp(r'(^|[\s._\-\[(])(8k|4320p)(?=$|[\s._\-\])])')
        .hasMatch(text)) {
      risk += 100;
    }
    if (RegExp(r'(^|[\s._\-\[(])(av1|av01)(?=$|[\s._\-\])])')
        .hasMatch(text)) {
      risk += 45;
    }
    if (RegExp(
      r'(^|[\s._\-\[(])(hi10p|h\.?264[ ._-]?10bit|avc[ ._-]?10bit)(?=$|[\s._\-\])])',
    ).hasMatch(text)) {
      risk += 40;
    }

    final hasDolbyVision = RegExp(
      r'(^|[\s._\-\[(])(dovi|dolby[ ._-]?vision|dv)(?=$|[\s._\-\])])',
    ).hasMatch(text);
    final hasHdrFallback = RegExp(
      r'(^|[\s._\-\[(])(hdr10\+?|hdr)(?=$|[\s._\-\])])',
    ).hasMatch(text);
    if (hasDolbyVision && !hasHdrFallback) risk += 30;

    return risk;
  }

  bool get compatibilityFriendly => compatibilityRisk == 0;

'''
if 'int get compatibilityRisk' not in s:
    if marker not in s:
        raise SystemExit('SourceResult sizeLabel marker not found')
    s = s.replace(marker, insert + marker, 1)
p.write_text(s, encoding='utf-8')

p = Path('lib/screens/details_screen.dart')
s = p.read_text(encoding='utf-8')
replacements = [
("""  Future<SourceResult?> _chooseSource(List<SourceResult> results) async {
    var priority = await widget.sources.getPriorityOrder();
    if (!mounted) return null;
""", """  Future<SourceResult?> _chooseSource(List<SourceResult> results) async {
    var priority = await widget.sources.getPriorityOrder();
    var compatibilityOnly = false;
    if (!mounted) return null;
"""),
("""          final sorted = widget.sources.sortResults(results, priority);
          final best = sorted.isEmpty ? null : sorted.first;
          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
""", """          final ranked = widget.sources.sortResults(results, priority);
          final sorted = compatibilityOnly
              ? ranked.where((result) => result.compatibilityFriendly).toList(growable: false)
              : ranked;
          final hiddenCount = ranked.length - sorted.length;
          final best = sorted.isEmpty ? null : sorted.first;
          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');
"""),
("""                                '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',
""", """                                compatibilityOnly
                                    ? '${sorted.length} compatible result${sorted.length == 1 ? '' : 's'}${hiddenCount > 0 ? ' • $hiddenCount risky hidden' : ''}'
                                    : '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',
"""),
("""                        OutlinedButton.icon(
                          onPressed: () => customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),
""", """                        FilterChip(
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
                          onPressed: () => customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),
"""),
("""                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${result.provider}${result.isMagnet ? ' • cloud source' : ' • direct URL'}',
                              ),
                            ),
""", """                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${result.provider}${result.isMagnet ? ' • cloud source' : ' • direct URL'}${result.compatibilityFriendly ? '' : ' • ⚠ compatibility risk'}',
                              ),
                            ),
"""),
]
for old, new in replacements:
    if old not in s:
        raise SystemExit('details screen patch marker not found')
    s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')

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
                          ),
"""
new = """                          StreamBuilder<Duration>(
                            stream: player.stream.buffer,
                            initialData: player.state.buffer,
                            builder: (context, bufferSnapshot) {
                              final bufferedMs = (bufferSnapshot.data ?? Duration.zero)
                                  .inMilliseconds
                                  .toDouble()
                                  .clamp(actualMs, maxMs)
                                  .toDouble();
                              return SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3.5,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                ),
                                child: Slider(
                                  value: actualMs,
                                  max: maxMs,
                                  secondaryTrackValue: bufferedMs,
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
                              );
                            },
                          ),
"""
if old not in s:
    raise SystemExit('player slider marker not found')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')

p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8')
if 'version: 0.5.4+24' not in s:
    raise SystemExit('unexpected pubspec version')
p.write_text(s.replace('version: 0.5.4+24', 'version: 0.5.5+25', 1), encoding='utf-8')

p = Path('installer/orvix.iss')
s = p.read_text(encoding='utf-8')
p.write_text(s.replace('#define MyAppVersion "0.5.4"', '#define MyAppVersion "0.5.5"', 1), encoding='utf-8')
