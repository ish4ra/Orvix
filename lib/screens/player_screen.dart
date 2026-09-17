import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../models/media_item.dart';
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
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  final FocusNode _focusNode = FocusNode();
  bool _aiSinhalaEnabled = false;
  String _aiDisplaySubtitle = '';

  bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _aiSinhalaEnabled = widget.aiSubtitle != null;
    if (_aiSinhalaEnabled) {
      _positionSubscription = widget.playback.player.stream.position.listen(_onPosition);
    }
    _open();
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _persistProgress());
    _completedSubscription = widget.playback.player.stream.completed.listen((completed) {
      if (completed) _startNextCountdown();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  Future<void> _open() async {
    try {
      await widget.playback.open(widget.url, title: widget.title);
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
    if (player.state.duration > Duration.zero && target > player.state.duration) {
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
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
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

  void _onPosition(Duration position) {
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
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * .72),
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
                  style: TextStyle(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 22),
                const _TrackHeading(icon: Icons.audiotrack_rounded, text: 'Audio'),
                const SizedBox(height: 8),
                if (audioTracks.isEmpty)
                  const _EmptyTrackMessage('No selectable audio tracks reported.')
                else
                  ...audioTracks.map(
                    (track) => _TrackTile(
                      title: _trackLabel(track.title, track.language, track.id),
                      detail: [
                        track.codec,
                        if (track.channelscount != null) '${track.channelscount} ch',
                      ].whereType<String>().where((value) => value.isNotEmpty).join(' • '),
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
                      child: _TrackHeading(icon: Icons.subtitles_rounded, text: 'Subtitles'),
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
                const SizedBox(height: 8),
                _TrackTile(
                  title: 'Off',
                  detail: 'Disable subtitles',
                  selected: player.state.track.subtitle.id.toLowerCase() == 'no',
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
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
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
          boxShadow: const [BoxShadow(color: Color(0x77000000), blurRadius: 28)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Up next', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
            Text('Could not start playback', style: Theme.of(context).textTheme.headlineSmall),
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
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
                      final actualMs = (_seekPreviewMs ?? position.inMilliseconds.toDouble())
                          .clamp(0, maxMs)
                          .toDouble();
                      return Column(
                        children: [
                          StreamBuilder<Duration>(
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
                          Row(
                            children: [
                              StreamBuilder<bool>(
                                stream: player.stream.playing,
                                initialData: player.state.playing,
                                builder: (context, snapshot) => IconButton.filled(
                                  tooltip: snapshot.data == true ? 'Pause' : 'Play',
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
                                onPressed: () => _seekRelative(const Duration(seconds: -10)),
                                icon: const Icon(Icons.replay_10_rounded),
                              ),
                              IconButton(
                                tooltip: 'Forward 10 seconds',
                                onPressed: () => _seekRelative(const Duration(seconds: 10)),
                                icon: const Icon(Icons.forward_10_rounded),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${_format(position)} / ${_format(duration)}',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(width: 14),
                              StreamBuilder<double>(
                                stream: player.stream.volume,
                                initialData: player.state.volume,
                                builder: (context, snapshot) {
                                  final volume = (snapshot.data ?? 100).clamp(0, 100).toDouble();
                                  return Row(
                                    children: [
                                      IconButton(
                                        tooltip: volume <= 0 ? 'Unmute (M)' : 'Mute (M)',
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
                                  PopupMenuItem(value: .75, child: Text('0.75×')),
                                  PopupMenuItem(value: 1, child: Text('1×')),
                                  PopupMenuItem(value: 1.25, child: Text('1.25×')),
                                  PopupMenuItem(value: 1.5, child: Text('1.5×')),
                                  PopupMenuItem(value: 2, child: Text('2×')),
                                ],
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0x551A1D26),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0x44FFFFFF)),
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
    return hours > 0 ? '$hours:$minutes:$seconds' : '${value.inMinutes}:$seconds';
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
        Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
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
        selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
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
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
