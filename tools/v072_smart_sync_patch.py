from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "lib/screens/details_screen.dart",
    """          item: item,
          episode: episode,
          onStatus: (message) {""",
    """          item: item,
          episode: episode,
          videoUrl: url,
          onStatus: (message) {""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """import '../services/ai_sinhala_subtitle_service.dart';
import '../services/media_state_service.dart';""",
    """import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/media_state_service.dart';""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
  String _aiDisplaySubtitle = '';""",
    """  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
  bool _timingTrackSelected = false;
  String _aiDisplaySubtitle = '';
  int _autoSyncOffsetMs = 0;
  int _manualSyncOffsetMs = 0;
  final List<int> _autoSyncSamples = <int>[];""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """    if (_aiSinhalaEnabled) {
      _positionSubscription = widget.playback.player.stream.position.listen(_onPosition);
    }
    _open();""",
    """    if (_aiSinhalaEnabled) {
      _positionSubscription = widget.playback.player.stream.position.listen(_onPosition);
      _subtitleTimingSubscription =
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
      unawaited(_loadManualSync());
    }
    _open();""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """      await widget.playback.open(widget.url, title: widget.title);
      _startupTimer?.cancel();""",
    """      await widget.playback.open(widget.url, title: widget.title);
      if (_aiSinhalaEnabled) {
        unawaited(_ensureEnglishTimingTrack());
      }
      _startupTimer?.cancel();""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """  void _onPosition(Duration position) {
    final prepared = widget.aiSubtitle;
    if (!_aiSinhalaEnabled || prepared == null || !mounted) return;
    final next = prepared.subtitleAt(position);
    if (next == _aiDisplaySubtitle) return;
    setState(() => _aiDisplaySubtitle = next);
  }
""",
    """  int get _effectiveSyncOffsetMs =>
      (_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-15000, 15000);

  Future<void> _loadManualSync() async {
    final prepared = widget.aiSubtitle;
    if (prepared == null) return;
    final value = await AiSinhalaPreferencesService.syncOffsetMs(prepared.key);
    if (!mounted) return;
    setState(() => _manualSyncOffsetMs = value);
    _refreshAiSubtitle();
  }

  Future<void> _adjustManualSync(int deltaMs) async {
    final prepared = widget.aiSubtitle;
    if (prepared == null) return;
    final next = (_manualSyncOffsetMs + deltaMs).clamp(-15000, 15000);
    if (mounted) setState(() => _manualSyncOffsetMs = next);
    await AiSinhalaPreferencesService.setSyncOffsetMs(prepared.key, next);
    _refreshAiSubtitle();
  }

  Future<void> _resetManualSync() async {
    final prepared = widget.aiSubtitle;
    if (prepared == null) return;
    if (mounted) setState(() => _manualSyncOffsetMs = 0);
    await AiSinhalaPreferencesService.setSyncOffsetMs(prepared.key, 0);
    _refreshAiSubtitle();
  }

  String _formatSyncOffset(int milliseconds) {
    final sign = milliseconds > 0 ? '+' : '';
    return '$sign${(milliseconds / 1000).toStringAsFixed(2)}s';
  }

  void _refreshAiSubtitle() {
    _onPosition(widget.playback.player.state.position);
  }

  void _onPosition(Duration position) {
    final prepared = widget.aiSubtitle;
    if (!_aiSinhalaEnabled || prepared == null || !mounted) return;
    var adjustedMs = position.inMilliseconds - _effectiveSyncOffsetMs;
    if (adjustedMs < 0) adjustedMs = 0;
    final next = prepared.subtitleAt(Duration(milliseconds: adjustedMs));
    if (next == _aiDisplaySubtitle) return;
    setState(() => _aiDisplaySubtitle = next);
  }

  Future<void> _ensureEnglishTimingTrack() async {
    if (!_aiSinhalaEnabled) return;
    final player = widget.playback.player;
    for (var attempt = 0; attempt < 8 && mounted; attempt++) {
      final current = player.state.track.subtitle;
      if (current.id.toLowerCase() != 'no' && _isEnglishTextTrack(current)) {
        _timingTrackSelected = true;
        return;
      }
      final tracks = player.state.tracks.subtitle
          .where((track) => track.id.toLowerCase() != 'no')
          .where(_isEnglishTextTrack)
          .toList(growable: false);
      if (tracks.isNotEmpty) {
        await player.setSubtitleTrack(tracks.first);
        _timingTrackSelected = true;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  bool _isEnglishTextTrack(dynamic track) {
    final language = (track.language ?? '').toString().trim().toLowerCase();
    final title = (track.title ?? '').toString().trim().toLowerCase();
    final codec = (track.codec ?? '').toString().trim().toLowerCase();
    final english = language == 'en' ||
        language == 'eng' ||
        language.startsWith('en-') ||
        title.contains('english') ||
        title == 'eng';
    if (!english) return false;
    return !codec.contains('pgs') &&
        !codec.contains('dvd') &&
        !codec.contains('dvb') &&
        !codec.contains('vob');
  }

  void _onEmbeddedSubtitleCue(List<String> lines) {
    if (!_aiSinhalaEnabled || !_timingTrackSelected || !mounted) return;
    final prepared = widget.aiSubtitle;
    if (prepared == null) return;
    final source = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\\n')
        .trim();
    if (source.isEmpty) return;
    final matched = prepared.matchSourceCue(source);
    if (matched == null) return;
    final sample = widget.playback.player.state.position.inMilliseconds -
        matched.start.inMilliseconds;
    if (sample.abs() > 10000) return;
    _autoSyncSamples.add(sample);
    if (_autoSyncSamples.length > 5) _autoSyncSamples.removeAt(0);
    final ordered = [..._autoSyncSamples]..sort();
    final median = ordered[ordered.length ~/ 2];
    if ((median - _autoSyncOffsetMs).abs() < 40) return;
    setState(() => _autoSyncOffsetMs = median);
    _refreshAiSubtitle();
  }
""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """                const SizedBox(height: 8),
                const SizedBox(height: 8),
                _TrackTile(
                  title: 'Off',""",
    """                const SizedBox(height: 8),
                if (_aiSinhalaEnabled && widget.aiSubtitle != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111A13),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF263827)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'AI Sinhala sync',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            Text(_formatSyncOffset(_effectiveSyncOffsetMs)),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _autoSyncSamples.isNotEmpty
                              ? 'Auto-synced from this video’s embedded English timing. Adjust only if it still looks off.'
                              : 'Orvix is using release-matched timing. Adjust only if this source is still out of sync.',
                          style: TextStyle(
                            color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () async {
                                await _adjustManualSync(-500);
                                if (sheetContext.mounted) Navigator.pop(sheetContext);
                              },
                              child: const Text('Earlier -0.5s'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await _resetManualSync();
                                if (sheetContext.mounted) Navigator.pop(sheetContext);
                              },
                              child: const Text('Reset manual'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await _adjustManualSync(500);
                                if (sheetContext.mounted) Navigator.pop(sheetContext);
                              },
                              child: const Text('Later +0.5s'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _TrackTile(
                  title: 'Off',""",
)

replace_once(
    "lib/screens/player_screen.dart",
    """    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _persistProgress();""",
    """    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _subtitleTimingSubscription?.cancel();
    _persistProgress();""",
)

service = Path("lib/services/ai_sinhala_subtitle_service.dart")
text = service.read_text(encoding="utf-8")
bad = "RegExp(r'[^a-z0-9\\s\\'’-]')"
good = 'RegExp(r"[^a-z0-9\\s\'’-]")'
if bad not in text:
    raise SystemExit("AI subtitle normalization regex marker was not found")
service.write_text(text.replace(bad, good, 1), encoding="utf-8")

pubspec = Path("pubspec.yaml")
text = pubspec.read_text(encoding="utf-8")
if "version: 0.7.1+34" not in text:
    raise SystemExit("pubspec version was not the expected v0.7.1+34")
pubspec.write_text(text.replace("version: 0.7.1+34", "version: 0.7.2+35", 1), encoding="utf-8")
