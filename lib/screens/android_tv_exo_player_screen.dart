import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/media_item.dart';
import '../services/media_state_service.dart';

/// Android-TV-only safe player used for local P2P HTTP streams.
///
/// This deliberately bypasses media_kit/libmpv so P2P playback can be tested
/// independently from the MPV native stack. video_player uses Android Media3 /
/// ExoPlayer underneath on Android.
class AndroidTvExoPlayerScreen extends StatefulWidget {
  const AndroidTvExoPlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.mediaState,
    this.item,
    this.episode,
    this.nextEpisodeLabel,
    this.onNext,
  });

  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final String? nextEpisodeLabel;
  final Future<void> Function()? onNext;

  @override
  State<AndroidTvExoPlayerScreen> createState() =>
      _AndroidTvExoPlayerScreenState();
}

class _AndroidTvExoPlayerScreenState extends State<AndroidTvExoPlayerScreen> {
  final FocusNode _focusNode = FocusNode();

  VideoPlayerController? _controller;
  Timer? _uiTimer;
  Timer? _saveTimer;
  Timer? _hideTimer;
  String? _error;
  bool _controlsVisible = true;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && !_closing) setState(() {});
    });
    _saveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_persistProgress()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _scheduleHide();
    });
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller = controller;
    try {
      await controller.initialize();
      if (_closing) return;

      final item = widget.item;
      final mediaState = widget.mediaState;
      if (item != null && mediaState != null) {
        final resume = await mediaState.resumePosition(
          item,
          episode: widget.episode,
        );
        if (resume != null &&
            resume > const Duration(seconds: 10) &&
            resume < controller.value.duration) {
          await controller.seekTo(resume);
        }
      }

      await controller.play();
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted && !_closing) {
        setState(() => _error = 'ExoPlayer could not open this stream.\n$error');
      }
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_closing) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _showControls();
  }

  Future<void> _seekRelative(Duration delta) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await controller.seekTo(target);
    _showControls();
  }

  Future<void> _persistProgress() async {
    final controller = _controller;
    final item = widget.item;
    final mediaState = widget.mediaState;
    if (controller == null ||
        !controller.value.isInitialized ||
        item == null ||
        mediaState == null) {
      return;
    }
    try {
      await mediaState.saveProgress(
        item,
        position: controller.value.position,
        duration: controller.value.duration,
        episode: widget.episode,
      );
    } catch (_) {}
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    _uiTimer?.cancel();
    _saveTimer?.cancel();
    await _persistProgress();
    try {
      await _controller?.pause();
    } catch (_) {}
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_togglePlayPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekRelative(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekRelative(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      unawaited(() async {
        await _close();
        if (mounted) Navigator.of(context).maybePop();
      }());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _closing = true;
    _hideTimer?.cancel();
    _uiTimer?.cancel();
    _saveTimer?.cancel();
    _focusNode.dispose();
    unawaited(_persistProgress());
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final value = controller?.value;

    return WillPopScope(
      onWillPop: () async {
        await _close();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_error != null)
                  _errorView()
                else if (value?.isInitialized == true)
                  Center(
                    child: AspectRatio(
                      aspectRatio: value!.aspectRatio > 0
                          ? value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(controller!),
                    ),
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                if (_error == null &&
                    value?.isInitialized == true &&
                    value!.isBuffering)
                  const Center(child: CircularProgressIndicator()),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _controls(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 56),
              const SizedBox(height: 18),
              Text(
                _error ?? 'Playback failed.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, height: 1.45),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () async {
                  await _controller?.dispose();
                  _controller = null;
                  if (mounted) setState(() => _error = null);
                  await _open();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final controller = _controller;
    final value = controller?.value;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    final totalMs = duration.inMilliseconds;
    final currentMs = position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB8000000), Color(0x00000000), Color(0xD9000000)],
          stops: [0, .45, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(34, 28, 34, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: 'Back',
                  onPressed: () async {
                    await _close();
                    if (mounted) Navigator.of(context).maybePop();
                  },
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'ExoPlayer • TV safe mode',
                  style: TextStyle(color: Color(0xFFB8C2B5)),
                ),
              ],
            ),
            const Spacer(),
            if (totalMs > 0)
              Slider(
                value: currentMs.toDouble(),
                min: 0,
                max: totalMs.toDouble(),
                onChanged: (next) {
                  unawaited(
                    controller?.seekTo(
                          Duration(milliseconds: next.round()),
                        ) ??
                        Future<void>.value(),
                  );
                  _showControls();
                },
              ),
            Row(
              children: [
                IconButton.filled(
                  tooltip: value?.isPlaying == true ? 'Pause' : 'Play',
                  onPressed: _togglePlayPause,
                  icon: Icon(
                    value?.isPlaying == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 10),
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
                const SizedBox(width: 14),
                Text(
                  '${_format(position)} / ${_format(duration)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (widget.nextEpisodeLabel != null)
                  Text(
                    'Next: ${widget.nextEpisodeLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFB8C2B5)),
                  ),
              ],
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
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
