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
import '../services/ai_sinhala_runtime_state.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/media_state_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/playback_service.dart';
import '../services/platform_profile.dart';
import '../services/subtitle_preferences_service.dart';
import '../widgets/player_loading_overlay.dart';

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
    this.allowAiSinhala = true,
    this.releaseHint,
    this.expectedSizeBytes,
    this.expectedVideoHash,
    this.nextEpisodeLabel,
    this.onNext,
    this.onPlaybackStarted,
    this.onStartupFailed,
    this.onStartupFallback,
  });

  final PlaybackService playback;
  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final AiPreparedSubtitle? aiSubtitle;
  final bool allowAiSinhala;
  final String? releaseHint;
  final int? expectedSizeBytes;
  final String? expectedVideoHash;
  final String? nextEpisodeLabel;
  final Future<void> Function()? onNext;
  final VoidCallback? onPlaybackStarted;
  final ValueChanged<String>? onStartupFailed;
  final Future<void> Function(String message)? onStartupFallback;

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
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<String>>? _subtitleTimingSubscription;
  StreamSubscription<String>? _playbackErrorSubscription;
  bool _playbackStarted = false;
  bool _successReported = false;
  bool _failureReported = false;
  bool _startupFailureVisible = false;
  bool _preflightWarmup = false;
  bool _exitPrepared = false;
  Future<void>? _exitPreparation;
  bool _backNavigationInProgress = false;
  bool _closing = false;
  final FocusNode _focusNode = FocusNode();
  AiPreparedSubtitle? _preparedAiSubtitle;
  String? _generatedAiSubtitlePath;
  String? _generatedAiSubtitleLabel;
  AiSinhalaRuntimeState _aiState = const AiSinhalaRuntimeState.native();
  int _liveCueGeneration = 0;
  int _lastAiPrefetchBucket = -1;
  final List<String> _liveDialogueContext = <String>[];
  bool _aiSubtitleUnavailable = false;
  String _aiPreflightMessage = '';
  bool _timingTrackSelected = false;
  bool _timingTrackIsText = false;
  String _aiDisplaySubtitle = '';
  int _autoSyncOffsetMs = 0;
  int _manualSyncOffsetMs = 0;
  int? _lastNativeSubtitleStartMs;
  final List<int> _autoSyncSamples = <int>[];
  final Map<int, int> _bitmapOffsetVotes = <int, int>{};
  int _embeddedMismatchCount = 0;
  int _liveTranslationFailures = 0;
  int _preparedTranslationFailures = 0;
  int _nativeAiMatchIndex = -1;
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
  bool _tvControlFocused = false;

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get _localP2pStream {
    final uri = Uri.tryParse(widget.url);
    return uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port == 11470;
  }

  bool get _aiSinhalaRequested => _aiState.requested;
  bool get _aiSinhalaEnabled => _aiState.enabled;
  bool get _liveAiFallback => _aiState.liveEmbedded;
  bool get _aiSubtitleLoading => _aiState.loading;

  void _transitionAi(AiSinhalaRuntimeMode next) {
    _aiState = _aiState.transition(next);
  }

  @override
  void initState() {
    super.initState();
    _preparedAiSubtitle =
        widget.allowAiSinhala && !PlatformProfile.isAndroidTv
            ? widget.aiSubtitle
            : null;
    _aiState = _preparedAiSubtitle == null
        ? const AiSinhalaRuntimeState.native()
        : const AiSinhalaRuntimeState(AiSinhalaRuntimeMode.prepared);
    unawaited(_loadSubtitlePreferences());
    _playbackErrorSubscription =
        widget.playback.player.stream.error.listen(_onPlaybackError);
    _startupPlayingSubscription =
        widget.playback.player.stream.playing.listen((playing) {
      if (playing) _markPlaybackStarted();
    });
    _startupPositionActivitySubscription =
        widget.playback.player.stream.position.listen((position) {
      if (position > Duration.zero && widget.playback.player.state.playing) {
        _markPlaybackStarted();
      }
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
    return _playbackStarted || state.playing;
  }

  void _markPlaybackStarted() {
    if (_closing || _preflightWarmup) return;
    final firstStart = !_playbackStarted;
    _playbackStarted = true;
    _startupTimer?.cancel();

    if (firstStart && !_successReported) {
      _successReported = true;
      widget.onPlaybackStarted?.call();
    }

    if (mounted && _startupFailureVisible) {
      setState(() {
        _startupFailureVisible = false;
        _error = null;
      });
    }
  }

  bool _reportStartupFailure(String message) {
    if (_closing || _playbackStarted || _failureReported) return false;
    _failureReported = true;
    widget.onStartupFailed?.call(message);
    final fallback = widget.onStartupFallback;
    if (fallback != null) {
      unawaited(_runStartupFallback(message, fallback));
      return true;
    }
    return false;
  }

  Future<void> _runStartupFallback(
    String message,
    Future<void> Function(String message) fallback,
  ) async {
    await _preparePlayerExit();
    if (!mounted) return;
    Navigator.of(context).pop();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await fallback(message);
  }

  Future<void> _open() async {
    try {
      _playbackStarted = false;
      _startupFailureVisible = false;
      _startupTimer?.cancel();
      if (mounted && _error != null) {
        setState(() => _error = null);
      }

      final aiSettingEnabled =
          await AiSinhalaPreferencesService.isEnabled();
      // Windows local P2P remains stability-first, but it must not disable AI
      // Sinhala completely. Skip the old play/pause/seek preflight and start
      // playback normally; once the container exposes its native English text
      // track, use those real cue events as the subtitle clock.
      final deferAiForLocalP2p =
          Platform.isWindows && _localP2pStream && _preparedAiSubtitle == null;
      final aiPreferred = widget.allowAiSinhala &&
          !PlatformProfile.isAndroidTv &&
          (_preparedAiSubtitle != null || aiSettingEnabled);
      var aiReady = _preparedAiSubtitle != null;

      if (mounted && !_subtitleChoiceOverridden) {
        setState(() {
          _transitionAi(
            aiReady
                ? AiSinhalaRuntimeMode.prepared
                : aiPreferred
                    ? AiSinhalaRuntimeMode.preparing
                    : AiSinhalaRuntimeMode.native,
          );
          _aiSubtitleUnavailable = false;
          _aiPreflightMessage = aiPreferred && !aiReady
              ? deferAiForLocalP2p
                  ? 'Starting local P2P normally; AI Sinhala will follow the video’s own English cues.'
                  : 'Opening video paused to verify its real English subtitle track…'
              : '';
        });
      }

      // Alpha.20 opens the real media PAUSED first. The native English text
      // track visible in the track menu is the timing ground truth. Orvix
      // pre-translates a matching transcript, then every native cue event
      // selects the Sinhala line. Online subtitle timestamps are never used,
      // and no generated external subtitle track is loaded on this path.
      await widget.playback.open(
        widget.url,
        title: widget.title,
        // Local P2P must start normally. Its AI path only observes/selects
        // subtitle cues after startup and never runs the seek/pause sampler.
        play: deferAiForLocalP2p ? true : !aiPreferred,
      );

      if (aiPreferred && !aiReady) {
        aiReady = deferAiForLocalP2p
            ? await _tryPrepareEmbeddedAiTiming()
            : await _prepareAiSinhalaBeforePlayback();
      }

      if (aiReady && _generatedAiSubtitlePath != null) {
        await widget.playback.player.setSubtitleTrack(
          mk.SubtitleTrack.uri(
            _generatedAiSubtitlePath!,
            title:
                'AI Sinhala • ${_generatedAiSubtitleLabel ?? 'native-timed'}',
            language: 'si',
          ),
        );
        await _setNativeSubtitleDelayProperty(0);
        await _setNativeSubtitleVisibility(true);
        if (mounted) {
          setState(() {
            _transitionAi(AiSinhalaRuntimeMode.native);
            _aiSubtitleUnavailable = false;
            _aiDisplaySubtitle = '';
          });
        }
      } else if (aiReady && _preparedAiSubtitle != null) {
        // Native-cue mode: keep the video's synced English text track selected
        // and visible as a safety fallback while the small Sinhala buffer fills.
        // As soon as a translated cue is available, the cue handler hides the
        // English renderer and draws the Sinhala overlay for that cue.
        await _setNativeSubtitleDelayProperty(0);
        await _setNativeSubtitleVisibility(true);
        _timingTrackSelected = true;
        _timingTrackIsText = true;
        _nativeAiMatchIndex = -1;
        _positionSubscription ??=
            widget.playback.player.stream.position.listen(_onPosition);
        _subtitleTimingSubscription ??=
            widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
        _startNativeSubtitleClock();

        final position = widget.playback.player.state.position;
        final bucket = position.inSeconds ~/ 30;
        _lastAiPrefetchBucket = bucket;
        unawaited(_ensureAiTranslationNear(position, bucket: bucket));
      } else {
        final currentSubtitle = widget.playback.player.state.track.subtitle;
        await _setNativeSubtitleVisibility(
          // When AI Sinhala is off, keep libmpv subtitle rendering enabled even
          // if track metadata arrives a moment after open(). A later/default
          // embedded subtitle can then appear with its own authored styling.
          !_aiSinhalaRequested ||
              currentSubtitle.id.toLowerCase() != 'no',
        );
      }

      if (aiPreferred && !aiReady && mounted && !_closing) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiDisplaySubtitle = '';
          if (_aiPreflightMessage.trim().isEmpty) {
            _aiPreflightMessage =
                'AI Sinhala could not verify a native-timed subtitle. Normal playback will continue.';
          }
        });
        if (_aiPreflightMessage.trim().isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_aiPreflightMessage),
              duration: const Duration(seconds: 7),
            ),
          );
        }
      }

      Duration? resume;
      if (widget.item != null && widget.mediaState != null) {
        resume = await widget.mediaState!.resumePosition(
          widget.item!,
          episode: widget.episode,
        );
        if (resume != null && resume > const Duration(seconds: 10)) {
          await widget.playback.player.seek(resume);
          _afterSeek(resume);
        }
      }

      if (aiPreferred) {
        await widget.playback.player.play();
      }

      if (_hasPlaybackActivity()) {
        _markPlaybackStarted();
      } else {
        _startupTimer = Timer(const Duration(seconds: 30), () {
          if (!mounted || _closing) return;
          if (_hasPlaybackActivity()) {
            _markPlaybackStarted();
            return;
          }
          const message =
              'The stream is taking longer than expected to start. '
              'Orvix will recover automatically if media begins playing.';
          final switchingEngine = _reportStartupFailure(message);
          if (!switchingEngine && mounted) {
            setState(() {
              _startupFailureVisible = true;
              _error = message;
            });
          }
        });
      }

      final currentVolume = widget.playback.player.state.volume;
      if (currentVolume > 0) _lastVolume = currentVolume;
    } catch (e) {
      final message = e.toString();
      final switchingEngine = _reportStartupFailure(message);
      if (mounted && !switchingEngine) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _error = message;
        });
      }
    }
  }

  void _onPlaybackError(String message) {
    if (_closing ||
        _preflightWarmup ||
        !mounted ||
        message.trim().isEmpty ||
        _hasPlaybackActivity()) {
      return;
    }
    final detail = 'Playback engine: ${message.trim()}';
    final switchingEngine = _reportStartupFailure(detail);
    if (!switchingEngine && mounted) {
      setState(() {
        _startupFailureVisible = true;
        _error = detail;
      });
    }
  }

  bool _hasTextSubtitleTrack() {
    return widget.playback.player.state.tracks.subtitle.any(
      (track) => track.id.toLowerCase() != 'no' && !_isImageSubtitleTrack(track),
    );
  }

  Future<void> _primeSubtitleTracksForAiPreflight() async {
    if (_closing || _hasTextSubtitleTrack()) return;

    final player = widget.playback.player;
    final originalVolume = player.state.volume;
    final originalPosition = player.state.position;

    if (mounted) {
      setState(() {
        _aiPreflightMessage =
            'Warming the stream briefly to detect its real subtitle track…';
      });
    }

    _preflightWarmup = true;
    try {
      await player.setVolume(0);
      await player.play();

      for (var attempt = 0;
          attempt < 24 && mounted && !_closing && !_hasTextSubtitleTrack();
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      // Preflight will still try exact/release matching if track discovery fails.
    } finally {
      try {
        await player.pause();
      } catch (_) {}

      try {
        final current = player.state.position;
        if ((current - originalPosition).abs() >
            const Duration(milliseconds: 20)) {
          await player.seek(originalPosition);
        }
      } catch (_) {}

      try {
        await player.setVolume(originalVolume);
      } catch (_) {}
      _preflightWarmup = false;
      _playbackStarted = false;
      _startupFailureVisible = false;
    }
  }

  mk.SubtitleTrack? _bestNativeEnglishTextTrack() {
    final tracks = widget.playback.player.state.tracks.subtitle
        .where((track) => track.id.toLowerCase() != 'no')
        .where((track) => !_isImageSubtitleTrack(track))
        .toList(growable: false);

    final english = tracks.where(_isEnglishTrack).toList(growable: false);
    if (english.isEmpty) return null;

    int score(mk.SubtitleTrack track) {
      final language = (track.language ?? '').toLowerCase();
      final title = (track.title ?? '').toLowerCase();
      final codec = (track.codec ?? '').toLowerCase();
      var value = 0;
      if (language == 'eng' || language == 'en') value += 120;
      if (title == 'eng' || title.contains('english')) value += 110;
      if (codec.contains('subrip') ||
          codec.contains('srt') ||
          codec.contains('ass') ||
          codec.contains('ssa') ||
          codec.contains('webvtt')) {
        value += 30;
      }
      if (title.contains('forced') || title.contains('commentary')) value -= 100;
      return value;
    }

    english.sort((a, b) => score(b).compareTo(score(a)));
    return english.first;
  }

  Future<List<AiNativeCueSample>> _captureNativeEnglishSamples() async {
    final player = widget.playback.player;

    mk.SubtitleTrack? track;
    for (var attempt = 0; attempt < 30 && mounted && !_closing; attempt++) {
      track = _bestNativeEnglishTextTrack();
      if (track != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (track == null) return const <AiNativeCueSample>[];

    await player.setSubtitleTrack(track);
    await _setNativeSubtitleDelayProperty(0);
    await _setNativeSubtitleVisibility(false);

    final samples = <AiNativeCueSample>[];
    final seen = <String>{};
    final done = Completer<void>();
    Future<void> addSample(List<String> lines) async {
      if (_closing || done.isCompleted) return;
      final text = lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .join('\n')
          .trim();
      if (text.isEmpty) return;

      final normalized = text
          .toLowerCase()
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r"[^a-z0-9\s'’-]"), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (normalized.split(' ').where((word) => word.isNotEmpty).length < 3 ||
          !seen.add(normalized)) {
        return;
      }

      final startMs =
          await _nativeSubtitleStartMs() ?? player.state.position.inMilliseconds;
      final endMs = await _nativeSubtitleEndMs() ?? startMs + 2200;
      if (startMs < 0 || endMs <= startMs) return;

      samples.add(
        AiNativeCueSample(
          start: Duration(milliseconds: startMs),
          end: Duration(milliseconds: endMs),
          text: text,
        ),
      );
      if (mounted) {
        setState(() {
          _aiPreflightMessage =
              'Reading a few real English cues safely… ${samples.length}/5';
        });
      }
      if (samples.length >= 5 && !done.isCompleted) done.complete();
    }

    final subscription = player.stream.subtitle.listen(
      (lines) => unawaited(addSample(lines)),
    );
    final originalVolume = player.state.volume;
    final originalPosition = player.state.position;

    // This fallback deliberately runs at normal speed. Alpha.20 accelerated
    // network/P2P playback to 4x during preflight, which can aggressively
    // request pieces, then pause + seek immediately afterwards. Some free
    // sources become unstable or crash the native player after that sequence.
    _preflightWarmup = true;
    try {
      await player.setVolume(0);
      await player.play();
      await Future.any<void>([
        done.future,
        Future<void>.delayed(const Duration(seconds: 18)),
      ]);
    } catch (_) {
      // Safe fallback: normal playback will resume with native subtitles.
    } finally {
      try {
        await player.pause();
      } catch (_) {}
      await subscription.cancel();
      try {
        final current = player.state.position;
        if ((current - originalPosition).abs() >
            const Duration(milliseconds: 250)) {
          await player.seek(originalPosition);
        }
      } catch (_) {}
      try {
        await player.setVolume(originalVolume);
      } catch (_) {}
      _preflightWarmup = false;
      _playbackStarted = false;
      _startupFailureVisible = false;
    }

    return samples;
  }

  Future<bool> _prepareAiSinhalaBeforePlayback() async {
    if (_closing) return false;
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    if (!enabled || !mounted || _closing || _subtitleChoiceOverridden) {
      return false;
    }

    final item = widget.item;
    if (item == null) {
      if (mounted) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiPreflightMessage =
              'AI Sinhala needs movie or episode metadata.';
        });
      }
      return false;
    }

    setState(() {
      _transitionAi(AiSinhalaRuntimeMode.preparing);
      _aiSubtitleUnavailable = false;
      _aiPreflightMessage =
          'Finding the video’s synced English text subtitle track…';
    });

    try {
      // Ensure the same native English text track the user can select manually
      // is actually selected before AI preparation. Usually container metadata
      // already exposes it; if not, prime briefly at normal speed.
      await _primeSubtitleTracksForAiPreflight();
      final timingTrack = _bestNativeEnglishTextTrack();
      if (timingTrack == null) {
        throw const AiSubtitleException(
          'This source does not expose a readable native English text subtitle track.',
        );
      }
      await widget.playback.player.setSubtitleTrack(timingTrack);
      await _setNativeSubtitleDelayProperty(0);
      await _setNativeSubtitleVisibility(false);
      _timingTrackSelected = true;
      _timingTrackIsText = true;

      // First try sources that can identify the transcript without playing the
      // video at all: the embedded English file itself, then OpenSubtitles REST
      // matched by the actual selected file hash + byte size. These identify
      // TEXT only; runtime timing still comes from the native subtitle cues.
      final trusted = await AiSinhalaSubtitleService
          .prepareTrustedTranscriptForNativeClock(
        title: widget.title,
        videoUrl: widget.url,
        releaseHint: widget.releaseHint,
        expectedSizeBytes: widget.expectedSizeBytes,
        expectedVideoHash: widget.expectedVideoHash,
        preferredTrackLabel: _subtitleTrackPreferenceLabel(timingTrack),
        onStatus: (message) {
          if (!mounted || _closing) return;
          setState(() => _aiPreflightMessage = message);
        },
      );
      if (!mounted || _closing || _subtitleChoiceOverridden) return false;

      if (trusted != null) {
        _generatedAiSubtitlePath = null;
        _generatedAiSubtitleLabel = null;
        _preparedAiSubtitle = trusted;
        _nativeAiMatchIndex = -1;
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.prepared);
          _timingTrackSelected = true;
          _timingTrackIsText = true;
          _aiSubtitleUnavailable = false;
          _aiDisplaySubtitle = '';
          _aiPreflightMessage =
              'AI Sinhala ready • transcript verified without stressing playback; native English cues control timing.';
        });
        return true;
      }

      // Only if exact/embedded transcript discovery is unavailable do a short
      // NORMAL-SPEED native-cue sample and text-match generic candidates.
      final samples = await _captureNativeEnglishSamples();
      if (samples.length < 3) {
        throw const AiSubtitleException(
          'This source has an English track, but Orvix could not safely collect enough dialogue to identify its transcript.',
        );
      }
      if (!mounted || _closing || _subtitleChoiceOverridden) return false;

      setState(() {
        _aiPreflightMessage =
            'Exact-file lookup was unavailable. Matching native dialogue against fallback transcripts…';
      });
      final candidates = await OnlineSubtitleService.search(
        item: item,
        episode: widget.episode,
        releaseHint: widget.releaseHint,
        videoSize: widget.expectedSizeBytes,
        // Hash/size/filename are useful for choosing the transcript. They are
        // never used as the subtitle clock; native cue events remain final.
        videoHash: widget.expectedVideoHash,
        preferredLanguage: 'eng',
        includeTranscriptFallbacks: true,
      );

      final prepared = await AiSinhalaSubtitleService
          .prepareTranslatedTranscriptForNativeTiming(
        title: widget.title,
        videoIdentity: widget.url,
        nativeSamples: samples,
        candidates: candidates,
        onStatus: (message) {
          if (!mounted || _closing) return;
          setState(() => _aiPreflightMessage = message);
        },
      );
      if (!mounted || _closing || _subtitleChoiceOverridden) return false;

      _generatedAiSubtitlePath = null;
      _generatedAiSubtitleLabel = null;
      _preparedAiSubtitle = prepared;
      _nativeAiMatchIndex = -1;
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.prepared);
        _timingTrackSelected = true;
        _timingTrackIsText = true;
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage =
            'AI Sinhala ready • timing locked to this video’s native English track.';
      });
      return true;
    } catch (error) {
      _generatedAiSubtitlePath = null;
      _generatedAiSubtitleLabel = null;
      _preparedAiSubtitle = null;
      _nativeAiMatchIndex = -1;
      if (!mounted || _closing || _subtitleChoiceOverridden) return false;
      final reason = error.toString().trim();
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.native);
        _timingTrackSelected = false;
        _timingTrackIsText = false;
        _aiSubtitleUnavailable = true;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = reason.isEmpty
            ? 'Native-timed AI Sinhala could not be prepared.'
            : '$reason Normal playback will continue with the video’s own subtitles.';
      });
      return false;
    }
  }

  Future<void> _restoreNativeSubtitleFallback() async {
    _nativeSubtitleClockTimer?.cancel();
    _timingTrackSelected = false;
    _timingTrackIsText = false;
    _liveCueGeneration++;
    if (mounted && _aiState.mode != AiSinhalaRuntimeMode.native) {
      setState(() => _transitionAi(AiSinhalaRuntimeMode.native));
    }
    // AI mode hides libmpv while Orvix draws Sinhala. On fallback we switch
    // back to the native subtitle renderer so the source track's authored
    // styling is preserved. Hide first only to avoid an overlap during the
    // state transition, then restore the selected native track below.
    await _setNativeSubtitleVisibility(false);

    final player = widget.playback.player;
    final current = player.state.track.subtitle;
    if (current.id.toLowerCase() != 'no' &&
        (_isEnglishTrack(current) || _isUnlabeledTextTrack(current))) {
      await _setNativeSubtitleVisibility(true);
      await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
      return;
    }

    // Prefer an English track for the safe fallback. Keep retrying briefly
    // because network/P2P containers can publish track metadata asynchronously.
    for (var attempt = 0; attempt < 12 && mounted && !_closing; attempt++) {
      final tracks = player.state.tracks.subtitle
          .where((track) => track.id.toLowerCase() != 'no')
          .toList(growable: false);
      final englishText =
          tracks.where(_isEnglishTextTrack).toList(growable: false);
      final englishAny = tracks.where(_isEnglishTrack).toList(growable: false);
      final unknownText =
          tracks.where(_isUnlabeledTextTrack).toList(growable: false);
      final chosen = englishText.isNotEmpty
          ? englishText.first
          : englishAny.isNotEmpty
              ? englishAny.first
              : unknownText.length == 1
                  ? unknownText.first
                  : null;
      if (chosen != null) {
        await player.setSubtitleTrack(chosen);
        await _setNativeSubtitleVisibility(true);
        await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    // No English-labelled track was discoverable. Preserve the player's
    // current native choice as a last-resort fallback instead of leaving
    // subtitles blank.
    if (current.id.toLowerCase() != 'no') {
      await _setNativeSubtitleVisibility(true);
      await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
    }
  }

  Future<bool> _enableEmbeddedLiveAiFallback(String reason) async {
    if (!mounted || _closing || _subtitleChoiceOverridden) return false;

    _liveTranslationFailures = 0;
    setState(() {
      _preparedAiSubtitle = null;
      _transitionAi(AiSinhalaRuntimeMode.liveEmbedded);
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage =
          'Using the video’s own English cues for live Sinhala translation. $reason';
    });

    _subtitleTimingSubscription ??=
        widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
    await _setNativeSubtitleDelayProperty(0);
    await _setNativeSubtitleVisibility(true);
    _startNativeSubtitleClock();
    return true;
  }

  Future<bool> _tryPrepareEmbeddedAiTiming() async {
    if (!_aiSinhalaRequested ||
        _subtitleChoiceOverridden ||
        _closing ||
        !mounted ||
        widget.item == null) {
      return false;
    }

    final player = widget.playback.player;
    for (var attempt = 0; attempt < 12 && mounted; attempt++) {
      final current = player.state.track.subtitle;
      dynamic chosen;
      if (current.id.toLowerCase() != 'no' &&
          (_isEnglishTextTrack(current) ||
              _isUnlabeledTextTrack(current))) {
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
          final unknownText =
              allTracks.where(_isUnlabeledTextTrack).toList(growable: false);
          if (unknownText.length == 1) {
            chosen = unknownText.first;
            await player.setSubtitleTrack(chosen);
          }
        }
      }

      if (chosen != null) {
        _timingTrackSelected = true;
        _timingTrackIsText = true;
        _liveCueGeneration++;
        _liveDialogueContext.clear();
        await _hideNativeTimingSubtitle();

        try {
          if (mounted) {
            setState(() {
              _transitionAi(AiSinhalaRuntimeMode.preparing);
              _aiSubtitleUnavailable = false;
              _aiDisplaySubtitle = '';
            });
          }
          // Sync-first V2 rule: never use a title/episode-only downloaded
          // subtitle as the timing source. The selected video's native English
          // text track remains the clock. We may use an embedded transcript or
          // an exact file-hash OpenSubtitles match only as the TEXT oracle.
          final prepared =
              await AiSinhalaSubtitleService.prepareTrustedTranscriptForNativeClock(
            title: widget.title,
            videoUrl: widget.url,
            releaseHint: widget.releaseHint,
            expectedSizeBytes: widget.expectedSizeBytes,
            expectedVideoHash: widget.expectedVideoHash,
            preferredTrackLabel: _subtitleTrackPreferenceLabel(chosen),
            onStatus: (message) {
              if (!mounted || _closing) return;
              setState(() => _aiPreflightMessage = message);
            },
          );
          if (!mounted || _closing || _subtitleChoiceOverridden) {
            return false;
          }
          if (prepared == null) {
            return _enableEmbeddedLiveAiFallback(
              'No embedded or exact-file transcript could be verified. '
              'Using the video’s own English cues keeps Sinhala locked to native timing.',
            );
          }

          setState(() {
            _preparedAiSubtitle = prepared;
            _transitionAi(AiSinhalaRuntimeMode.prepared);
            _preparedTranslationFailures = 0;
            _aiSubtitleUnavailable = false;
            _aiPreflightMessage =
                'AI Sinhala V2 ready • native English cues control timing.';
            _lastAiPrefetchBucket = -1;
          });
          _positionSubscription ??=
              player.stream.position.listen(_onPosition);
          _subtitleTimingSubscription ??=
              player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
          await _setNativeSubtitleDelayProperty(0);
          await _setNativeSubtitleVisibility(true);
          _startNativeSubtitleClock();

          final position = player.state.position;
          final bucket = position.inSeconds ~/ 30;
          _lastAiPrefetchBucket = bucket;
          unawaited(_ensureAiTranslationNear(position, bucket: bucket));
          return true;
        } catch (_) {
          return _enableEmbeddedLiveAiFallback(
            'The prebuffered transcript path failed.',
          );
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled) async {
    await AiSinhalaPreferencesService.setEnabled(enabled);
    if (!mounted || _closing) return;

    if (!enabled) {
      _subtitleChoiceOverridden = false;
      _nativeSubtitleClockTimer?.cancel();
      _liveCueClearTimer?.cancel();
      _nativeAiMatchIndex = -1;
      _lastAiPrefetchBucket = -1;
      _liveCueGeneration++;
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiDisplaySubtitle = '';
        _aiSubtitleUnavailable = false;
        _aiPreflightMessage = '';
      });
      await _restoreNativeSubtitleFallback();
      return;
    }

    _subtitleChoiceOverridden = false;

    if (_preparedAiSubtitle != null) {
      await _enablePreparedAiSubtitle();
      return;
    }

    if (_aiState.mode == AiSinhalaRuntimeMode.native) {
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.preparing);
        _aiSubtitleUnavailable = false;
        _aiPreflightMessage =
            'Preparing AI Sinhala from the selected video subtitle track…';
      });
    }

    final player = widget.playback.player;
    final resumePlaybackAfterToggle = player.state.playing;
    var ready = false;
    try {
      ready = Platform.isWindows && _localP2pStream
          ? await _tryPrepareEmbeddedAiTiming()
          : await _prepareAiSinhalaBeforePlayback();

      if (ready && _preparedAiSubtitle != null && mounted && !_closing) {
        _positionSubscription ??=
            player.stream.position.listen(_onPosition);
        _subtitleTimingSubscription ??=
            player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
        await _ensureEnglishTimingTrack();

        if (_timingTrackSelected && _timingTrackIsText) {
          await _setNativeSubtitleVisibility(true);
          final position = player.state.position;
          final bucket = position.inSeconds ~/ 30;
          _lastAiPrefetchBucket = bucket;
          unawaited(_ensureAiTranslationNear(position, bucket: bucket));
          unawaited(_refreshNativeCueAfterSeek());
        }
      }

      if (!ready && mounted && !_closing) {
        await AiSinhalaPreferencesService.setEnabled(false);
        setState(() {
          if (_aiState.mode != AiSinhalaRuntimeMode.native) {
            _transitionAi(AiSinhalaRuntimeMode.native);
          }
          _aiSubtitleUnavailable = true;
          if (_aiPreflightMessage.trim().isEmpty) {
            _aiPreflightMessage =
                'AI Sinhala could not prepare a reliable subtitle path for this source.';
          }
        });
        await _restoreNativeSubtitleFallback();
      }
    } finally {
      if (resumePlaybackAfterToggle && !_closing && !player.state.playing) {
        try {
          await player.play();
        } catch (_) {}
      }
    }
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
      if (visible && !_aiSinhalaRequested) {
        // Preserve authored ASS/SSA styling when AI Sinhala is off.
        await platform.setProperty(
          'sub-ass-override',
          'no',
          waitForInitialization: false,
        );
      }
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
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiDisplaySubtitle = '';
      });
    }
    await widget.playback.player.setSubtitleTrack(track);
    await _setNativeSubtitleVisibility(true);
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
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiDisplaySubtitle = '';
      });
    }
    await _setNativeSubtitleVisibility(false);
    await widget.playback.player.setSubtitleTrack(mk.SubtitleTrack.no());
  }

  Future<void> _enablePreparedAiSubtitle() async {
    final prepared = _preparedAiSubtitle;
    if (prepared == null) return;
    _subtitleChoiceOverridden = true;
    await _setNativeSubtitleDelayProperty(0);
    if (!mounted) return;
    setState(() {
      _transitionAi(AiSinhalaRuntimeMode.prepared);
      _lastAiPrefetchBucket = -1;
      _aiDisplaySubtitle = '';
    });
    _positionSubscription ??=
        widget.playback.player.stream.position.listen(_onPosition);
    _subtitleTimingSubscription ??=
        widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);

    await _ensureEnglishTimingTrack();
    await _loadManualSync();
    if (!mounted) return;

    if (_timingTrackSelected && _timingTrackIsText) {
      await _setNativeSubtitleVisibility(true);
      final position = widget.playback.player.state.position;
      final bucket = position.inSeconds ~/ 30;
      _lastAiPrefetchBucket = bucket;
      unawaited(_ensureAiTranslationNear(position, bucket: bucket));
      unawaited(_refreshNativeCueAfterSeek());
    } else {
      // Last-resort legacy path when no readable native text timing track is
      // exposed. Position lookup remains available, but never hide a selected
      // source subtitle merely because AI was requested.
      _refreshAiSubtitle();
    }
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
      if (mounted &&
          !_seeking &&
          !_tvControlFocused &&
          _nextCountdown == 0) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _handleTvControlFocus(bool focused) {
    _tvControlFocused = focused;
    if (focused) {
      _hideTimer?.cancel();
      if (!_controlsVisible && mounted) {
        setState(() => _controlsVisible = true);
      }
    } else {
      _scheduleHide();
    }
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

  Future<void> _refreshNativeCueAfterSeek() async {
    if (!_aiSinhalaEnabled ||
        !_timingTrackSelected ||
        !_timingTrackIsText ||
        _closing) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || _closing) return;
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      final text = (await platform.getProperty(
        'sub-text',
        waitForInitialization: false,
      ))
          .trim();
      await _handleEmbeddedSubtitleCue(text.isEmpty ? const [] : [text]);
    } catch (_) {}
  }

  void _afterSeek(Duration target) {
    if (!_aiSinhalaRequested) return;
    _lastNativeSubtitleStartMs = null;
    _lastAiPrefetchBucket = -1;
    _nativeAiMatchIndex = -1;
    _liveCueGeneration++;
    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;
    unawaited(_setNativeSubtitleVisibility(false));

    if (mounted && _aiDisplaySubtitle.isNotEmpty) {
      setState(() => _aiDisplaySubtitle = '');
    }

    if (_aiSinhalaEnabled &&
        _timingTrackSelected &&
        _timingTrackIsText &&
        _preparedAiSubtitle != null) {
      unawaited(_refreshNativeCueAfterSeek());
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
    if (!Platform.isAndroid || !mounted || PlatformProfile.isAndroidTv) return;
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

  Future<void> _preparePlayerExit() async {
    if (_exitPrepared) return;

    final existing = _exitPreparation;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _preparePlayerExitInternal();
    _exitPreparation = future;
    try {
      await future;
    } finally {
      if (!_exitPrepared) _exitPreparation = null;
    }
  }

  Future<void> _preparePlayerExitInternal() async {
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _nextTimer?.cancel();
    _startupTimer?.cancel();
    _nativeSubtitleClockTimer?.cancel();
    _liveCueClearTimer?.cancel();
    _liveCueGeneration++;

    // Stop async player callbacks before tearing down libmpv. This prevents
    // completed/error/subtitle events from mutating UI or launching "next"
    // while the route is already closing.
    try {
      await _startupPlayingSubscription?.cancel();
      await _startupPositionActivitySubscription?.cancel();
      await _completedSubscription?.cancel();
      await _positionSubscription?.cancel();
      await _subtitleTimingSubscription?.cancel();
      await _playbackErrorSubscription?.cancel();
    } catch (_) {}

    try {
      await _persistProgress();
    } catch (_) {}

    // Windows local P2P has a native MPV surface reading from a localhost
    // torrent endpoint. Pause first, then stop, and give libmpv one short
    // settle window before Flutter disposes the Video surface during route pop.
    // This avoids a stop/surface-destroy race on Back.
    try {
      await widget.playback.player.pause();
    } catch (_) {}
    try {
      await widget.playback.stop();
    } catch (_) {}
    if (Platform.isWindows && _localP2pStream) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    _exitPrepared = true;
  }

  Future<void> _handleEscape() async {
    // A Windows key/button event can be delivered more than once while the
    // native player teardown is still completing. Guard the route transition
    // itself (not only the teardown future) so one user Back action can pop
    // exactly one route.
    if (_backNavigationInProgress || _closing) return;
    if (_desktop && await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      return;
    }
    _backNavigationInProgress = true;
    await _preparePlayerExit();
    if (mounted) Navigator.of(context).pop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Once a real TV control has focus, let Flutter's normal focus traversal
    // and ActivateIntent handle DPAD/OK. The root player shortcut layer should
    // only own keys while the video surface itself has focus.
    if (PlatformProfile.isAndroidTv && !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        (PlatformProfile.isAndroidTv &&
            (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter))) {
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
    if (PlatformProfile.isAndroidTv &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _showControls();
      return KeyEventResult.ignored;
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
    if (_closing ||
        widget.onNext == null ||
        _advancing ||
        _nextCountdown > 0) {
      return;
    }
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
    await _preparePlayerExit();
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
        !mounted) {
      return;
    }

    // Native text cues remain the timing authority. Position is used only to
    // maintain a small translation buffer ahead of playback.
    if (_timingTrackSelected && _timingTrackIsText) {
      final bucket = position.inSeconds ~/ 30;
      if (bucket != _lastAiPrefetchBucket) {
        _lastAiPrefetchBucket = bucket;
        unawaited(_ensureAiTranslationNear(position, bucket: bucket));
      }
      return;
    }

    var adjustedMs = position.inMilliseconds - _effectiveSyncOffsetMs;
    if (adjustedMs < 0) adjustedMs = 0;
    final adjusted = Duration(milliseconds: adjustedMs);
    final next = prepared.subtitleAt(adjusted);
    if (next != _aiDisplaySubtitle) {
      setState(() => _aiDisplaySubtitle = next);
    }

    final bucket = adjusted.inSeconds ~/ 30;
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
        lookBehind: 3,
        lookAhead: 24,
      );
      if (!mounted ||
          !_aiSinhalaEnabled ||
          _liveAiFallback ||
          _preparedAiSubtitle?.key != prepared.key) {
        return;
      }
      if (_timingTrackSelected && _timingTrackIsText) {
        // The buffer may finish while the same English cue is still on screen.
        // Re-read that native cue so it can switch to Sinhala immediately
        // instead of waiting for the next line of dialogue.
        unawaited(_refreshNativeCueAfterSeek());
      } else {
        _refreshAiSubtitle();
      }
    } catch (_) {
      if (mounted &&
          (bucket == null || bucket == _lastAiPrefetchBucket)) {
        _lastAiPrefetchBucket = -1;
      }
    }
  }

  Future<void> _ensureEnglishTimingTrack() async {
    if (!_aiSinhalaEnabled || _closing) return;
    final player = widget.playback.player;
    for (var attempt = 0; attempt < 12 && mounted && !_closing; attempt++) {
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
          final unknownText =
              allTracks.where(_isUnlabeledTextTrack).toList(growable: false);
          if (unknownText.length == 1) {
            chosen = unknownText.first;
            await player.setSubtitleTrack(chosen);
          }
        }
      }

      if (chosen != null) {
        _timingTrackSelected = true;
        _timingTrackIsText = !_isImageSubtitleTrack(chosen);
        await _setNativeSubtitleDelayProperty(0);
        await _setNativeSubtitleVisibility(true);
        _startNativeSubtitleClock();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  String _subtitleTrackPreferenceLabel(dynamic track) {
    final title = (track.title ?? '').toString().trim();
    final language = (track.language ?? '').toString().trim();
    final codec = (track.codec ?? '').toString().trim();
    return <String>[title, language, codec]
        .where((value) => value.isNotEmpty)
        .join(' • ');
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

  bool _isUnlabeledTextTrack(dynamic track) {
    if (_isImageSubtitleTrack(track)) return false;
    final language = (track.language ?? '').toString().trim();
    final title = (track.title ?? '').toString().trim();
    return language.isEmpty && title.isEmpty;
  }

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
    if (!_aiSinhalaRequested ||
        !_timingTrackSelected ||
        !_timingTrackIsText ||
        !mounted) {
      return;
    }

    final source = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();

    if (source.isEmpty) {
      _liveCueGeneration++;
      if (_aiDisplaySubtitle.isNotEmpty && mounted) {
        setState(() => _aiDisplaySubtitle = '');
      }
      return;
    }

    if (_liveAiFallback) {
      await _translateLiveSubtitleCue(source);
      return;
    }

    final prepared = _preparedAiSubtitle;
    if (prepared == null) return;

    final match = prepared.matchSourceCueRange(
      source,
      previousIndex: _nativeAiMatchIndex,
    );
    if (match == null) {
      // Never leave the viewer with blank subtitles while Sinhala is not
      // available. The native source subtitle remains visible as the fallback.
      unawaited(_setNativeSubtitleVisibility(true));
      if (_aiDisplaySubtitle.isNotEmpty && mounted) {
        setState(() => _aiDisplaySubtitle = '');
      }
      return;
    }

    _nativeAiMatchIndex = match.index + match.count - 1;
    final matchedCues =
        prepared.cues.sublist(match.index, match.index + match.count);
    final translated = matchedCues
        .map((cue) => cue.translation?.trim() ?? '')
        .where((line) => line.isNotEmpty)
        .join('\n');

    if (translated.isEmpty) {
      // Buffer around the transcript cue we just matched. English remains
      // visible until that Sinhala buffer is ready, instead of disappearing.
      unawaited(_setNativeSubtitleVisibility(true));
      if (_aiDisplaySubtitle.isNotEmpty && mounted) {
        setState(() => _aiDisplaySubtitle = '');
      }
      final cuePosition = matchedCues.first.start;
      final bucket = cuePosition.inSeconds ~/ 30;
      _lastAiPrefetchBucket = bucket;
      unawaited(_ensureAiTranslationNear(cuePosition, bucket: bucket));
      return;
    }

    _liveCueGeneration++;
    unawaited(_setNativeSubtitleVisibility(false));
    if (translated != _aiDisplaySubtitle && mounted) {
      setState(() => _aiDisplaySubtitle = translated);
    }
  }

  Future<void> _registerLiveTranslationFailure(String reason) async {
    _liveTranslationFailures++;
    if (_liveTranslationFailures < 3 ||
        !mounted ||
        !_liveAiFallback ||
        _closing) {
      return;
    }

    setState(() {
      _aiPreflightMessage =
          'AI Sinhala could not keep up ($reason) — using English subtitles.';
      _aiSubtitleUnavailable = true;
      _transitionAi(AiSinhalaRuntimeMode.native);
      _aiDisplaySubtitle = '';
    });
    await _restoreNativeSubtitleFallback();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_aiPreflightMessage),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _translateLiveSubtitleCue(String source) async {
    final generation = ++_liveCueGeneration;
    final requestStartedAt = DateTime.now();
    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;

    // Live translation is best-effort. Keep the video's own English subtitle
    // visible while the network request is in flight so AI failure/latency can
    // never produce a blank subtitle screen.
    await _setNativeSubtitleVisibility(true);

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
      final elapsedMs =
          DateTime.now().difference(requestStartedAt).inMilliseconds;
      final remainingMs = cueEndMs == null
          ? 2200 - elapsedMs
          : cueEndMs - nowMs;

      // A translation that repeatedly arrives after the cue is no longer a
      // functioning subtitle path. Count it as a delivery failure and recover
      // to English instead of leaving the user with a permanently blank overlay.
      if (remainingMs < 700) {
        await _registerLiveTranslationFailure('translation arrived too late');
        return;
      }

      _liveTranslationFailures = 0;
      await _setNativeSubtitleVisibility(false);
      if (!mounted || generation != _liveCueGeneration) return;
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
      await _registerLiveTranslationFailure('translation service failed');
    }
  }

  double _effectiveSubtitleFontSize(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final base = _subtitleFontSize;

    // Scale from a 720p logical-height reference so subtitles stay readable on
    // desktop/TV without making Android phones oversized. The user preference
    // still acts as the baseline; the viewport supplies the final scale.
    final heightScale = (size.height / 720.0).clamp(0.72, 1.75);

    if (_androidMobilePlayerMode) {
      return (base * heightScale).clamp(18.0, 28.0).toDouble();
    }

    if (_desktop) {
      return (base * heightScale * 1.08).clamp(24.0, 44.0).toDouble();
    }

    // Android TV / large-screen Android.
    return (base * heightScale * 1.10).clamp(22.0, 44.0).toDouble();
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
                    fontSize: _effectiveSubtitleFontSize(context),
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

  Future<void> _activateAiSinhalaFromOnlineSubtitle(
    OnlineSubtitleResult subtitle,
  ) async {
    if (_closing || !mounted) return;
    _subtitleChoiceOverridden = true;
    final wasPlaying = widget.playback.player.state.playing;

    try {
      await widget.playback.player.pause();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.preparing);
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage =
            'Downloading ${subtitle.label} for Sinhala translation…';
      });
    }

    try {
      final generated =
          await AiSinhalaSubtitleService.prepareGeneratedSinhalaFromOnlineSubtitle(
        title: widget.title,
        subtitleUrl: subtitle.url,
        subtitleIdentity: subtitle.id,
        subtitleLabel: subtitle.label,
        onStatus: (message) {
          if (!mounted || _closing) return;
          setState(() => _aiPreflightMessage = message);
        },
      );

      if (!mounted || _closing) return;
      await widget.playback.player.setSubtitleTrack(
        mk.SubtitleTrack.uri(
          generated.path,
          title: 'AI Sinhala • ${subtitle.label}',
          language: 'si',
        ),
      );
      await _setNativeSubtitleDelayProperty(0);
      await _setNativeSubtitleVisibility(true);

      if (!mounted) return;
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = generated.cacheHit
            ? 'Cached Sinhala subtitle loaded • ${subtitle.label}'
            : 'Sinhala subtitle generated • ${subtitle.label}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_aiPreflightMessage),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (error) {
      if (mounted && !_closing) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiDisplaySubtitle = '';
          _aiPreflightMessage =
              'Could not translate this subtitle: ${error.toString()}';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_aiPreflightMessage),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (wasPlaying && !_closing) {
        try {
          await widget.playback.player.play();
        } catch (_) {}
      }
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
      videoHash: widget.expectedVideoHash,
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
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (OnlineSubtitleService.normalizeLanguage(
                                        subtitle.language,
                                      ) ==
                                      'eng')
                                    Tooltip(
                                      message:
                                          'Translate this subtitle to Sinhala',
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.translate_rounded,
                                        ),
                                        onPressed: () async {
                                          if (sheetContext.mounted) {
                                            Navigator.pop(sheetContext);
                                          }
                                          await _activateAiSinhalaFromOnlineSubtitle(
                                            subtitle,
                                          );
                                        },
                                      ),
                                    ),
                                  const Icon(Icons.play_arrow_rounded),
                                ],
                              ),
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
                  if (widget.allowAiSinhala && !PlatformProfile.isAndroidTv) ...[
                    _AiSinhalaSwitchTile(
                      value: _aiSinhalaRequested,
                      busy: _aiSubtitleLoading,
                      detail: _aiSubtitleLoading
                          ? 'Preparing a verified native-timed Sinhala subtitle…'
                          : _aiSinhalaEnabled
                              ? 'On • Sinhala uses the selected video’s English cue timing'
                              : _aiSubtitleUnavailable
                                  ? (_aiPreflightMessage.trim().isEmpty
                                      ? 'Off • last attempt could not prepare this source'
                                      : 'Off • ${_aiPreflightMessage.trim()}')
                                  : 'Off • turn on AI Sinhala for this playback and future videos',
                      onChanged: (value) async {
                        await _setAiSinhalaEnabledFromPlayer(value);
                        if (sheetContext.mounted) {
                          setSheetState(() {});
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_aiSinhalaEnabled) ...[
                    _subtitleAppearanceControls(setSheetState),
                    const SizedBox(height: 12),
                  ] else ...[
                    const _EmptyTrackMessage(
                      'Source subtitle appearance is preserved by the native player. '
                      'Orvix font/background/position styling is only used for AI Sinhala.',
                    ),
                    const SizedBox(height: 12),
                    _subtitleSyncControls(setSheetState),
                    const SizedBox(height: 12),
                  ],
                  if (_aiSubtitleLoading)
                    const _EmptyTrackMessage(
                      'AI Sinhala is preparing a verified subtitle timeline.',
                    )
                  else if (_aiSubtitleUnavailable)
                    _EmptyTrackMessage(
                      _aiPreflightMessage.trim().isEmpty
                          ? 'AI Sinhala could not confidently prepare subtitles for this release. Playback is unaffected.'
                          : _aiPreflightMessage,
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
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _nextTimer?.cancel();
    _startupTimer?.cancel();
    _nativeSubtitleClockTimer?.cancel();
    _liveCueClearTimer?.cancel();
    _liveCueGeneration++;
    unawaited(_startupPlayingSubscription?.cancel() ?? Future<void>.value());
    unawaited(
      _startupPositionActivitySubscription?.cancel() ?? Future<void>.value(),
    );
    unawaited(_completedSubscription?.cancel() ?? Future<void>.value());
    unawaited(_positionSubscription?.cancel() ?? Future<void>.value());
    unawaited(_subtitleTimingSubscription?.cancel() ?? Future<void>.value());
    unawaited(_playbackErrorSubscription?.cancel() ?? Future<void>.value());
    if (!_exitPrepared) {
      unawaited(
        _persistProgress()
            .catchError((_) {})
            .whenComplete(() => widget.playback.stop().catchError((_) {})),
      );
    }
    _focusNode.dispose();
    unawaited(_restoreAndroidMobilePlayerMode().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.playback.player;
    return WillPopScope(
      onWillPop: () async {
        if (_backNavigationInProgress || _closing) return false;
        _backNavigationInProgress = true;
        await _preparePlayerExit();
        return true;
      },
      child: Scaffold(
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
                      // NativePlayer/libmpv renders source subtitles itself so
                      // ASS/SSA/bitmap styling is preserved. Flutter styling is
                      // only a fallback for non-native player platforms.
                      visible: !_aiSinhalaRequested &&
                          widget.playback.player.platform is! mk.NativePlayer,
                      style: TextStyle(
                        height: 1.35,
                        fontSize: _effectiveSubtitleFontSize(context),
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
                if (_error == null && !_aiSubtitleLoading)
                  StreamBuilder<bool>(
                    stream: player.stream.buffering,
                    initialData: player.state.buffering,
                    builder: (context, snapshot) {
                      if (snapshot.data != true) {
                        return const SizedBox.shrink();
                      }
                      if (!_playbackStarted) {
                        return PlayerLoadingOverlay(
                          item: widget.item,
                          title: widget.title,
                          message: 'Starting playback…',
                          detail: widget.episode == null ? null : widget.title,
                        );
                      }
                      return Center(
                        child: CircularProgressIndicator(
                          color: PlatformProfile.isAndroidTv
                              ? Colors.white
                              : null,
                        ),
                      );
                    },
                  ),
                if (_error == null &&
                    _aiSubtitleLoading &&
                    !_playbackStarted)
                  PlayerLoadingOverlay(
                    item: widget.item,
                    title: widget.title,
                    message: 'Preparing AI Sinhala before playback',
                    detail: _aiPreflightMessage.trim().isEmpty
                        ? 'Checking the safest subtitle timing source…'
                        : _aiPreflightMessage,
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
    if (PlatformProfile.isAndroidTv) {
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
                  size: 52,
                  color: Colors.white,
                ),
                const SizedBox(height: 18),
                const Text(
                  'Could not start playback',
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
                _TvPlayerAction(
                  icon: Icons.arrow_back_rounded,
                  label: 'Back to sources',
                  onPressed: _handleEscape,
                  onFocusChange: _handleTvControlFocus,
                ),
              ],
            ),
          ),
        ),
      );
    }

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
              onPressed: _handleEscape,
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tvControls(BuildContext context) {
    final player = widget.playback.player;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xB8000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0xE8000000),
          ],
          stops: [0, .24, .58, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
              child: Row(
                children: [
                  _TvPlayerAction(
                    icon: Icons.arrow_back_rounded,
                    semanticLabel: 'Back',
                    onPressed: _handleEscape,
                    onFocusChange: _handleTvControlFocus,
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
                      return StreamBuilder<Duration>(
                        stream: player.stream.buffer,
                        initialData: player.state.buffer,
                        builder: (context, bufferSnapshot) {
                          final buffered = bufferSnapshot.data ?? Duration.zero;
                          final durationMs =
                              duration.inMilliseconds.clamp(1, 1 << 31);
                          final playedFraction =
                              (position.inMilliseconds / durationMs)
                                  .clamp(0.0, 1.0)
                                  .toDouble();
                          final bufferedFraction =
                              (buffered.inMilliseconds / durationMs)
                                  .clamp(playedFraction, 1.0)
                                  .toDouble();

                          return Column(
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
                                    child: _TvProgressBar(
                                      played: playedFraction,
                                      buffered: bufferedFraction,
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
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _TvPlayerAction(
                                    icon: Icons.replay_10_rounded,
                                    semanticLabel: 'Back 10 seconds',
                                    onPressed: () => _seekRelative(
                                      const Duration(seconds: -10),
                                    ),
                                    onFocusChange: _handleTvControlFocus,
                                  ),
                                  const SizedBox(width: 14),
                                  StreamBuilder<bool>(
                                    stream: player.stream.playing,
                                    initialData: player.state.playing,
                                    builder: (context, snapshot) =>
                                        _TvPlayerAction(
                                      icon: snapshot.data == true
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      semanticLabel: snapshot.data == true
                                          ? 'Pause'
                                          : 'Play',
                                      prominent: true,
                                      onPressed: player.playOrPause,
                                      onFocusChange: _handleTvControlFocus,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  _TvPlayerAction(
                                    icon: Icons.forward_10_rounded,
                                    semanticLabel: 'Forward 10 seconds',
                                    onPressed: () => _seekRelative(
                                      const Duration(seconds: 10),
                                    ),
                                    onFocusChange: _handleTvControlFocus,
                                  ),
                                  const SizedBox(width: 24),
                                  _TvPlayerAction(
                                    icon: Icons.subtitles_rounded,
                                    label: 'Audio & Subtitles',
                                    onPressed: _showTracks,
                                    onFocusChange: _handleTvControlFocus,
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
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
                                  activeTrackColor: const Color(0xFFB9FF45),
                                  secondaryActiveTrackColor:
                                      const Color(0xFF5F7F38),
                                  inactiveTrackColor:
                                      const Color(0xFF273027),
                                  thumbColor: const Color(0xFFB9FF45),
                                  overlayColor:
                                      const Color(0x33B9FF45),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
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
                                    if (!mounted || _closing) return;
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
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFFB9FF45),
                                    foregroundColor: Colors.black,
                                    focusColor: const Color(0xFFCBFF75),
                                    hoverColor: const Color(0xFFD6FF91),
                                    elevation: 0,
                                  ),
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
                                          activeColor: const Color(0xFFB9FF45),
                                          secondaryActiveColor:
                                              const Color(0xFF5F7F38),
                                          thumbColor: const Color(0xFFB9FF45),
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
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFB9FF45),
              foregroundColor: Colors.black,
              focusColor: const Color(0xFFCBFF75),
              hoverColor: const Color(0xFFD6FF91),
              elevation: 0,
            ),
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

class _TvPlayerAction extends StatefulWidget {
  const _TvPlayerAction({
    required this.icon,
    required this.onPressed,
    required this.onFocusChange,
    this.label,
    this.semanticLabel,
    this.prominent = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChange;
  final String? label;
  final String? semanticLabel;
  final bool prominent;

  @override
  State<_TvPlayerAction> createState() => _TvPlayerActionState();
}

class _TvPlayerActionState extends State<_TvPlayerAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.prominent ? 64.0 : 48.0;
    const lime = Color(0xFFB9FF45);
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: widget.prominent
                ? (_focused
                    ? const [Color(0xFFCBFF75), lime]
                    : const [lime, Color(0xFF92D934)])
                : (_focused
                    ? const [Color(0xFF29411C), Color(0xFF182315)]
                    : const [Color(0xDD141915), Color(0xDD0E120F)]),
          ),
          borderRadius: BorderRadius.circular(widget.prominent ? 32 : 14),
          border: Border.all(
            color: _focused
                ? const Color(0xFFCBFF75)
                : widget.prominent
                    ? lime.withValues(alpha: .75)
                    : const Color(0x554F6550),
            width: _focused ? 2.2 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
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
                        color: widget.prominent ? Colors.black : Colors.white,
                        size: widget.prominent ? 34 : 26,
                      ),
                    ),
                    if (widget.label != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        widget.label!,
                        style: TextStyle(
                          color:
                              widget.prominent ? Colors.black : Colors.white,
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

class _TvProgressBar extends StatelessWidget {
  const _TvProgressBar({
    required this.played,
    required this.buffered,
  });

  final double played;
  final double buffered;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF252D27)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth * buffered,
                    child: const ColoredBox(color: Color(0xFF526644)),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth * played,
                    child: const ColoredBox(color: Color(0xFFB9FF45)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
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

class _AiSinhalaSwitchTile extends StatelessWidget {
  const _AiSinhalaSwitchTile({
    required this.value,
    required this.busy,
    required this.detail,
    required this.onChanged,
  });

  final bool value;
  final bool busy;
  final String detail;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: value
            ? primary.withValues(alpha: .10)
            : const Color(0xFF101411),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value
              ? primary.withValues(alpha: .58)
              : Colors.white.withValues(alpha: .10),
        ),
      ),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        secondary: Icon(
          Icons.translate_rounded,
          color: value ? primary : null,
        ),
        title: const Text(
          'AI Sinhala',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(detail),
        value: value,
        onChanged: busy ? null : onChanged,
      ),
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
