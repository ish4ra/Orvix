import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart';
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
  });

  final PlaybackService playback;
  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  String? _error;
  bool _controlsVisible = true;
  bool _seeking = false;
  double? _seekPreviewMs;
  Timer? _hideTimer;
  Timer? _saveTimer;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _open();
    _scheduleHide();
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _persistProgress());
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  Future<void> _open() async {
    try {
      await widget.playback.open(widget.url, title: widget.title);
      final item = widget.item;
      final state = widget.mediaState;
      if (item != null && state != null) {
        final resume = await state.resumePosition(item, episode: widget.episode);
        if (resume != null && resume > const Duration(seconds: 10)) {
          await widget.playback.player.seek(resume);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _persistProgress() async {
    final item = widget.item;
    final state = widget.mediaState;
    if (item == null || state == null) return;
    final playerState = widget.playback.player.state;
    await state.saveProgress(
      item,
      episode: widget.episode,
      position: playerState.position,
      duration: playerState.duration,
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_seeking) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _seekRelative(Duration offset) async {
    final current = widget.playback.player.state.position;
    final duration = widget.playback.player.state.duration;
    var target = current + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await widget.playback.player.seek(target);
    _showControls();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        widget.playback.player.playOrPause();
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekRelative(const Duration(seconds: -10));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekRelative(const Duration(seconds: 10));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
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
                  )
                else
                  _errorView(context),
                if (_error == null)
                  StreamBuilder<bool>(
                    stream: player.stream.buffering,
                    initialData: player.state.buffering,
                    builder: (context, snapshot) {
                      if (snapshot.data != true) return const SizedBox.shrink();
                      return const Center(child: CircularProgressIndicator());
                    },
                  ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _controls(context),
                  ),
                ),
              ],
            ),
          ),
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
                    onPressed: () => Navigator.of(context).maybePop(),
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
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                children: [
                  StreamBuilder<Duration>(
                    stream: player.stream.duration,
                    initialData: player.state.duration,
                    builder: (context, durationSnapshot) {
                      final duration = durationSnapshot.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: player.stream.position,
                        initialData: player.state.position,
                        builder: (context, positionSnapshot) {
                          final position = positionSnapshot.data ?? Duration.zero;
                          final maxMs = duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
                          final actualMs = (_seekPreviewMs ?? position.inMilliseconds.toDouble())
                              .clamp(0, maxMs)
                              .toDouble();
                          return Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(trackHeight: 3.5, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
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
                              Row(
                                children: [
                                  StreamBuilder<bool>(
                                    stream: player.stream.playing,
                                    initialData: player.state.playing,
                                    builder: (context, snapshot) => IconButton.filled(
                                      tooltip: snapshot.data == true ? 'Pause' : 'Play',
                                      onPressed: player.playOrPause,
                                      icon: Icon(snapshot.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28),
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
                                  Text('${_format(position)} / ${_format(duration)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                  const Spacer(),
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
                                      child: Text('${player.state.rate.toStringAsFixed(player.state.rate == 1 ? 0 : 2)}×'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ],
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
