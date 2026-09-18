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
import '../services/online_subtitle_service.dart';
import '../services/playback_service.dart';
import '../services/subtitle_preferences_service.dart';

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
    this.releaseHint,
    this.expectedSizeBytes,
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
  final String? releaseHint;
  final int? expectedSizeBytes;
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
  Timer? _liveCueClearTimer;
  StreamSubscription<bool>? _startupPlayingSubscription;
  StreamSubscription<Duration>? _startupPositionActivitySubscription;
  StreamSubscription<Duration>? _startupDurationSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  StreamSubscription<String>? _playbackErrorSubscription;
  bool _playbackStarted = false;
  bool _startupFailureVisible = false;
  final FocusNode _focusNode = FocusNode();
  AiPreparedSubtitle? _preparedAiSubtitle;
  bool _aiSinhalaEnabled = false;
  bool _aiSinhalaRequested = false;
  bool _liveAiFallback = false;
  int _liveCueGeneration = 0;
  int _lastAiPrefetchBucket = -1;
  final List<String> _liveDialogueContext = <String>[];
  bool _aiSubtitleLoading = false;
  bool _aiSubtitleUnavailable = false;
  bool _timingTrackSelected = false;
  bool _timingTrackIsText = false;
  String _aiDisplaySubtitle = '';
  int _autoSyncOffsetMs = 0;
  int _manualSyncOffsetMs = 0;
  int? _lastNativeSubtitleStartMs;
  final List<int> _autoSyncSamples = <int>[];
  final Map<int, int> _bitmapOffsetVotes = <int, int>{};
  int _embeddedMismatchCount = 0;
  double _subtitleFontSize = SubtitlePreferencesService.defaultFontSize;
  bool _subtitleBackground = SubtitlePreferencesService.defaultBackground;
  double _subtitleBackgroundOpacity =
      SubtitlePreferencesService.defaultBackgroundOpacity;
  double _subtitleBottomOffset = SubtitlePreferencesService.defaultBottomOffset;
  double _subtitleDelaySeconds = 0;
  String _preferredSubtitleLanguage =
      SubtitlePreferencesService.defaultPreferredLanguage;
  bool _subtitleChoiceOverridden = false;
  bool _androidMobilePlayerMode = false;
  bool _mobilePortraitPlayer = false;

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _preparedAiSubtitle = widget.aiSubtitle;
    _aiSinhalaEnabled = _preparedAiSubtitle != null;
    _aiSinhalaRequested = _preparedAiSubtitle != null;
    unawaited(_loadSubtitlePreferences());
    _playbackErrorSubscription =
        widget.playback.player.stream.error.listen(_onPlaybackError);
    _startupPlayingSubscription =
        widget.playback.player.stream.playing.listen((playing) {
      if (playing) _markPlaybackStarted();
    });
    _startupPositionActivitySubscription =
        widget.playback.player.stream.position.listen((position) {
      if (position > Duration.zero) _markPlaybackStarted();
    });
    _startupDurationSubscription =
        widget.playback.player.stream.duration.listen((duration) {
      if (duration > Duration.zero) _markPlaybackStarted();
    });
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      unawaited(_enterAndroidMobilePlayerMode());
    });
  }

  bool _hasPlaybackActivity() {
    final state = widget.playback.player.state;
    return _playbackStarted ||
        state.playing ||
        state.position > Duration.zero ||
        state.duration > Duration.zero;
  }

  void _markPlaybackStarted() {
    _playbackStarted = true;
    _startupTimer?.cancel();
    if (mounted && _startupFailureVisible) {
      setState(() {
        _startupFailureVisible = false;
        _error = null;
      });
    }
  }

  Future<void> _open() async {
    try {
      _playbackStarted = false;
      _startupFailureVisible = false;
      _startupTimer?.cancel();
      if (mounted && _error != null) {
        setState(() => _error = null);
      }

      final aiPreferred = _preparedAiSubtitle != null ||
          await AiSinhalaPreferencesService.isEnabled();
      if (mounted && !_subtitleChoiceOverridden) {
        setState(() {
          _aiSinhalaRequested = aiPreferred;
          _aiSinhalaEnabled =
              aiPreferred && _preparedAiSubtitle != null;
        });
      }

      await widget.playback.open(widget.url, title: widget.title);
      await _setNativeSubtitleVisibility(!_aiSinhalaRequested);
      if (_aiSinhalaEnabled) {
        unawaited(_ensureEnglishTimingTrack());
        _lastAiPrefetchBucket = -1;
        _refreshAiSubtitle();
      } else if (_aiSinhalaRequested) {
        unawaited(_prepareAiSinhalaAfterPlaybackStarts());
      }

      if (_hasPlaybackActivity()) {
        _markPlaybackStarted();
      } else {
        _startupTimer = Timer(const Duration(seconds: 30), () {
          if (!mounted) return;
          if (_hasPlaybackActivity()) {
            _markPlaybackStarted();
            return;
          }
          setState(() {
            _startupFailureVisible = true;
            _error =
                'The stream is taking longer than expected to start. '
                'Orvix will recover automatically if media begins playing.';
          });
        });
      }

      final currentVolume = widget.playback.player.state.volume;
      if (currentVolume > 0) _lastVolume = currentVolume;
      if (widget.item != null && widget.mediaState != null) {
        final resume = await widget.mediaState!.resumePosition(
          widget.item!,
          episode: widget.episode,
        );
        if (resume != null && resume > const Duration(seconds: 10)) {
          await widget.playback.player.seek(resume);
          _afterSeek(resume);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onPlaybackError(String message) {
    if (!mounted || message.trim().isEmpty || _hasPlaybackActivity()) return;
    final state = widget.playback.player.state;
    if (state.duration <= Duration.zero &&
        state.position < const Duration(seconds: 1)) {
      setState(() {
        _startupFailureVisible = true;
        _error = 'Playback engine: ${message.trim()}';
      });
    }
  }

  Future<void> _prepareAiSinhalaAfterPlaybackStarts() async {
    if (_preparedAiSubtitle != null) return;
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    if (!enabled || !mounted || _subtitleChoiceOverridden) return;

    setState(() => _aiSinhalaRequested = true);
    await _setNativeSubtitleVisibility(false);

    if (widget.item == null) {
      if (mounted) {
        setState(() {
          _aiSubtitleLoading = false;
          _aiSubtitleUnavailable = true;
        });
      }
      await _setNativeSubtitleVisibility(true);
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || _subtitleChoiceOverridden) return;
    setState(() {
      _aiSubtitleLoading = true;
      _aiSubtitleUnavailable = false;
    });
    try {
      final prepared = await AiSinhalaSubtitleService.prepareBuffered(
        item: widget.item!,
        episode: widget.episode,
        videoUrl: widget.url,
        releaseHint: widget.releaseHint,
        expectedSizeBytes: widget.expectedSizeBytes,
      );
      if (!mounted || _subtitleChoiceOverridden) return;
      if (prepared == null) {
        final embeddedReady = await _tryPrepareEmbeddedAiTiming();
        if (!mounted) return;
        if (!embeddedReady) {
          setState(() {
            _aiSubtitleLoading = false;
            _aiSubtitleUnavailable = true;
            _aiSinhalaEnabled = false;
            _aiDisplaySubtitle = '';
          });
          await _setNativeSubtitleVisibility(true);
        }
        return;
      }

      setState(() {
        _preparedAiSubtitle = prepared;
        _aiSinhalaRequested = true;
        _aiSinhalaEnabled = true;
        _liveAiFallback = false;
        _aiSubtitleLoading = false;
        _aiSubtitleUnavailable = false;
        _lastAiPrefetchBucket = -1;
      });
      _positionSubscription ??=
          widget.playback.player.stream.position.listen(_onPosition);
      _subtitleTimingSubscription ??=
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
      await _loadManualSync();
      if (!mounted) return;
      await _setNativeSubtitleDelayProperty(0);
      await _ensureEnglishTimingTrack();
      _refreshAiSubtitle();
    } catch (_) {
      if (!mounted || _subtitleChoiceOverridden) return;
      final embeddedReady = await _tryPrepareEmbeddedAiTiming();
      if (!mounted) return;
      if (!embeddedReady) {
        setState(() {
          _aiSubtitleLoading = false;
          _aiSubtitleUnavailable = true;
          _aiSinhalaEnabled = false;
          _aiDisplaySubtitle = '';
        });
        await _setNativeSubtitleVisibility(true);
      }
    }
  }

  Future<bool> _tryPrepareEmbeddedAiTiming() async {
    if (!_aiSinhalaRequested ||
        _subtitleChoiceOverridden ||
        !mounted ||
        widget.item == null) {
      return false;
    }

    final player = widget.playback.player;
    for (var attempt = 0; attempt < 12 && mounted; attempt++) {
      final current = player.state.track.subtitle;
      dynamic chosen;
      if (current.id.toLowerCase() != 'no' &&
          _isEnglishTextTrack(current)) {
        chosen = current;
      } else {
        final allTracks = player.state.tracks.subtitle
            .where((track) => track.id.toLowerCase() != 'no')
            .toList(growable: false);
        final englishText =
            allTracks.where(_isEnglishTextTrack).toList(growable: false);
        if (englishText.isNotEmpty) {
          chosen = englishText.first;
          await player.setSubtitleTrack(chosen);
        } else {
          final unknownText = allTracks.where((track) {
            if (_isImageSubtitleTrack(track)) return false;
            final language = (track.language ?? '').toString().trim();
            final title = (track.title ?? '').toString().trim();
            return language.isEmpty && title.isEmpty;
          }).toList(growable: false);
          if (unknownText.length == 1) {
            chosen = unknownText.first;
            await player.setSubtitleTrack(chosen);
          }
        }
      }

      if (chosen != null) {
        _timingTrackSelected = true;
        _timingTrackIsText = true;
        _liveAiFallback = false;
        _liveCueGeneration++;
        _liveDialogueContext.clear();
        await _hideNativeTimingSubtitle();

        final wasPlaying = player.state.playing;
        if (wasPlaying) {
          await player.pause();
        }

        try {
          if (mounted) {
            setState(() {
              _aiSubtitleLoading = true;
              _aiSubtitleUnavailable = false;
              _aiDisplaySubtitle = '';
            });
          }
          final prepared =
              await AiSinhalaSubtitleService.prepareForEmbeddedTiming(
            item: widget.item!,
            episode: widget.episode,
          );
          if (!mounted ||
              _subtitleChoiceOverridden ||
              prepared == null) {
            if (wasPlaying) await player.play();
            return false;
          }

          setState(() {
            _preparedAiSubtitle = prepared;
            _aiSinhalaRequested = true;
            _aiSinhalaEnabled = true;
            _liveAiFallback = false;
            _aiSubtitleLoading = false;
            _aiSubtitleUnavailable = false;
            _lastAiPrefetchBucket = -1;
          });
          _positionSubscription ??=
              player.stream.position.listen(_onPosition);
          _subtitleTimingSubscription ??=
              player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
          await _setNativeSubtitleDelayProperty(0);
          await _hideNativeTimingSubtitle();
          _startNativeSubtitleClock();
          if (wasPlaying) await player.play();
          return true;
        } catch (_) {
          if (wasPlaying) await player.play();
          return false;
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<void> _loadSubtitlePreferences() async {
    final fontSize = await SubtitlePreferencesService.fontSize();
    final background = await SubtitlePreferencesService.backgroundEnabled();
    final opacity = await SubtitlePreferencesService.backgroundOpacity();
    final bottomOffset = await SubtitlePreferencesService.bottomOffset();
    final language = await SubtitlePreferencesService.preferredLanguage();
    if (!mounted) return;
    setState(() {
      _subtitleFontSize = fontSize;
      _subtitleBackground = background;
      _subtitleBackgroundOpacity = opacity;
      _subtitleBottomOffset = bottomOffset;
      _preferredSubtitleLanguage =
          OnlineSubtitleService.normalizeLanguage(language);
    });
  }

  Future<void> _setNativeSubtitleVisibility(bool visible) async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      await platform.setProperty(
        'sub-visibility',
        visible ? 'yes' : 'no',
        waitForInitialization: false,
      );
    } catch (_) {}
  }

  Future<void> _setNativeSubtitleDelayProperty(double seconds) async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      await platform.setProperty(
        'sub-delay',
        seconds.toStringAsFixed(3),
        waitForInitialization: false,
      );
    } catch (_) {}
  }

  Future<void> _setSubtitleDelay(double seconds) async {
    final next = seconds.clamp(-120.0, 120.0).toDouble();
    if (mounted) setState(() => _subtitleDelaySeconds = next);
    if (!_aiSinhalaRequested) {
      await _setNativeSubtitleDelayProperty(next);
    }
  }

  Future<void> _activateNativeSubtitle(mk.SubtitleTrack track) async {
    _subtitleChoiceOverridden = true;
    _nativeSubtitleClockTimer?.cancel();
    _liveCueClearTimer?.cancel();
    _timingTrackSelected = false;
    _timingTrackIsText = false;
    _liveCueGeneration++;
    if (mounted) {
      setState(() {
        _aiSinhalaRequested = false;
        _aiSinhalaEnabled = false;
        _liveAiFallback = false;
        _aiDisplaySubtitle = '';
      });
    }
    await _setNativeSubtitleVisibility(true);
    await widget.playback.player.setSubtitleTrack(track);
    await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
  }

  Future<void> _disableSubtitles() async {
    _subtitleChoiceOverridden = true;
    _nativeSubtitleClockTimer?.cancel();
    _timingTrackSelected = false;
    _timingTrackIsText = false;
    _liveCueGeneration++;
    if (mounted) {
      setState(() {
        _aiSinhalaRequested = false;
        _aiSinhalaEnabled = false;
        _liveAiFallback = false;
        _aiDisplaySubtitle = '';
      });
    }
    await _setNativeSubtitleVisibility(true);
    await widget.playback.player.setSubtitleTrack(mk.SubtitleTrack.no());
  }

  Future<void> _enablePreparedAiSubtitle() async {
    final prepared = _preparedAiSubtitle;
    if (prepared == null) return;
    _subtitleChoiceOverridden = true;
    await _setNativeSubtitleDelayProperty(0);
    await _setNativeSubtitleVisibility(false);
    if (!mounted) return;
    setState(() {
      _aiSinhalaRequested = true;
      _aiSinhalaEnabled = true;
      _liveAiFallback = false;
      _lastAiPrefetchBucket = -1;
    });
    _positionSubscription ??=
        widget.playback.player.stream.position.listen(_onPosition);
    _subtitleTimingSubscription ??=
        widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
    await _loadManualSync();
    if (!mounted) return;
    await _ensureEnglishTimingTrack();
    _refreshAiSubtitle();
  }

  Future<void> _setSubtitleFontSize(double value) async {
    final next = value.clamp(18.0, 72.0).toDouble();
    if (mounted) setState(() => _subtitleFontSize = next);
    await SubtitlePreferencesService.setFontSize(next);
  }

  Future<void> _setSubtitleBackground(bool value) async {
    if (mounted) setState(() => _subtitleBackground = value);
    await SubtitlePreferencesService.setBackgroundEnabled(value);
  }

  Future<void> _setSubtitleBackgroundOpacity(double value) async {
    final next = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _subtitleBackgroundOpacity = next);
    await SubtitlePreferencesService.setBackgroundOpacity(next);
  }

  Future<void> _setSubtitleBottomOffset(double value) async {
    final next = value.clamp(8.0, 220.0).toDouble();
    if (mounted) setState(() => _subtitleBottomOffset = next);
    await SubtitlePreferencesService.setBottomOffset(next);
  }

  Future<void> _resetSubtitleAppearance() async {
    await SubtitlePreferencesService.resetAppearance();
    if (!mounted) return;
    setState(() {
      _subtitleFontSize = SubtitlePreferencesService.defaultFontSize;
      _subtitleBackground = SubtitlePreferencesService.defaultBackground;
      _subtitleBackgroundOpacity =
          SubtitlePreferencesService.defaultBackgroundOpacity;
      _subtitleBottomOffset = SubtitlePreferencesService.defaultBottomOffset;
    });
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
    _afterSeek(target);
    _showControls();
  }

  void _afterSeek(Duration target) {
    if (!_aiSinhalaRequested) return;
    _lastNativeSubtitleStartMs = null;
    _lastAiPrefetchBucket = -1;
    _embeddedMismatchCount = 0;
    _autoSyncSamples.clear();
    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;
    unawaited(_setNativeSubtitleVisibility(false));

    if (_liveAiFallback) {
      // Any translation request that started before the seek now belongs to
      // the old playback position. Invalidate it and remove the stale line
      // immediately instead of leaving it on screen after a jump.
      _liveCueGeneration++;
      _liveDialogueContext.clear();
      if (mounted && _aiDisplaySubtitle.isNotEmpty) {
        setState(() => _aiDisplaySubtitle = '');
      }
      return;
    }

    if (_aiSinhalaEnabled) {
      _refreshAiSubtitle();
      unawaited(_ensureEnglishTimingTrack());
      unawaited(_ensureAiTranslationNear(target));
    }
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

  Future<void> _enterAndroidMobilePlayerMode() async {
    if (!Platform.isAndroid || !mounted) return;
    final size = MediaQuery.sizeOf(context);
    if (size.shortestSide >= 600) return;

    _androidMobilePlayerMode = true;
    _mobilePortraitPlayer = false;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _toggleMobileOrientation() async {
    if (!_androidMobilePlayerMode) return;
    _mobilePortraitPlayer = !_mobilePortraitPlayer;
    await SystemChrome.setPreferredOrientations(
      _mobilePortraitPlayer
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _showControls();
  }

  Future<void> _restoreAndroidMobilePlayerMode() async {
    if (!_androidMobilePlayerMode) return;
    _androidMobilePlayerMode = false;
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
      (_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-120000, 120000).toInt();

  Future<void> _loadManualSync() async {
    final prepared = _preparedAiSubtitle;
    if (prepared == null) return;
    final value = await AiSinhalaPreferencesService.syncOffsetMs(prepared.key);
    if (!mounted) return;
    setState(() => _manualSyncOffsetMs = value);
    _refreshAiSubtitle();
  }

  Future<void> _adjustManualSync(int deltaMs) async {
    final prepared = _preparedAiSubtitle;
    if (prepared == null) return;
    final next = (_manualSyncOffsetMs + deltaMs).clamp(-120000, 120000).toInt();
    if (mounted) setState(() => _manualSyncOffsetMs = next);
    await AiSinhalaPreferencesService.setSyncOffsetMs(prepared.key, next);
    _refreshAiSubtitle();
  }

  Future<void> _resetManualSync() async {
    final prepared = _preparedAiSubtitle;
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
    final prepared = _preparedAiSubtitle;
    if (!_aiSinhalaEnabled ||
        _liveAiFallback ||
        prepared == null ||
        !mounted ||
        (_timingTrackSelected && _timingTrackIsText)) {
      return;
    }
    var adjustedMs = position.inMilliseconds - _effectiveSyncOffsetMs;
    if (adjustedMs < 0) adjustedMs = 0;
    final adjusted = Duration(milliseconds: adjustedMs);
    final next = prepared.subtitleAt(adjusted);
    if (next != _aiDisplaySubtitle) {
      setState(() => _aiDisplaySubtitle = next);
    }

    final cueIndex = prepared.cueIndexNear(adjusted);
    if (cueIndex < 0) return;
    final bucket = cueIndex ~/ 12;
    if (bucket != _lastAiPrefetchBucket) {
      _lastAiPrefetchBucket = bucket;
      unawaited(_ensureAiTranslationNear(adjusted, bucket: bucket));
    }
  }

  Future<void> _ensureAiTranslationNear(
    Duration position, {
    int? bucket,
  }) async {
    final prepared = _preparedAiSubtitle;
    if (!_aiSinhalaEnabled ||
        _liveAiFallback ||
        prepared == null ||
        !mounted) {
      return;
    }
    try {
      await AiSinhalaSubtitleService.ensureTranslatedAround(
        prepared,
        position,
        lookBehind: 4,
        lookAhead: 120,
      );
      if (!mounted ||
          !_aiSinhalaEnabled ||
          _liveAiFallback ||
          _preparedAiSubtitle?.key != prepared.key) {
        return;
      }
      _refreshAiSubtitle();
    } catch (_) {
      if (mounted &&
          (bucket == null || bucket == _lastAiPrefetchBucket)) {
        _lastAiPrefetchBucket = -1;
      }
    }
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
        final allTracks = player.state.tracks.subtitle
            .where((track) => track.id.toLowerCase() != 'no')
            .toList(growable: false);
        final tracks = allTracks.where(_isEnglishTrack).toList(growable: false)
          ..sort((a, b) {
            final aBitmap = _isImageSubtitleTrack(a) ? 1 : 0;
            final bBitmap = _isImageSubtitleTrack(b) ? 1 : 0;
            return aBitmap.compareTo(bBitmap);
          });
        if (tracks.isNotEmpty) {
          chosen = tracks.first;
          await player.setSubtitleTrack(chosen);
        } else {
          final unknownText = allTracks.where((track) {
            if (_isImageSubtitleTrack(track)) return false;
            final language = (track.language ?? '').toString().trim();
            final title = (track.title ?? '').toString().trim();
            return language.isEmpty && title.isEmpty;
          }).toList(growable: false);
          if (unknownText.length == 1) {
            chosen = unknownText.first;
            await player.setSubtitleTrack(chosen);
          }
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
      // Reset normal-subtitle delay so AI timing uses the source cue clock.
      await platform.setProperty(
        'sub-delay',
        '0',
        waitForInitialization: false,
      );
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

  Future<int?> _nativeSubtitleEndMs() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return null;
    try {
      final raw = (await platform.getProperty(
        'sub-end/full',
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
    if (sample.abs() > 120000 || !mounted) return;
    _autoSyncSamples.add(sample);
    if (_autoSyncSamples.length > 7) _autoSyncSamples.removeAt(0);

    // Never let a single fuzzy cue move the whole subtitle timeline.
    if (_autoSyncSamples.length < 3) return;
    final ordered = [..._autoSyncSamples]..sort();
    final median = ordered[ordered.length ~/ 2];
    final deviations = ordered.map((value) => (value - median).abs()).toList()
      ..sort();
    final medianDeviation = deviations[deviations.length ~/ 2];
    if (medianDeviation > 1200) return;
    if ((median - _autoSyncOffsetMs).abs() < 80) return;
    setState(() => _autoSyncOffsetMs = median);
    _refreshAiSubtitle();
  }

  void _voteBitmapTiming(int sourceStartMs) {
    final prepared = _preparedAiSubtitle;
    if (prepared == null || prepared.cues.isEmpty) return;

    // PGS/VobSub carries timing but no text. Build a small histogram of the
    // difference between source cue starts and nearby OpenSubtitles cue starts.
    // The real release offset repeats across many cues; accidental neighbours do not.
    const windowMs = 120000;
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
    if (!_aiSinhalaRequested || !_timingTrackSelected || !mounted) return;
    final source = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();

    if (source.isEmpty) {
      if (_liveAiFallback) {
        // mpv can emit an empty subtitle event at cue boundaries. Do not
        // invalidate a translation request that is still finishing; its
        // native sub-end timestamp decides whether it is still worth showing.
        if (_liveCueClearTimer == null &&
            _aiDisplaySubtitle.isNotEmpty &&
            mounted) {
          _liveCueClearTimer = Timer(const Duration(milliseconds: 180), () {
            _liveCueClearTimer = null;
            if (mounted && _liveAiFallback) {
              setState(() => _aiDisplaySubtitle = '');
            }
          });
        }
      } else if (_timingTrackIsText) {
        _liveCueGeneration++;
        if (_aiDisplaySubtitle.isNotEmpty && mounted) {
          setState(() => _aiDisplaySubtitle = '');
        }
      }
      return;
    }

    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;

    if (_liveAiFallback) {
      await _translateLiveSubtitleCue(source);
      return;
    }

    if (!_aiSinhalaEnabled) return;
    final prepared = _preparedAiSubtitle;
    if (prepared == null || !_timingTrackIsText) return;

    // When the file itself has an English text track, its cue events are the
    // authoritative clock. Match that text to the already translated external
    // subtitle and render Sinhala on the file's real cue timing instead of
    // trying to continuously offset a different release timeline.
    final matched = prepared.matchSourceCue(source);
    if (matched != null) {
      _embeddedMismatchCount = 0;
      final generation = ++_liveCueGeneration;
      final ready = matched.translation?.trim() ?? '';
      if (ready.isNotEmpty) {
        if (mounted) setState(() => _aiDisplaySubtitle = ready);
      } else {
        if (_aiDisplaySubtitle.isNotEmpty && mounted) {
          setState(() => _aiDisplaySubtitle = '');
        }
        try {
          await AiSinhalaSubtitleService.ensureTranslatedAround(
            prepared,
            matched.start,
            lookBehind: 2,
            lookAhead: 120,
          );
          if (!mounted ||
              generation != _liveCueGeneration ||
              _liveAiFallback) {
            return;
          }
          final translated = matched.translation?.trim() ?? '';
          if (translated.isNotEmpty) {
            setState(() => _aiDisplaySubtitle = translated);
          }
        } catch (_) {}
      }

      // Keep a large translated runway ahead so later dialogue does not
      // disappear when the next batch is requested.
      unawaited(
        AiSinhalaSubtitleService.ensureTranslatedAround(
          prepared,
          matched.start,
          lookBehind: 2,
          lookAhead: 120,
        ),
      );
      return;
    }

    _embeddedMismatchCount++;
    _liveCueGeneration++;
    if (_aiDisplaySubtitle.isNotEmpty && mounted) {
      setState(() => _aiDisplaySubtitle = '');
    }

    // The embedded text track is the real video clock. If a transcript line
    // cannot be matched, omit only that line. Never fall back to translating
    // the already-started cue live, because network latency makes that path
    // inherently late and caused the disappear/flash behaviour seen in alpha.04.
    if (_embeddedMismatchCount >= 12) {
      _embeddedMismatchCount = 0;
    }
    return;
  }

  Future<void> _translateLiveSubtitleCue(String source) async {
    final generation = ++_liveCueGeneration;
    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;

    final cueEndMs = await _nativeSubtitleEndMs();
    if (!mounted || generation != _liveCueGeneration) return;

    // Never leave the previous dialogue on screen while a new cue is being
    // translated.
    if (_aiDisplaySubtitle.isNotEmpty) {
      setState(() => _aiDisplaySubtitle = '');
    }

    try {
      final translation = await AiSinhalaSubtitleService.translateCue(
        title: widget.title,
        text: source,
        context: _liveDialogueContext,
      );
      if (!mounted ||
          !_liveAiFallback ||
          generation != _liveCueGeneration) {
        return;
      }

      final nowMs = widget.playback.player.state.position.inMilliseconds;
      final remainingMs =
          cueEndMs == null ? 1800 : cueEndMs - nowMs;

      // If AI returned after the actual cue has essentially ended, skip it.
      // Showing a late result for 100-300ms is the "flashing" behaviour that
      // made subtitles look broken.
      if (remainingMs < 700) return;

      setState(() => _aiDisplaySubtitle = translation);
      _liveDialogueContext.add(source);
      if (_liveDialogueContext.length > 6) {
        _liveDialogueContext.removeAt(0);
      }

      _liveCueClearTimer = Timer(
        Duration(milliseconds: remainingMs.clamp(700, 8000)),
        () {
          _liveCueClearTimer = null;
          if (!mounted ||
              !_liveAiFallback ||
              generation != _liveCueGeneration) {
            return;
          }
          setState(() => _aiDisplaySubtitle = '');
        },
      );
    } catch (_) {
      // A failed/late cue is better omitted than flashed at the wrong time.
    }
  }

  Widget _aiSubtitleOverlay() {
    final baseBottom = _controlsVisible ? 110.0 : 12.0;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      left: 40,
      right: 40,
      bottom: baseBottom + _subtitleBottomOffset,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _subtitleBackground
                    ? Colors.black.withValues(
                        alpha: _subtitleBackgroundOpacity,
                      )
                    : Colors.transparent,
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
                padding: EdgeInsets.symmetric(
                  horizontal: _androidMobilePlayerMode ? 14 : 18,
                  vertical: _androidMobilePlayerMode ? 7 : 10,
                ),
                child: Text(
                  _aiDisplaySubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: _androidMobilePlayerMode && _subtitleFontSize > 26
                        ? 26
                        : _subtitleFontSize,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 8),
                    ],
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
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
    );
    final path = result?.path;
    if (path == null || path.isEmpty) {
      if (mounted) _scheduleHide();
      return;
    }
    final name = path.split(RegExp(r'[/\\]')).last;
    await _activateNativeSubtitle(
      mk.SubtitleTrack.uri(path, title: name),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded subtitle: $name')),
      );
      _scheduleHide();
    }
  }

  Future<void> _showOnlineSubtitles() async {
    final item = widget.item;
    if (item == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Online subtitles need movie or episode metadata.'),
          ),
        );
      }
      return;
    }

    _hideTimer?.cancel();
    var languageFilter = _preferredSubtitleLanguage;
    final future = OnlineSubtitleService.search(
      item: item,
      episode: widget.episode,
      releaseHint: widget.releaseHint,
      videoSize: widget.expectedSizeBytes,
      preferredLanguage: _preferredSubtitleLanguage,
    );

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D120E),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 860),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .78,
            child: FutureBuilder<List<OnlineSubtitleResult>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 14),
                        Text('Searching OpenSubtitles v3…'),
                      ],
                    ),
                  );
                }

                final results = snapshot.data ?? const <OnlineSubtitleResult>[];
                if (results.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'OpenSubtitles v3 did not return subtitles for this title/release.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                final languages = results
                    .map((entry) => entry.language)
                    .toSet()
                    .toList(growable: false)
                  ..sort((a, b) => OnlineSubtitleService.languageName(a)
                      .compareTo(OnlineSubtitleService.languageName(b)));
                if (languageFilter != 'all' &&
                    !languages.contains(languageFilter)) {
                  languageFilter = 'all';
                }
                final visible = languageFilter == 'all'
                    ? results
                    : results
                        .where((entry) => entry.language == languageFilter)
                        .toList(growable: false);

                return Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Online subtitles',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Official OpenSubtitles v3 • release-aware matching • choose any available language',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(Icons.language_rounded, size: 20),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 240,
                            child: DropdownButtonFormField<String>(
                              value: languageFilter,
                              decoration: const InputDecoration(
                                labelText: 'Language',
                                isDense: true,
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 'all',
                                  child: Text('All languages'),
                                ),
                                for (final language in languages)
                                  DropdownMenuItem(
                                    value: language,
                                    child: Text(
                                      OnlineSubtitleService.languageName(
                                        language,
                                      ),
                                    ),
                                  ),
                              ],
                              onChanged: (value) async {
                                if (value == null) return;
                                setSheetState(() => languageFilter = value);
                                if (value != 'all') {
                                  _preferredSubtitleLanguage = value;
                                  await SubtitlePreferencesService
                                      .setPreferredLanguage(value);
                                }
                              },
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${visible.length} result${visible.length == 1 ? '' : 's'}',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final subtitle = visible[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 5,
                              ),
                              leading: const Icon(Icons.closed_caption_rounded),
                              title: Text(
                                subtitle.languageLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              subtitle: Text(
                                '${subtitle.provider} • ${subtitle.label}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.play_arrow_rounded),
                              onTap: () async {
                                _preferredSubtitleLanguage = subtitle.language;
                                await SubtitlePreferencesService
                                    .setPreferredLanguage(
                                  subtitle.language,
                                );
                                await _activateNativeSubtitle(
                                  mk.SubtitleTrack.uri(
                                    subtitle.url,
                                    title:
                                        '${subtitle.languageLabel} • ${subtitle.provider}',
                                    language: subtitle.language,
                                  ),
                                );
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    if (mounted) _scheduleHide();
  }

  Widget _subtitleAppearanceControls(StateSetter setSheetState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B120D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF263827)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Subtitle appearance',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleFontSize(_subtitleFontSize - 2);
                  setSheetState(() {});
                },
                child: const Text('A−'),
              ),
              Chip(
                label: Text('${_subtitleFontSize.toStringAsFixed(0)} px'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleFontSize(_subtitleFontSize + 2);
                  setSheetState(() {});
                },
                child: const Text('A+'),
              ),
              FilterChip(
                selected: _subtitleBackground,
                label: const Text('Background'),
                onSelected: (value) async {
                  await _setSubtitleBackground(value);
                  setSheetState(() {});
                },
              ),
              OutlinedButton(
                onPressed: !_subtitleBackground
                    ? null
                    : () async {
                        await _setSubtitleBackgroundOpacity(
                          _subtitleBackgroundOpacity - .1,
                        );
                        setSheetState(() {});
                      },
                child: const Text('BG −'),
              ),
              Chip(
                label: Text(
                  'BG ${(_subtitleBackgroundOpacity * 100).round()}%',
                ),
              ),
              OutlinedButton(
                onPressed: !_subtitleBackground
                    ? null
                    : () async {
                        await _setSubtitleBackgroundOpacity(
                          _subtitleBackgroundOpacity + .1,
                        );
                        setSheetState(() {});
                      },
                child: const Text('BG +'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleBottomOffset(_subtitleBottomOffset - 10);
                  setSheetState(() {});
                },
                child: const Text('Lower'),
              ),
              Chip(
                label: Text('Position ${_subtitleBottomOffset.round()}'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleBottomOffset(_subtitleBottomOffset + 10);
                  setSheetState(() {});
                },
                child: const Text('Higher'),
              ),
              TextButton.icon(
                onPressed: () async {
                  await _resetSubtitleAppearance();
                  setSheetState(() {});
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset appearance'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _subtitleSyncControls(StateSetter setSheetState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B120D),
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
                  'Subtitle sync',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                '${_subtitleDelaySeconds > 0 ? '+' : ''}${_subtitleDelaySeconds.toStringAsFixed(2)}s',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Earlier/later works for embedded, local and OpenSubtitles tracks. The adjustment is only for this playback session.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA99E)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleDelay(_subtitleDelaySeconds - .5);
                  setSheetState(() {});
                },
                child: const Text('Earlier −0.5s'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleDelay(0);
                  setSheetState(() {});
                },
                child: const Text('Reset'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await _setSubtitleDelay(_subtitleDelaySeconds + .5);
                  setSheetState(() {});
                },
                child: const Text('Later +0.5s'),
              ),
            ],
          ),
        ],
      ),
    );
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
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
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
                    style:
                        Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Switch embedded tracks or load a local subtitle file.',
                    style: TextStyle(
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant),
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
                        title:
                            _trackLabel(track.title, track.language, track.id),
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
                          await _showOnlineSubtitles();
                        },
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('Online'),
                      ),
                      const SizedBox(width: 8),
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
                  _subtitleAppearanceControls(setSheetState),
                  const SizedBox(height: 12),
                  if (!_aiSinhalaEnabled) ...[
                    _subtitleSyncControls(setSheetState),
                    const SizedBox(height: 12),
                  ],
                  if (_preparedAiSubtitle != null)
                    _TrackTile(
                      title: 'AI Sinhala',
                      detail: _aiSinhalaEnabled
                          ? 'Active • translated Sinhala overlay'
                          : 'Available • switch back to AI Sinhala',
                      selected: _aiSinhalaRequested && _aiSinhalaEnabled,
                      onTap: () async {
                        await _enablePreparedAiSubtitle();
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                    )
                  else if (_liveAiFallback)
                    _TrackTile(
                      title: 'AI Sinhala',
                      detail:
                          'Active • translating the embedded English text track live',
                      selected: true,
                      onTap: () {},
                    ),
                  if (_aiSubtitleLoading)
                    const _EmptyTrackMessage(
                      'AI Sinhala is matching this exact release in the background. Playback is not blocked.',
                    )
                  else if (_aiSubtitleUnavailable)
                    const _EmptyTrackMessage(
                      'AI Sinhala could not confidently prepare subtitles for this release. Playback is unaffected.',
                    ),
                  if ((_aiSubtitleLoading || _aiSubtitleUnavailable) &&
                      _aiSinhalaEnabled == false)
                    const SizedBox(height: 12),
                  if (_aiSinhalaEnabled && _preparedAiSubtitle != null) ...[
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
                      await _disableSubtitles();
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
                  ...subtitleTracks.map(
                    (track) => _TrackTile(
                      title: _trackLabel(track.title, track.language, track.id),
                      detail: track.codec ?? 'Embedded subtitle',
                      selected: player.state.track.subtitle.id == track.id,
                      onTap: () async {
                        await _activateNativeSubtitle(track);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                    ),
                  ),
                ],
              ),
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
    _startupPlayingSubscription?.cancel();
    _startupPositionActivitySubscription?.cancel();
    _startupDurationSubscription?.cancel();
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _subtitleTimingSubscription?.cancel();
    _playbackErrorSubscription?.cancel();
    _persistProgress();
    _focusNode.dispose();
    widget.playback.stop();
    unawaited(_restoreAndroidMobilePlayerMode());
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
                      visible: !_aiSinhalaRequested,
                      style: TextStyle(
                        height: 1.35,
                        fontSize: _subtitleFontSize,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        backgroundColor: _subtitleBackground
                            ? Colors.black.withValues(
                                alpha: _subtitleBackgroundOpacity,
                              )
                            : Colors.transparent,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 7),
                        ],
                      ),
                      padding: EdgeInsets.fromLTRB(
                        20,
                        0,
                        20,
                        _controlsVisible && _subtitleBottomOffset < 110
                            ? 110
                            : _subtitleBottomOffset,
                      ),
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
    final compact = !_desktop && MediaQuery.sizeOf(context).shortestSide < 600;
    return Positioned(
      right: compact ? 14 : 28,
      left: compact ? 14 : null,
      bottom: compact ? 96 : 116,
      child: Container(
        width: compact ? null : 330,
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
    final compact = !_desktop && MediaQuery.sizeOf(context).shortestSide < 600;
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
                  if (!compact && _desktop) ...[
                    const _KeyboardHint('←/→ 10s'),
                    const SizedBox(width: 8),
                    const _KeyboardHint('Space Play/Pause'),
                    const SizedBox(width: 8),
                    const _KeyboardHint('F Fullscreen'),
                  ],
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 10 : 24,
                0,
                compact ? 10 : 24,
                compact ? 10 : 20,
              ),
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
                                    final target =
                                        Duration(milliseconds: value.round());
                                    await player.seek(target);
                                    _afterSeek(target);
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
                          if (compact)
                            _compactTransportRow(player, position, duration)
                          else
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
                              if (_androidMobilePlayerMode)
                                IconButton(
                                  tooltip: _mobilePortraitPlayer
                                      ? 'Rotate to landscape'
                                      : 'Rotate to portrait',
                                  onPressed: _toggleMobileOrientation,
                                  icon: const Icon(Icons.screen_rotation_rounded),
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

  Widget _compactTransportRow(
    mk.Player player,
    Duration position,
    Duration duration,
  ) {
    return Row(
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
              size: 26,
            ),
          ),
        ),
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
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '${_format(position)} / ${_format(duration)}',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Audio & subtitles',
          onPressed: _showTracks,
          icon: const Icon(Icons.subtitles_rounded),
        ),
        if (_androidMobilePlayerMode)
          IconButton(
            tooltip: _mobilePortraitPlayer
                ? 'Rotate to landscape'
                : 'Rotate to portrait',
            onPressed: _toggleMobileOrientation,
            icon: const Icon(Icons.screen_rotation_rounded),
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Text(
              '${player.state.rate.toStringAsFixed(player.state.rate == 1 ? 0 : 2)}×',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
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
