import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../models/media_item.dart';
import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/media_state_service.dart';
import '../services/playback_service.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.playback,
    required this.url,
    required this.title,
    this.mediaState,
    this.item,
    this.episode,
    this.aiSubtitle,
    this.nextEpisodeLabel,
    this.onNext,
  });

  final PlaybackService playback;
  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final AiPreparedSubtitle? aiSubtitle;
  final String? nextEpisodeLabel;
  final Future<void> Function()? onNext;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  String? _error;
  bool _controlsVisible = true;
  bool _seeking = false;
  bool _advancing = false;
  double? _seekPreviewMs;
  double _lastVolume = 100;
  int _nextCountdown = 0;
  Timer? _hideTimer;
  Timer? _saveTimer;
  Timer? _nextTimer;
  Timer? _startupTimer;
  Timer? _nativeSubtitleClockTimer;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
  bool _timingTrackSelected = false;
  bool _timingTrackIsText = false;
  String _aiDisplaySubtitle = '';
  int _autoSyncOffsetMs = 0;
  int _manualSyncOffsetMs = 0;
  int? _lastNativeSubtitleStartMs;
  final List<int> _autoSyncSamples = <int>[];
  final Map<int, int> _bitmapOffsetVotes = <int, int>{};

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _aiSinhalaEnabled = widget.aiSubtitle != null;
    if (_aiSinhalaEnabled) {
      _positionSubscription =
          widget.playback.player.stream.position.listen(_onPosition);
      _subtitleTimingSubscription =
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
      unawaited(_loadManualSync());
    }
    _open();
    _scheduleHide();
    _saveTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _persistProgress());
    _completedSubscription =
        widget.playback.player.stream.completed.listen((completed) {
      if (completed) _startNextCountdown();
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  Future<void> _open() async {
    try {
      await widget.playback.open(widget.url, title: widget.title);
      if (_aiSinhalaEnabled) {
        unawaited(_ensureEnglishTimingTrack());
      }
      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted) return;
        final state = widget.playback.player.state;
        if (state.duration <= Duration.zero &&
            state.position <= Duration.zero) {
          setState(() {
            _error =
                'PikPak stream did not initialize (still 0:00/0:00 after 12 seconds). '
                'This is a stream-start failure, not normal buffering.';
          });
        }
      });
      final currentVolume = widget.playback.player.state.volume;
      if (currentVolume > 0) _lastVolume = currentVolume;
      if (widget.item != null && widget.mediaState != null) {
        final resume = await widget.mediaState!.resumePosition(
          widget.item!,
          episode: widget.episode,
        );
        if (resume != null && resume > const Duration(seconds: 10)) {
          await widget.playback.player.seek(resume);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _persistProgress() async {
    if (widget.item == null || widget.mediaState == null) return;
    final state = widget.playback.player.state;
    await widget.mediaState!.saveProgress(
      widget.item!,
      episode: widget.episode,
      position: state.position,
      duration: state.duration,
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_seeking && _nextCountdown == 0) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _seekRelative(Duration offset) async {
    final player = widget.playback.player;
    var target = player.state.position + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (player.state.duration > Duration.zero &&
        target > player.state.duration) {
      target = player.state.duration;
    }
    await player.seek(target);
    _showControls();
  }

  Future<void> _toggleMute() async {
    final player = widget.playback.player;
    if (player.state.volume > 0) {
      _lastVolume = player.state.volume;
      await player.setVolume(0);
    } else {
      await player.setVolume(_lastVolume <= 0 ? 100 : _lastVolume);
    }
    _showControls();
  }

  Future<void> _toggleFullscreen() async {
    if (!_desktop) return;
    await windowManager.setFullScreen(!(await windowManager.isFullScreen()));
    _showControls();
  }

  Future<void> _handleEscape() async {
    if (_desktop && await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      widget.playback.player.playOrPause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _handleEscape();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startNextCountdown() {
    if (widget.onNext == null || _advancing || _nextCountdown > 0) return;
    _hideTimer?.cancel();
    if (mounted) {
      setState(() {
        _controlsVisible = true;
        _nextCountdown = 8;
      });
    }
    _nextTimer?.cancel();
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_nextCountdown <= 1) {
        timer.cancel();
        _playNext();
      } else {
        setState(() => _nextCountdown--);
      }
    });
  }

  void _cancelNext() {
    _nextTimer?.cancel();
    if (mounted) {
      setState(() => _nextCountdown = 0);
      _scheduleHide();
    }
  }

  Future<void> _playNext() async {
    if (widget.onNext == null || _advancing) return;
    _advancing = true;
    _nextTimer?.cancel();
    await _persistProgress();
    if (!mounted) return;
    Navigator.of(context).pop();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await widget.onNext!();
  }

  int get _effectiveSyncOffsetMs =>
      (_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-15000, 15000).toInt();

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
    final next = (_manualSyncOffsetMs + deltaMs).clamp(-15000, 15000).toInt();
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
    for (var attempt = 0; attempt < 12 && mounted; attempt++) {
      final current = player.state.track.subtitle;
      dynamic chosen;
      if (current.id.toLowerCase() != 'no' && _isEnglishTrack(current)) {
        chosen = current;
      } else {
        final tracks = player.state.tracks.subtitle
            .where((track) => track.id.toLowerCase() != 'no')
            .where(_isEnglishTrack)
            .toList(growable: false)
          ..sort((a, b) {
            final aBitmap = _isImageSubtitleTrack(a) ? 1 : 0;
            final bBitmap = _isImageSubtitleTrack(b) ? 1 : 0;
            return aBitmap.compareTo(bBitmap);
          });
        if (tracks.isNotEmpty) {
          chosen = tracks.first;
          await player.setSubtitleTrack(chosen);
        }
      }

      if (chosen != null) {
        _timingTrackSelected = true;
        _timingTrackIsText = !_isImageSubtitleTrack(chosen);
        await _hideNativeTimingSubtitle();
        _startNativeSubtitleClock();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  bool _isEnglishTrack(dynamic track) {
    final language = (track.language ?? '').toString().trim().toLowerCase();
    final title = (track.title ?? '').toString().trim().toLowerCase();
    return language == 'en' ||
        language == 'eng' ||
        language.startsWith('en-') ||
        language.contains('english') ||
        title.contains('english') ||
        title == 'eng';
  }

  bool _isImageSubtitleTrack(dynamic track) {
    final codec = (track.codec ?? '').toString().trim().toLowerCase();
    return codec.contains('pgs') ||
        codec.contains('hdmv') ||
        codec.contains('dvd') ||
        codec.contains('dvb') ||
        codec.contains('vob');
  }

  bool _isEnglishTextTrack(dynamic track) =>
      _isEnglishTrack(track) && !_isImageSubtitleTrack(track);

  Future<void> _hideNativeTimingSubtitle() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      // mpv keeps the selected subtitle decoded while hiding its native render.
      // That lets Orvix use both text and PGS/bitmap cue timing as a sync clock.
      await platform.setProperty(
        'sub-visibility',
        'no',
        waitForInitialization: false,
      );
    } catch (_) {
      // The AI overlay still works even if a platform does not expose this.
    }
  }

  void _startNativeSubtitleClock() {
    _nativeSubtitleClockTimer?.cancel();
    _nativeSubtitleClockTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(_pollNativeSubtitleClock()),
    );
  }

  Future<int?> _nativeSubtitleStartMs() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return null;
    try {
      final raw = (await platform.getProperty(
        'sub-start/full',
        waitForInitialization: false,
      ))
          .trim();
      if (raw.isEmpty || raw == 'null' || raw == 'N/A') return null;
      final seconds = double.tryParse(raw);
      if (seconds == null || !seconds.isFinite || seconds < 0) return null;
      return (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  Future<void> _pollNativeSubtitleClock() async {
    if (!_aiSinhalaEnabled || !_timingTrackSelected || !mounted) return;
    final startMs = await _nativeSubtitleStartMs();
    if (startMs == null || !mounted) return;
    final previous = _lastNativeSubtitleStartMs;
    if (previous != null && (startMs - previous).abs() < 40) return;
    _lastNativeSubtitleStartMs = startMs;
    if (!_timingTrackIsText) {
      _voteBitmapTiming(startMs);
    }
  }

  void _acceptAutoSyncSample(int sample) {
    if (sample.abs() > 15000 || !mounted) return;
    _autoSyncSamples.add(sample);
    if (_autoSyncSamples.length > 7) _autoSyncSamples.removeAt(0);
    final ordered = [..._autoSyncSamples]..sort();
    final median = ordered[ordered.length ~/ 2];
    if ((median - _autoSyncOffsetMs).abs() < 40) return;
    setState(() => _autoSyncOffsetMs = median);
    _refreshAiSubtitle();
  }

  void _voteBitmapTiming(int sourceStartMs) {
    final prepared = widget.aiSubtitle;
    if (prepared == null || prepared.cues.isEmpty) return;

    // PGS/VobSub carries timing but no text. Build a small histogram of the
    // difference between source cue starts and nearby OpenSubtitles cue starts.
    // The real release offset repeats across many cues; accidental neighbours do not.
    const windowMs = 12000;
    for (final cue in prepared.cues) {
      final cueStart = cue.start.inMilliseconds;
      if (cueStart < sourceStartMs - windowMs) continue;
      if (cueStart > sourceStartMs + windowMs) break;
      final diff = sourceStartMs - cueStart;
      final bucket = (diff / 100).round() * 100;
      _bitmapOffsetVotes[bucket] = (_bitmapOffsetVotes[bucket] ?? 0) + 1;
    }

    if (_bitmapOffsetVotes.length < 2) return;
    final ranked = _bitmapOffsetVotes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final secondVotes = ranked.length > 1 ? ranked[1].value : 0;
    if (best.value >= 4 && best.value - secondVotes >= 2) {
      _acceptAutoSyncSample(best.key);
    }
  }

  void _onEmbeddedSubtitleCue(List<String> lines) {
    unawaited(_handleEmbeddedSubtitleCue(lines));
  }

  Future<void> _handleEmbeddedSubtitleCue(List<String> lines) async {
    if (!_aiSinhalaEnabled || !_timingTrackSelected || !mounted) return;
    final prepared = widget.aiSubtitle;
    if (prepared == null || !_timingTrackIsText) return;
    final source = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
    if (source.isEmpty) return;
    final matched = prepared.matchSourceCue(source);
    if (matched == null) return;
    final nativeStart = await _nativeSubtitleStartMs();
    if (!mounted) return;
    final sourceStart =
        nativeStart ?? widget.playback.player.state.position.inMilliseconds;
    _acceptAutoSyncSample(sourceStart - matched.start.inMilliseconds);
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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

  Future<void> _pickExternalSubtitle() async {
    _hideTimer?.cancel();
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) {
      if (mounted) _scheduleHide();
      return;
    }
    final name = path.split(RegExp(r'[/\\]')).last;
    await widget.playback.player.setSubtitleTrack(
      mk.SubtitleTrack.uri(path, title: name),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded subtitle: $name')),
      );
      _scheduleHide();
    }
  }

  Future<void> _showTracks() async {
    _hideTimer?.cancel();
    final player = widget.playback.player;
    final audioTracks = player.state.tracks.audio
        .where((track) => track.id.toLowerCase() != 'no')
        .toList(growable: false);
    final subtitleTracks = player.state.tracks.subtitle
        .where((track) => track.id.toLowerCase() != 'no')
        .toList(growable: false);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D120E),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .72),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Audio & Subtitles',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Switch embedded tracks or load a local subtitle file.',
                  style: TextStyle(
                      color:
                          Theme.of(sheetContext).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 22),
                const _TrackHeading(
                    icon: Icons.audiotrack_rounded, text: 'Audio'),
                const SizedBox(height: 8),
                if (audioTracks.isEmpty)
                  const _EmptyTrackMessage(
                      'No selectable audio tracks reported.')
                else
                  ...audioTracks.map(
                    (track) => _TrackTile(
                      title: _trackLabel(track.title, track.language, track.id),
                      detail: [
                        track.codec,
                        if (track.channelscount != null)
                          '${track.channelscount} ch',
                      ]
                          .whereType<String>()
                          .where((value) => value.isNotEmpty)
                          .join(' • '),
                      selected: player.state.track.audio.id == track.id,
                      onTap: () async {
                        await player.setAudioTrack(track);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                    ),
                  ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    const Expanded(
                      child: _TrackHeading(
                          icon: Icons.subtitles_rounded, text: 'Subtitles'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        await _pickExternalSubtitle();
                      },
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Load file'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                              ? 'Auto-synced from this video’s embedded English subtitle timing. Adjust only if it still looks off.'
                              : 'Orvix is using release-matched timing. Adjust only if this source is still out of sync.',
                          style: TextStyle(
                            color: Theme.of(sheetContext)
                                .colorScheme
                                .onSurfaceVariant,
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
                                if (sheetContext.mounted)
                                  Navigator.pop(sheetContext);
                              },
                              child: const Text('Earlier -0.5s'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await _resetManualSync();
                                if (sheetContext.mounted)
                                  Navigator.pop(sheetContext);
                              },
                              child: const Text('Reset manual'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                await _adjustManualSync(500);
                                if (sheetContext.mounted)
                                  Navigator.pop(sheetContext);
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
                  title: 'Off',
                  detail: 'Disable subtitles',
                  selected:
                      player.state.track.subtitle.id.toLowerCase() == 'no',
                  onTap: () async {
                    await player.setSubtitleTrack(mk.SubtitleTrack.no());
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                ),
                ...subtitleTracks.map(
                  (track) => _TrackTile(
                    title: _trackLabel(track.title, track.language, track.id),
                    detail: track.codec ?? 'Embedded subtitle',
                    selected: player.state.track.subtitle.id == track.id,
                    onTap: () async {
                      await player.setSubtitleTrack(track);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) _scheduleHide();
  }

  String _trackLabel(String? title, String? language, String id) {
    final cleanTitle = title?.trim();
    final cleanLanguage = language?.trim();
    if (cleanTitle != null && cleanTitle.isNotEmpty) {
      return cleanLanguage == null || cleanLanguage.isEmpty
          ? cleanTitle
          : '$cleanTitle • ${cleanLanguage.toUpperCase()}';
    }
    if (cleanLanguage != null && cleanLanguage.isNotEmpty) {
      return cleanLanguage.toUpperCase();
    }
    return 'Track $id';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _nextTimer?.cancel();
    _startupTimer?.cancel();
    _nativeSubtitleClockTimer?.cancel();
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _subtitleTimingSubscription?.cancel();
    _persistProgress();
    _focusNode.dispose();
    widget.playback.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.playback.player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() => _controlsVisible = !_controlsVisible);
              if (_controlsVisible) _scheduleHide();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_error == null)
                  Video(
                    controller: widget.playback.controller,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                    subtitleViewConfiguration: SubtitleViewConfiguration(
                      visible: !_aiSinhalaEnabled,
                    ),
                  )
                else
                  _errorView(context),
                if (_error == null)
                  StreamBuilder<bool>(
                    stream: player.stream.buffering,
                    initialData: player.state.buffering,
                    builder: (context, snapshot) => snapshot.data == true
                        ? const Center(child: CircularProgressIndicator())
                        : const SizedBox.shrink(),
                  ),
                if (_aiSinhalaEnabled && _aiDisplaySubtitle.isNotEmpty)
                  _aiSubtitleOverlay(),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _controls(context),
                  ),
                ),
                if (_nextCountdown > 0) _nextEpisodeOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _nextEpisodeOverlay() {
    return Positioned(
      right: 28,
      bottom: 116,
      child: Container(
        width: 330,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xEE11141C),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF343A4D)),
          boxShadow: const [
            BoxShadow(color: Color(0x77000000), blurRadius: 28)
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Up next',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
              widget.nextEpisodeLabel ?? 'Next episode',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text('Playing in $_nextCountdown seconds'),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _playNext,
                    icon: const Icon(Icons.skip_next_rounded),
                    label: const Text('Play now'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _cancelNext, child: const Text('Cancel')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 54),
            const SizedBox(height: 16),
            Text('Could not start playback',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final player = widget.playback.player;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xA8000000), Color(0x00000000), Color(0xDD000000)],
          stops: [0, .52, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Back (Esc)',
                    onPressed: _handleEscape,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const _KeyboardHint('←/→ 10s'),
                  const SizedBox(width: 8),
                  const _KeyboardHint('Space Play/Pause'),
                  if (_desktop) ...[
                    const SizedBox(width: 8),
                    const _KeyboardHint('F Fullscreen'),
                  ],
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: StreamBuilder<Duration>(
                stream: player.stream.duration,
                initialData: player.state.duration,
                builder: (context, durationSnapshot) {
                  final duration = durationSnapshot.data ?? Duration.zero;
                  return StreamBuilder<Duration>(
                    stream: player.stream.position,
                    initialData: player.state.position,
                    builder: (context, positionSnapshot) {
                      final position = positionSnapshot.data ?? Duration.zero;
                      final maxMs = duration.inMilliseconds <= 0
                          ? 1.0
                          : duration.inMilliseconds.toDouble();
                      final actualMs =
                          (_seekPreviewMs ?? position.inMilliseconds.toDouble())
                              .clamp(0, maxMs)
                              .toDouble();
                      return Column(
                        children: [
                          StreamBuilder<Duration>(
                            stream: player.stream.buffer,
                            initialData: player.state.buffer,
                            builder: (context, bufferSnapshot) {
                              final bufferedMs =
                                  (bufferSnapshot.data ?? Duration.zero)
                                      .inMilliseconds
                                      .toDouble()
                                      .clamp(actualMs, maxMs)
                                      .toDouble();
                              return SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3.5,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                ),
                                child: Slider(
                                  value: actualMs,
                                  max: maxMs,
                                  secondaryTrackValue: bufferedMs,
                                  onChangeStart: (_) {
                                    _hideTimer?.cancel();
                                    setState(() => _seeking = true);
                                  },
                                  onChanged: (value) =>
                                      setState(() => _seekPreviewMs = value),
                                  onChangeEnd: (value) async {
                                    await player.seek(
                                        Duration(milliseconds: value.round()));
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
                          Row(
                            children: [
                              StreamBuilder<bool>(
                                stream: player.stream.playing,
                                initialData: player.state.playing,
                                builder: (context, snapshot) =>
                                    IconButton.filled(
                                  tooltip:
                                      snapshot.data == true ? 'Pause' : 'Play',
                                  onPressed: player.playOrPause,
                                  icon: Icon(
                                    snapshot.data == true
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: 28,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              IconButton(
                                tooltip: 'Back 10 seconds',
                                onPressed: () =>
                                    _seekRelative(const Duration(seconds: -10)),
                                icon: const Icon(Icons.replay_10_rounded),
                              ),
                              IconButton(
                                tooltip: 'Forward 10 seconds',
                                onPressed: () =>
                                    _seekRelative(const Duration(seconds: 10)),
                                icon: const Icon(Icons.forward_10_rounded),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${_format(position)} / ${_format(duration)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(width: 14),
                              StreamBuilder<double>(
                                stream: player.stream.volume,
                                initialData: player.state.volume,
                                builder: (context, snapshot) {
                                  final volume = (snapshot.data ?? 100)
                                      .clamp(0, 100)
                                      .toDouble();
                                  return Row(
                                    children: [
                                      IconButton(
                                        tooltip: volume <= 0
                                            ? 'Unmute (M)'
                                            : 'Mute (M)',
                                        onPressed: _toggleMute,
                                        icon: Icon(
                                          volume <= 0
                                              ? Icons.volume_off_rounded
                                              : volume < 50
                                                  ? Icons.volume_down_rounded
                                                  : Icons.volume_up_rounded,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 92,
                                        child: Slider(
                                          min: 0,
                                          max: 100,
                                          value: volume,
                                          onChanged: (value) {
                                            if (value > 0) _lastVolume = value;
                                            player.setVolume(value);
                                          },
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Audio & subtitles',
                                onPressed: _showTracks,
                                icon: const Icon(Icons.subtitles_rounded),
                              ),
                              PopupMenuButton<double>(
                                tooltip: 'Playback speed',
                                initialValue: player.state.rate,
                                onSelected: player.setRate,
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: .5, child: Text('0.5×')),
                                  PopupMenuItem(
                                      value: .75, child: Text('0.75×')),
                                  PopupMenuItem(value: 1, child: Text('1×')),
                                  PopupMenuItem(
                                      value: 1.25, child: Text('1.25×')),
                                  PopupMenuItem(
                                      value: 1.5, child: Text('1.5×')),
                                  PopupMenuItem(value: 2, child: Text('2×')),
                                ],
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0x551A1D26),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: const Color(0x44FFFFFF)),
                                  ),
                                  child: Text(
                                    '${player.state.rate.toStringAsFixed(player.state.rate == 1 ? 0 : 2)}×',
                                  ),
                                ),
                              ),
                              if (_desktop) ...[
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Fullscreen (F / F11)',
                                  onPressed: _toggleFullscreen,
                                  icon: const Icon(Icons.fullscreen_rounded),
                                ),
                              ],
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minutes:$seconds'
        : '${value.inMinutes}:$seconds';
  }
}

class _TrackHeading extends StatelessWidget {
  const _TrackHeading({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 9),
        Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_off_rounded,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: detail.isEmpty ? null : Text(detail),
      onTap: onTap,
    );
  }
}

class _EmptyTrackMessage extends StatelessWidget {
  const _EmptyTrackMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _KeyboardHint extends StatelessWidget {
  const _KeyboardHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x55000000),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
