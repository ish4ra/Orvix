import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/media_item.dart';
import '../services/media_state_service.dart';

class AndroidExoPlayerResult {
  const AndroidExoPlayerResult({
    this.failed = false,
    this.switchToMpv = false,
    this.started = false,
    this.error,
  });

  final bool failed;
  final bool switchToMpv;
  final bool started;
  final String? error;
}

class AndroidExoPlayerScreen extends StatefulWidget {
  const AndroidExoPlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.mediaState,
    this.item,
    this.episode,
    this.httpHeaders,
    this.autoFallbackToMpv = false,
  });

  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final Map<String, String>? httpHeaders;
  final bool autoFallbackToMpv;

  @override
  State<AndroidExoPlayerScreen> createState() => _AndroidExoPlayerScreenState();
}

class _AndroidExoPlayerScreenState extends State<AndroidExoPlayerScreen> {
  final FocusNode _surfaceFocus = FocusNode(debugLabel: 'exo-surface');
  final FocusNode _backFocus = FocusNode(debugLabel: 'exo-back');
  final FocusNode _playFocus = FocusNode(debugLabel: 'exo-play');
  final FocusNode _switchFocus = FocusNode(debugLabel: 'exo-switch');

  VideoPlayerController? _controller;
  Timer? _hideTimer;
  Timer? _saveTimer;
  bool _controlsVisible = true;
  bool _controlFocused = false;
  bool _closing = false;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: widget.httpHeaders ?? const <String, String>{},
    );
    _controller = controller;
    controller.addListener(_onControllerChanged);

    try {
      await controller.initialize().timeout(const Duration(seconds: 35));
      if (!mounted || _closing) return;

      final mediaState = widget.mediaState;
      final item = widget.item;
      if (mediaState != null && item != null) {
        final resume = await mediaState.resumePosition(
          item,
          episode: widget.episode,
        );
        if (resume != null &&
            resume > const Duration(seconds: 5) &&
            resume < controller.value.duration - const Duration(seconds: 10)) {
          await controller.seekTo(resume);
        }
      }

      if (!mounted || _closing) return;
      setState(() {
        _initialized = true;
        _error = null;
      });

      await controller.play();
      _saveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_persistProgress()),
      );
      _showControls();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _surfaceFocus.requestFocus();
      });
    } on TimeoutException {
      await _fail(
        'ExoPlayer could not initialize this stream within 35 seconds.',
      );
    } catch (error) {
      await _fail('ExoPlayer could not open this stream: $error');
    }
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null || !mounted || _closing) return;
    final value = controller.value;

    if (value.hasError && _error == null) {
      unawaited(
        _fail(
          value.errorDescription?.trim().isNotEmpty == true
              ? value.errorDescription!
              : 'ExoPlayer reported a playback error.',
        ),
      );
      return;
    }

    if (_initialized) setState(() {});
  }

  Future<void> _fail(String message) async {
    if (!mounted || _closing) return;
    setState(() => _error = message);
    _hideTimer?.cancel();

    if (widget.autoFallbackToMpv) {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!mounted || _closing) return;
      await _close(
        failed: true,
        switchToMpv: true,
        error: message,
      );
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _switchFocus.requestFocus();
    });
  }

  void _showControls() {
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer?.cancel();
    if (_controlFocused || _error != null) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _controlFocused || _error != null) return;
      setState(() => _controlsVisible = false);
      _surfaceFocus.requestFocus();
    });
  }

  void _onControlFocus(bool focused) {
    _controlFocused = focused;
    if (focused) {
      _hideTimer?.cancel();
      if (!_controlsVisible && mounted) {
        setState(() => _controlsVisible = true);
      }
    } else {
      _showControls();
    }
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _showControls();
  }

  Future<void> _seekRelative(Duration offset) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    final target = value.position + offset;
    final bounded = target < Duration.zero
        ? Duration.zero
        : target > value.duration
            ? value.duration
            : target;
    await controller.seekTo(bounded);
    _showControls();
  }

  KeyEventResult _onSurfaceKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
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
      _playFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _persistProgress() async {
    final controller = _controller;
    final mediaState = widget.mediaState;
    final item = widget.item;
    if (controller == null ||
        !controller.value.isInitialized ||
        mediaState == null ||
        item == null) {
      return;
    }
    final value = controller.value;
    await mediaState.saveProgress(
      item,
      episode: widget.episode,
      position: value.position,
      duration: value.duration,
    );
  }

  Future<void> _close({
    bool failed = false,
    bool switchToMpv = false,
    String? error,
  }) async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    await _persistProgress();
    try {
      await _controller?.pause();
    } catch (_) {}

    if (!mounted) return;
    Navigator.of(context).pop(
      AndroidExoPlayerResult(
        failed: failed,
        switchToMpv: switchToMpv,
        started: _initialized &&
            ((_controller?.value.isPlaying ?? false) ||
                (_controller?.value.position ?? Duration.zero) >
                    Duration.zero),
        error: error,
      ),
    );
  }

  String _format(Duration value) {
    final total = value.inSeconds.clamp(0, 24 * 60 * 60);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _controller?.removeListener(_onControllerChanged);
    unawaited(_controller?.dispose() ?? Future<void>.value());
    _surfaceFocus.dispose();
    _backFocus.dispose();
    _playFocus.dispose();
    _switchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final value = controller?.value;
    final initialized = value?.isInitialized == true;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          focusNode: _surfaceFocus,
          onKeyEvent: _onSurfaceKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
              if (initialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: value!.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio,
                    child: VideoPlayer(controller!),
                  ),
                )
              else
                const ColoredBox(color: Colors.black),
              if (!initialized && _error == null)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              if (value?.isBuffering == true && _error == null)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              if (_controlsVisible && _error == null)
                _controls(value),
              if (_error != null) _errorView(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(VideoPlayerValue? value) {
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    final played = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xC4000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0xEA000000),
          ],
          stops: [0, .22, .58, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
              child: Row(
                children: [
                  _ExoAction(
                    focusNode: _backFocus,
                    icon: Icons.arrow_back_rounded,
                    semanticLabel: 'Back',
                    onFocusChange: _onControlFocus,
                    onPressed: () => unawaited(_close()),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 0, 38, 28),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        _format(position),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value: played,
                            backgroundColor: const Color(0xFF484D49),
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _format(duration),
                        style: const TextStyle(
                          color: Color(0xFFC0C4C1),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      _ExoAction(
                        icon: Icons.replay_10_rounded,
                        semanticLabel: 'Back 10 seconds',
                        onFocusChange: _onControlFocus,
                        onPressed: () => unawaited(
                          _seekRelative(const Duration(seconds: -10)),
                        ),
                      ),
                      _ExoAction(
                        focusNode: _playFocus,
                        icon: value?.isPlaying == true
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        semanticLabel:
                            value?.isPlaying == true ? 'Pause' : 'Play',
                        prominent: true,
                        onFocusChange: _onControlFocus,
                        onPressed: () => unawaited(_togglePlay()),
                      ),
                      _ExoAction(
                        icon: Icons.forward_10_rounded,
                        semanticLabel: 'Forward 10 seconds',
                        onFocusChange: _onControlFocus,
                        onPressed: () => unawaited(
                          _seekRelative(const Duration(seconds: 10)),
                        ),
                      ),
                      _ExoAction(
                        focusNode: _switchFocus,
                        icon: Icons.swap_horiz_rounded,
                        label: 'Use MPV',
                        semanticLabel: 'Switch to MPV',
                        onFocusChange: _onControlFocus,
                        onPressed: () => unawaited(
                          _close(switchToMpv: true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white,
                size: 52,
              ),
              const SizedBox(height: 18),
              const Text(
                'ExoPlayer could not play this source',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFB8BDBA),
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  _ExoAction(
                    focusNode: _switchFocus,
                    icon: Icons.swap_horiz_rounded,
                    label: 'Try MPV',
                    semanticLabel: 'Try MPV',
                    onFocusChange: _onControlFocus,
                    onPressed: () => unawaited(
                      _close(
                        failed: true,
                        switchToMpv: true,
                        error: _error,
                      ),
                    ),
                  ),
                  _ExoAction(
                    focusNode: _backFocus,
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    semanticLabel: 'Back',
                    onFocusChange: _onControlFocus,
                    onPressed: () => unawaited(
                      _close(failed: true, error: _error),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExoAction extends StatefulWidget {
  const _ExoAction({
    required this.icon,
    required this.onPressed,
    required this.onFocusChange,
    this.focusNode,
    this.label,
    this.semanticLabel,
    this.prominent = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChange;
  final FocusNode? focusNode;
  final String? label;
  final String? semanticLabel;
  final bool prominent;

  @override
  State<_ExoAction> createState() => _ExoActionState();
}

class _ExoActionState extends State<_ExoAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.prominent ? 64.0 : 48.0;
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        decoration: BoxDecoration(
          color: _focused
              ? const Color(0xE62A2E2B)
              : const Color(0xA8151816),
          borderRadius: BorderRadius.circular(widget.prominent ? 32 : 14),
          border: Border.all(
            color: _focused ? Colors.white : const Color(0x664F5551),
            width: _focused ? 2.2 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusNode: widget.focusNode,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            borderRadius: BorderRadius.circular(widget.prominent ? 32 : 14),
            onFocusChange: (value) {
              setState(() => _focused = value);
              widget.onFocusChange(value);
            },
            onTap: widget.onPressed,
            child: SizedBox(
              height: size,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.label == null ? 0 : 16,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: widget.label == null ? size - 2 : 30,
                      child: Icon(
                        widget.icon,
                        color: Colors.white,
                        size: widget.prominent ? 34 : 26,
                      ),
                    ),
                    if (widget.label != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        widget.label!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
