from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, found {count}')
    return text.replace(old, new, 1)

# app.dart: add Settings destination/screen.
path = Path('lib/app.dart')
text = path.read_text(encoding='utf-8')
text = replace_once(
    text,
    "import 'screens/search_screen.dart';\nimport 'screens/sources_screen.dart';",
    "import 'screens/search_screen.dart';\nimport 'screens/settings_screen.dart';\nimport 'screens/sources_screen.dart';",
    'settings import',
)
text = replace_once(
    text,
    "      SourcesScreen(sources: widget.sources),\n      AccountScreen(",
    "      SourcesScreen(sources: widget.sources),\n      const SettingsScreen(),\n      AccountScreen(",
    'settings screen',
)
text = replace_once(
    text,
    "                NavigationRailDestination(\n                  icon: Icon(Icons.person_outline_rounded),",
    "                NavigationRailDestination(\n                  icon: Icon(Icons.settings_outlined),\n                  selectedIcon: Icon(Icons.settings_rounded),\n                  label: Text('Settings'),\n                ),\n                NavigationRailDestination(\n                  icon: Icon(Icons.person_outline_rounded),",
    'settings destination',
)
text = text.replace("'Orvix v0.6'", "'Orvix v0.7'", 1)
path.write_text(text, encoding='utf-8')

# details_screen.dart: pre-buffer AI subtitles before entering player.
path = Path('lib/screens/details_screen.dart')
text = path.read_text(encoding='utf-8')
text = replace_once(
    text,
    "import '../services/catalog_service.dart';\nimport '../services/cloud_preferences_service.dart';",
    "import '../services/ai_sinhala_preferences_service.dart';\nimport '../services/ai_sinhala_subtitle_service.dart';\nimport '../services/catalog_service.dart';\nimport '../services/cloud_preferences_service.dart';",
    'details AI imports',
)
old_start = """  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });

    final title = episode == null
"""
new_start = """  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    if (!mounted) return;

    AiPreparedSubtitle? preparedAiSubtitle;
    final aiEnabled = await AiSinhalaPreferencesService.isEnabled();
    if (aiEnabled && AiSinhalaSubtitleService.canTranslate) {
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Preparing Sinhala subtitles…';
      });
      try {
        preparedAiSubtitle = await AiSinhalaSubtitleService.prepareBuffered(
          item: item,
          episode: episode,
          onStatus: (message) {
            if (!mounted) return;
            setState(() => _status = message);
          },
        );
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'AI Sinhala could not be prepared for this title. Playing with normal subtitle options.',
              ),
            ),
          );
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });

    final title = episode == null
"""
text = replace_once(text, old_start, new_start, 'details prepare block')
text = replace_once(
    text,
    "          item: item,\n          episode: episode,\n          nextEpisodeLabel:",
    "          item: item,\n          episode: episode,\n          aiSubtitle: preparedAiSubtitle,\n          nextEpisodeLabel:",
    'details player argument',
)
path.write_text(text, encoding='utf-8')

# player_screen.dart: remove live per-cue network translation and consume pre-buffered cues.
path = Path('lib/screens/player_screen.dart')
text = path.read_text(encoding='utf-8')
text = replace_once(
    text,
    "    this.episode,\n    this.nextEpisodeLabel,",
    "    this.episode,\n    this.aiSubtitle,\n    this.nextEpisodeLabel,",
    'player constructor arg',
)
text = replace_once(
    text,
    "  final EpisodeItem? episode;\n  final String? nextEpisodeLabel;",
    "  final EpisodeItem? episode;\n  final AiPreparedSubtitle? aiSubtitle;\n  final String? nextEpisodeLabel;",
    'player field',
)
old_fields = """  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<List<String>>? _subtitleSubscription;
  final FocusNode _focusNode = FocusNode();
  final List<String> _subtitleContext = <String>[];
  bool _aiSinhalaEnabled = false;
  bool _aiSubtitleBusy = false;
  String _sourceSubtitle = '';
  String _aiDisplaySubtitle = '';
  String? _aiSubtitleError;
  int _subtitleRequestSerial = 0;
"""
new_fields = """  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
  String _aiDisplaySubtitle = '';
"""
text = replace_once(text, old_fields, new_fields, 'player AI fields')
text = replace_once(
    text,
    "    _subtitleSubscription = widget.playback.player.stream.subtitle.listen(_onSubtitleCue);\n    _open();",
    "    _aiSinhalaEnabled = widget.aiSubtitle != null;\n    if (_aiSinhalaEnabled) {\n      _positionSubscription = widget.playback.player.stream.position.listen(_onPosition);\n    }\n    _open();",
    'player init listener',
)

start_marker = '  void _onSubtitleCue(List<String> lines) {'
end_marker = '  Future<void> _pickExternalSubtitle() async {'
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('player live AI method block not found')
new_methods = """  void _onPosition(Duration position) {
    final prepared = widget.aiSubtitle;
    if (!_aiSinhalaEnabled || prepared == null || !mounted) return;
    final next = prepared.subtitleAt(position);
    if (next == _aiDisplaySubtitle) return;
    setState(() => _aiDisplaySubtitle = next);
  }

  Widget _aiSubtitleOverlay() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      left: 40,
      right: 40,
      bottom: _controlsVisible ? 122 : 30,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xD9000000),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 18,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Text(
                  _aiDisplaySubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 27,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

"""
text = text[:start] + new_methods + text[end:]

# Remove player-level AI toggle: global Settings owns this now.
toggle_start = text.find("                Container(\n                  decoration: BoxDecoration(\n                    color: const Color(0x331F7A4D),")
if toggle_start >= 0:
    toggle_end_marker = "                const SizedBox(height: 8),\n                _TrackTile(\n                  title: 'Off',"
    toggle_end = text.find(toggle_end_marker, toggle_start)
    if toggle_end < 0:
        raise SystemExit('player AI toggle end not found')
    text = text[:toggle_start] + toggle_end_marker + text[toggle_end + len(toggle_end_marker):]
else:
    raise SystemExit('player AI toggle start not found')

text = text.replace("                    if (_aiSinhalaEnabled) await _setAiSinhala(false);\n", '', 1)
text = replace_once(
    text,
    "    _completedSubscription?.cancel();\n    _subtitleSubscription?.cancel();\n    ++_subtitleRequestSerial;",
    "    _completedSubscription?.cancel();\n    _positionSubscription?.cancel();",
    'player dispose listener',
)
path.write_text(text, encoding='utf-8')

# Bump candidate version.
path = Path('pubspec.yaml')
text = path.read_text(encoding='utf-8')
text = replace_once(text, 'version: 0.7.0+33', 'version: 0.7.1+34', 'pubspec version')
path.write_text(text, encoding='utf-8')
