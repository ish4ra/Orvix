import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/media_item.dart';
import '../services/ai_audio_stt_service.dart';
import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_runtime_state.dart';
import '../services/ai_sinhala_trace_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/media_state_service.dart';
import '../services/native_subtitle_event_parser.dart';
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
    this.aiSourceUrl,
    this.mediaState,
    this.item,
    this.episode,
    this.aiSubtitle,
    this.preparedAiSubtitleFile,
    this.aiPreflightAttempted = false,
    this.aiPreflightFailure,
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
  // Original/direct media URL used only for AI subtitle inspection. Playback
  // may be wrapped by a localhost bridge; re-reading that bridge with FFmpeg
  // caused the beta.32/33 preparation stall.
  final String? aiSourceUrl;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final AiPreparedSubtitle? aiSubtitle;
  final AiGeneratedSubtitleFile? preparedAiSubtitleFile;
  final bool aiPreflightAttempted;
  final String? aiPreflightFailure;
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
  int _liveCueSequence = 0;
  int _liveDisplayedSequence = 0;
  String? _lastLiveCueKey;
  static const int _liveAiLeadMs = 6000;
  int _lastAiPrefetchBucket = -1;
  final List<String> _liveDialogueContext = <String>[];
  final Map<String, AiSubtitleCue> _liveExactCues =
      <String, AiSubtitleCue>{};
  final Set<String> _liveExactInFlight = <String>{};
  final Set<String> _liveExactLateKeys = <String>{};
  int _liveExactTraceCount = 0;
  String? _liveExactSyncKey;
  bool _windowsAiTextOnlyHeld = false;
  bool _aiSubtitleUnavailable = false;
  bool _aiPreferenceEnabled = false;
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
  int _liveCueTraceCount = 0;
  int _preparedTranslationFailures = 0;
  Future<bool>? _bufferedNativeAiPreparation;
  bool _audioAiActive = false;
  final Map<int, Future<void>> _audioAiWindowWorks = <int, Future<void>>{};
  final Set<int> _audioAiWindowStarts = <int>{};
  int _audioAiCoverageEndMs = 0;
  File? _audioAiSrtFile;
  bool _audioAiNativeAttached = false;
  bool _audioAiBitmapTimingMode = false;
  int _audioAiBitmapLastCueIndex = -1;
  Timer? _audioAiBitmapClearTimer;
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
        uri.port == 11470 &&
        uri.pathSegments.length >= 2 &&
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(uri.pathSegments.first) &&
        int.tryParse(uri.pathSegments[1]) != null;
  }

  bool get _localMediaBridgeStream {
    final uri = Uri.tryParse(widget.url);
    return uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port != 11470 &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'media';
  }

  bool get _aiSinhalaRequested => _aiState.requested;
  bool get _aiSinhalaEnabled => _aiState.enabled;
  bool get _liveAiFallback => _aiState.liveEmbedded;
  bool get _aiSubtitleLoading => _aiState.loading;

  void _transitionAi(AiSinhalaRuntimeMode next) {
    _aiState = _aiState.transition(next);
  }

  String get _aiMediaSourceUrl =>
      widget.aiSourceUrl?.trim().isNotEmpty == true
          ? widget.aiSourceUrl!.trim()
          : widget.url;

  Duration _audioWindowStartFor(Duration position) {
    final strideMs = AiAudioSttService.windowStride.inMilliseconds;
    final safeMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    return Duration(milliseconds: (safeMs ~/ strideMs) * strideMs);
  }

  String _normalizeAudioCueText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  String _srtTimestamp(Duration value) {
    final ms = value.inMilliseconds < 0 ? 0 : value.inMilliseconds;
    final hours = ms ~/ 3600000;
    final minutes = (ms ~/ 60000) % 60;
    final seconds = (ms ~/ 1000) % 60;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')},'
        '${millis.toString().padLeft(3, '0')}';
  }

  String _buildAudioAiSrt(AiPreparedSubtitle prepared) {
    final out = StringBuffer();
    var index = 1;
    for (final cue in prepared.cues) {
      final translation = cue.translation?.trim() ?? '';
      if (translation.isEmpty || cue.end <= cue.start) continue;
      out.writeln(index++);
      out.writeln('${_srtTimestamp(cue.start)} --> ${_srtTimestamp(cue.end)}');
      out.writeln(translation);
      out.writeln();
    }
    return out.toString();
  }

  Future<bool> _syncAudioAiNativeTrack({required bool initial}) async {
    final prepared = _preparedAiSubtitle;
    final platform = widget.playback.player.platform;
    if (prepared == null ||
        prepared.cues.isEmpty ||
        platform is! mk.NativePlayer ||
        _closing) {
      return false;
    }

    try {
      final srt = _buildAudioAiSrt(prepared);
      if (srt.trim().isEmpty) return false;

      var file = _audioAiSrtFile;
      if (file == null) {
        final temp = await getTemporaryDirectory();
        final dir = Directory(
          '${temp.path}${Platform.pathSeparator}orvix-ai-subs',
        );
        await dir.create(recursive: true);
        file = File(
          '${dir.path}${Platform.pathSeparator}'
          'audio_si_${DateTime.now().microsecondsSinceEpoch}.srt',
        );
        _audioAiSrtFile = file;
      }

      await file.writeAsString(srt, flush: true);
      final uri = Platform.isWindows
          ? Uri.file(file.path, windows: true).toString()
          : Uri.file(file.path).toString();
      final player = widget.playback.player;
      final track = mk.SubtitleTrack.uri(
        uri,
        title: 'AI Sinhala • audio',
        language: 'si',
      );

      bool selectedIsAudioAi() {
        final selected = player.state.track.subtitle;
        final selectedId = selected.id.toLowerCase();
        final selectedTitle = (selected.title ?? '').toLowerCase();
        final selectedLanguage = (selected.language ?? '').toLowerCase();
        return selectedId != 'no' &&
            (selectedLanguage == 'si' ||
                selectedLanguage == 'sin' ||
                selectedTitle.contains('ai sinhala'));
      }

      Future<bool> selectAndVerify() async {
        for (var attempt = 0; attempt < 10 && !_closing; attempt++) {
          try {
            await player.setSubtitleTrack(track);
            await _setNativeSubtitleDelayProperty(0);
            await _setNativeSubtitleVisibility(true);
          } catch (_) {}
          await Future<void>.delayed(
            Duration(milliseconds: attempt < 4 ? 120 : 220),
          );
          if (selectedIsAudioAi()) return true;
        }
        return false;
      }

      final firstAttach = !_audioAiNativeAttached || initial;
      if (firstAttach) {
        // Use the same media_kit attach path that is proven by complete
        // generated Sinhala SRTs, and do not report readiness until the player
        // state confirms that the Sinhala track is selected.
        if (!await selectAndVerify()) {
          throw const AiSubtitleException(
            'MPV did not confirm the rolling AI Sinhala audio subtitle track.',
          );
        }
        _audioAiNativeAttached = true;
      } else {
        var reloaded = false;
        var currentSid = '';
        try {
          currentSid = (await platform.getProperty(
            'sid',
            waitForInitialization: false,
          ))
              .trim();
        } catch (_) {}

        try {
          final command = currentSid.isNotEmpty &&
                  currentSid != 'no' &&
                  currentSid != 'auto'
              ? <String>['sub-reload', currentSid]
              : const <String>['sub-reload'];
          await platform.command(
            command,
            waitForInitialization: false,
            throwOnError: true,
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
          reloaded = selectedIsAudioAi();
        } catch (_) {
          reloaded = false;
        }

        // If this libmpv build rejects reload, recover through the same verified
        // high-level attach path rather than silently leaving stale SRT content.
        if (!reloaded && !await selectAndVerify()) {
          throw const AiSubtitleException(
            'MPV could not reload or reselect the rolling AI Sinhala subtitle track.',
          );
        }
        _audioAiNativeAttached = true;
      }

      await _setNativeSubtitleDelayProperty(0);
      await _setNativeSubtitleVisibility(true);
      var sid = '';
      try {
        sid = (await platform.getProperty(
          'sid',
          waitForInitialization: false,
        ))
            .trim();
      } catch (_) {}

      unawaited(
        AiSinhalaTraceService.write(
          firstAttach
              ? 'audio-ai-native-attach cues=${prepared.cues.length} '
                  'bytes=${await file.length()} sid=$sid confirmed=true'
              : 'audio-ai-native-reload cues=${prepared.cues.length} '
                  'bytes=${await file.length()} sid=$sid confirmed=true',
        ),
      );
      return true;
    } catch (error) {
      _audioAiNativeAttached = false;
      unawaited(
        AiSinhalaTraceService.write(
          'audio-ai-native-error initial=$initial '
          'type=${error.runtimeType} '
          'detail="${error.toString().replaceAll(RegExp(r'[\\r\\n|]+'), ' ')}"',
        ),
      );
      return false;
    }
  }

  Future<void> _removeAudioAiNativeTrack() async {
    if (!_audioAiNativeAttached) return;
    final platform = widget.playback.player.platform;
    if (platform is mk.NativePlayer) {
      try {
        await platform.command(
          const <String>['sub-remove'],
          waitForInitialization: false,
        );
      } catch (_) {}
    }
    _audioAiNativeAttached = false;
  }

  void _mergeAudioAiCues(List<AiAudioSinhalaCue> incoming) {
    final prepared = _preparedAiSubtitle;
    if (prepared == null || incoming.isEmpty) return;

    for (final cue in incoming) {
      final normalized = _normalizeAudioCueText(cue.english);
      final duplicate = prepared.cues.any((existing) {
        final delta =
            (existing.start.inMilliseconds - cue.start.inMilliseconds).abs();
        return delta <= 1600 &&
            _normalizeAudioCueText(existing.source) == normalized;
      });
      if (duplicate) continue;
      prepared.cues.add(
        AiSubtitleCue(
          start: cue.start,
          end: cue.end,
          source: cue.english,
          translation: cue.sinhala,
        ),
      );
      if (cue.end.inMilliseconds > _audioAiCoverageEndMs) {
        _audioAiCoverageEndMs = cue.end.inMilliseconds;
      }
    }
    prepared.cues.sort((a, b) => a.start.compareTo(b.start));
  }

  Future<List<AiAudioSinhalaCue>> _loadAudioAiWindow(
    Duration start, {
    required String phase,
  }) async {
    final startMs = start.inMilliseconds < 0 ? 0 : start.inMilliseconds;
    if (_audioAiWindowStarts.contains(startMs)) {
      return const <AiAudioSinhalaCue>[];
    }
    _audioAiWindowStarts.add(startMs);
    unawaited(
      AiSinhalaTraceService.write(
        'audio-ai-window-start phase=$phase startMs=$startMs '
        'sourceHost=${AiSinhalaTraceService.safeHost(_aiMediaSourceUrl)}',
      ),
    );
    try {
      final cues = await AiAudioSttService.transcribeWindow(
        title: widget.title,
        videoUrl: _aiMediaSourceUrl,
        start: Duration(milliseconds: startMs),
      );
      unawaited(
        AiSinhalaTraceService.write(
          'audio-ai-window-result phase=$phase startMs=$startMs cues=${cues.length}',
        ),
      );
      return cues;
    } catch (error) {
      unawaited(
        AiSinhalaTraceService.write(
          'audio-ai-window-error phase=$phase startMs=$startMs '
          'type=${error.runtimeType} detail="${error.toString().replaceAll(RegExp(r'[\\r\\n|]+'), ' ')}"',
        ),
      );
      return const <AiAudioSinhalaCue>[];
    }
  }

  Future<bool> _activateAudioAiFallback({
    required String phase,
    Duration? around,
  }) async {
    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return false;
    }
    if (_audioAiActive && _preparedAiSubtitle != null) return true;

    final player = widget.playback.player;
    final bitmapTimingTrack = _bestNativeEnglishBitmapTrack();
    final embeddedEnglishBitmap = bitmapTimingTrack != null;
    final audioReason = embeddedEnglishBitmap
        ? 'Embedded English subtitle found, but it is image-based (PGS/VobSub). Orvix is using its exact cue timing while listening to the audio for Sinhala dialogue…'
        : 'No readable English text subtitle was exposed by this source. Listening to the video audio for Sinhala dialogue…';

    if (_aiState.mode != AiSinhalaRuntimeMode.preparing) {
      setState(() {
        if (_aiState.mode != AiSinhalaRuntimeMode.native) {
          _transitionAi(AiSinhalaRuntimeMode.native);
        }
        _transitionAi(AiSinhalaRuntimeMode.preparing);
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = audioReason;
      });
    } else {
      setState(() {
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = audioReason;
      });
    }

    // Bitmap English subtitles cannot supply text, but they still contain the
    // release-authored timing we want. Keep that PGS/VobSub track selected and
    // decoded while hiding its native pixels; the Flutter Sinhala overlay will
    // later be driven by the exact bitmap cue clock instead of Gemini timing.
    _audioAiBitmapTimingMode = false;
    _audioAiBitmapLastCueIndex = -1;
    _audioAiBitmapClearTimer?.cancel();
    _audioAiBitmapClearTimer = null;
    if (bitmapTimingTrack != null) {
      try {
        await player.setSubtitleTrack(bitmapTimingTrack);
        _timingTrackSelected = true;
        _timingTrackIsText = false;
        _audioAiBitmapTimingMode = true;
        _lastNativeSubtitleStartMs = null;
        await _hideNativeTimingSubtitle();
        _startNativeSubtitleClock();
        unawaited(
          AiSinhalaTraceService.write(
            'audio-ai-bitmap-clock id=${bitmapTimingTrack.id} '
            'language=${bitmapTimingTrack.language ?? ''} '
            'codec=${bitmapTimingTrack.codec ?? ''}',
          ),
        );
      } catch (error) {
        _timingTrackSelected = false;
        _timingTrackIsText = false;
        _audioAiBitmapTimingMode = false;
        unawaited(
          AiSinhalaTraceService.write(
            'audio-ai-bitmap-clock-error type=${error.runtimeType}',
          ),
        );
      }
    }

    final firstStart =
        _audioWindowStartFor(around ?? player.state.position);

    // The old serial 28s/20s pipeline could not keep up: a single Gemini/STT
    // window often takes 20-35 seconds. On Windows prepare two overlapping
    // windows concurrently so startup has both the opening and the next region,
    // then keep two workers roughly a minute ahead during playback.
    final starts = <Duration>[firstStart];
    if (Platform.isWindows) {
      starts.add(firstStart + AiAudioSttService.windowStride);
      if (mounted) {
        setState(() {
          _aiPreflightMessage = embeddedEnglishBitmap
              ? 'Reading the first two dialogue windows while preserving the embedded subtitle timing…'
              : 'Reading the first two dialogue windows in parallel…';
        });
      }
    }

    final batches = await Future.wait<List<AiAudioSinhalaCue>>(
      starts.indexed.map(
        (entry) => _loadAudioAiWindow(
          entry.$2,
          phase: entry.$1 == 0 ? phase : '$phase-ahead',
        ),
      ),
    );
    var cues = batches.expand((batch) => batch).toList(growable: true)
      ..sort((a, b) => a.start.compareTo(b.start));

    // Non-Windows keeps the conservative single-worker path.
    if (!Platform.isWindows && cues.isEmpty && mounted && !_closing) {
      final secondStart = firstStart + AiAudioSttService.windowStride;
      if (mounted) {
        setState(() {
          _aiPreflightMessage =
              'The first audio window was quiet. Checking the next dialogue window…';
        });
      }
      cues = await _loadAudioAiWindow(secondStart, phase: '$phase-retry');
    }

    // Collapse the overlap between 28-second windows before creating the
    // prepared subtitle timeline.
    final unique = <AiAudioSinhalaCue>[];
    for (final cue in cues) {
      final normalized = _normalizeAudioCueText(cue.english);
      final duplicate = unique.any((existing) {
        final delta =
            (existing.start.inMilliseconds - cue.start.inMilliseconds).abs();
        return delta <= 1800 &&
            _normalizeAudioCueText(existing.english) == normalized;
      });
      if (!duplicate) unique.add(cue);
    }
    cues = unique;

    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return false;
    }

    if (cues.isEmpty) {
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiSubtitleUnavailable = true;
        _aiPreflightMessage =
            'AI Sinhala could not derive dialogue from this source, so Orvix will play the available native subtitles.';
      });
      _audioAiBitmapTimingMode = false;
      _timingTrackSelected = false;
      _timingTrackIsText = false;
      await _setNativeSubtitleVisibility(true);
      return false;
    }

    final converted = cues
        .map(
          (cue) => AiSubtitleCue(
            start: cue.start,
            end: cue.end,
            source: cue.english,
            translation: cue.sinhala,
          ),
        )
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    _preparedAiSubtitle = AiPreparedSubtitle(
      key: 'audio-stt-v2:${widget.title}:${_aiMediaSourceUrl.hashCode}',
      title: widget.title,
      sourceUrl: _aiMediaSourceUrl,
      cues: converted,
      sourceMatch:
          _audioAiBitmapTimingMode ? 'audio-stt+bitmap-clock' : 'audio-stt',
    );
    _audioAiCoverageEndMs = converted.fold<int>(
      0,
      (best, cue) =>
          cue.end.inMilliseconds > best ? cue.end.inMilliseconds : best,
    );
    _audioAiActive = true;
    if (!_audioAiBitmapTimingMode) {
      _timingTrackSelected = false;
      _timingTrackIsText = false;
      _nativeSubtitleClockTimer?.cancel();
    }
    _nativeAiMatchIndex = -1;
    _lastAiPrefetchBucket = -1;
    _liveCueClearTimer?.cancel();

    setState(() {
      _transitionAi(AiSinhalaRuntimeMode.prepared);
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage = _audioAiBitmapTimingMode
          ? 'AI Sinhala is ready. Embedded PGS/VobSub timing is now the sync authority.'
          : 'AI Sinhala audio subtitles are ready. Orvix will keep generating them ahead of playback.';
    });

    _positionSubscription ??=
        player.stream.position.listen(_onPosition);

    if (_audioAiBitmapTimingMode) {
      // Keep the bitmap track selected but invisible. Do NOT replace it with
      // the generated SRT, otherwise we lose the exact native timing oracle.
      _audioAiNativeAttached = false;
      await _hideNativeTimingSubtitle();
      _startNativeSubtitleClock();
    } else {
      final nativeAttached = await _syncAudioAiNativeTrack(initial: true);
      if (!nativeAttached) {
        await _setNativeSubtitleVisibility(false);
        _refreshAiSubtitle();
      } else if (mounted && _aiDisplaySubtitle.isNotEmpty) {
        setState(() => _aiDisplaySubtitle = '');
      }
    }

    // Fill the future timeline immediately instead of waiting until only 12s
    // remain. This is what keeps the comparatively slow audio/STT path ahead of
    // real-time playback.
    _ensureAudioAiAhead(player.state.position);

    unawaited(
      AiSinhalaTraceService.write(
        'audio-ai-ready phase=$phase cues=${converted.length} '
        'coverageEndMs=$_audioAiCoverageEndMs '
        'bitmapClock=$_audioAiBitmapTimingMode workers=${_audioAiWindowWorks.length}',
      ),
    );
    return true;
  }

  void _ensureAudioAiAhead(Duration position) {
    if (!_audioAiActive ||
        !_aiSinhalaEnabled ||
        _closing ||
        _subtitleChoiceOverridden ||
        _preparedAiSubtitle == null) {
      return;
    }

    final maxConcurrent = Platform.isWindows ? 2 : 1;
    if (_audioAiWindowWorks.length >= maxConcurrent) return;

    final positionMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    final horizonMs = positionMs + (Platform.isWindows ? 80000 : 35000);
    final strideMs = AiAudioSttService.windowStride.inMilliseconds;
    final durationMs = AiAudioSttService.windowDuration.inMilliseconds;

    var candidate = _audioWindowStartFor(position);
    if (_audioAiWindowStarts.isNotEmpty) {
      final furthestStart =
          _audioAiWindowStarts.reduce((a, b) => a > b ? a : b);
      final stillNearPreparedRegion =
          positionMs <= furthestStart + durationMs + strideMs;
      if (stillNearPreparedRegion) {
        candidate = Duration(milliseconds: furthestStart + strideMs);
      }
    }

    var inspected = 0;
    while (_audioAiWindowWorks.length < maxConcurrent &&
        candidate.inMilliseconds <= horizonMs &&
        inspected < 12) {
      final startMs = candidate.inMilliseconds;
      if (!_audioAiWindowStarts.contains(startMs) &&
          !_audioAiWindowWorks.containsKey(startMs)) {
        _queueAudioAiWindow(candidate);
      }
      candidate += AiAudioSttService.windowStride;
      inspected++;
    }
  }

  void _queueAudioAiWindow(Duration start) {
    if (_closing || !_audioAiActive) return;
    final startMs = start.inMilliseconds < 0 ? 0 : start.inMilliseconds;
    if (_audioAiWindowWorks.containsKey(startMs) ||
        _audioAiWindowStarts.contains(startMs)) {
      return;
    }

    late final Future<void> work;
    work = () async {
      final cues = await _loadAudioAiWindow(
        Duration(milliseconds: startMs),
        phase: 'prefetch',
      );
      if (!mounted || _closing || !_audioAiActive) return;
      if (cues.isNotEmpty) {
        _mergeAudioAiCues(cues);
        if (!_audioAiBitmapTimingMode) {
          final nativeUpdated =
              await _syncAudioAiNativeTrack(initial: false);
          if (!nativeUpdated) {
            _refreshAiSubtitle();
          }
        }
      }
    }();

    _audioAiWindowWorks[startMs] = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_audioAiWindowWorks[startMs], work)) {
          _audioAiWindowWorks.remove(startMs);
        }
        if (mounted && !_closing && _audioAiActive) {
          _ensureAudioAiAhead(widget.playback.player.state.position);
        }
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    // Complete-file AI Sinhala never starts from a partial/live buffer.
    // A cached generated SRT is resolved by the service after the real video
    // source is opened, so startup always has one deterministic path.
    _preparedAiSubtitle = null;
    _aiState = const AiSinhalaRuntimeState.native();
    unawaited(_loadSubtitlePreferences());
    _playbackErrorSubscription =
        widget.playback.player.stream.error.listen(_onPlaybackError);
    _startupPlayingSubscription =
        widget.playback.player.stream.playing.listen((playing) {
      if (!playing || _closing || _preflightWarmup) return;
      if (widget.playback.player.state.position > Duration.zero) {
        _markPlaybackStarted();
      }
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
    return _playbackStarted ||
        (state.playing && state.position > Duration.zero);
  }

  void _markPlaybackStarted() {
    if (_closing || _preflightWarmup) return;
    final firstStart = !_playbackStarted;
    _startupTimer?.cancel();

    if (mounted) {
      setState(() {
        _playbackStarted = true;
        if (_startupFailureVisible) {
          _startupFailureVisible = false;
          _error = null;
        }
      });
    } else {
      _playbackStarted = true;
    }

    if (firstStart && !_successReported) {
      _successReported = true;
      widget.onPlaybackStarted?.call();
    }
  }

  bool _isAiTranslationOnlyFailure(String message) {
    final value = message.toLowerCase();
    return value.contains('translate subtitle buffer') ||
        value.contains('subtitle buffer was incomplete') ||
        value.contains('non-sinhala subtitle buffer') ||
        value.contains('did not finish translating') ||
        value.contains('subtitle limit reached') ||
        value.contains('translation_failed');
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

  void _scheduleBufferedNativeCueAi({
    String? preferredTrackLabel,
    String phase = 'native-track',
  }) {
    if (_bufferedNativeAiPreparation != null ||
        !mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return;
    }

    final work = _prepareBufferedNativeCueAi(
      preferredTrackLabel: preferredTrackLabel,
      phase: phase,
    );
    _bufferedNativeAiPreparation = work;
    unawaited(
      work.then<void>((_) {}).whenComplete(() {
        if (identical(_bufferedNativeAiPreparation, work)) {
          _bufferedNativeAiPreparation = null;
        }
      }),
    );
  }

  Future<bool> _prepareBufferedNativeCueAi({
    String? preferredTrackLabel,
    required String phase,
  }) async {
    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return false;
    }

    // A text track being detected is NOT the same thing as Sinhala being
    // ready. beta.33 returned true here immediately, which made _open() start
    // playback and remove the loading overlay before any translated cue
    // existed. Stay in PREPARING until both a trusted transcript and the first
    // Sinhala buffer are actually ready.
    if (_aiState.mode != AiSinhalaRuntimeMode.preparing) {
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.preparing);
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage =
            'English subtitle track found. Preparing the first Sinhala buffer…';
      });
    } else if (mounted) {
      setState(() {
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage =
            'English subtitle track found. Preparing the first Sinhala buffer…';
      });
    }

    await _setNativeSubtitleVisibility(true);

    final sourceUrl = widget.aiSourceUrl?.trim().isNotEmpty == true
        ? widget.aiSourceUrl!.trim()
        : widget.url;

    unawaited(
      AiSinhalaTraceService.write(
        'buffered-native-ai-start phase=$phase '
        'playbackHost=${AiSinhalaTraceService.safeHost(widget.url)} '
        'sourceHost=${AiSinhalaTraceService.safeHost(sourceUrl)}',
      ),
    );

    AiPreparedSubtitle? prepared;
    try {
      prepared =
          await AiSinhalaSubtitleService.prepareTrustedTranscriptForNativeClock(
        title: widget.title,
        // IMPORTANT: inspect the original provider/debrid URL, never the
        // localhost playback bridge. FFmpegKit re-reading the localhost bridge
        // was the reason preparation sat for minutes while MPV already had the
        // real SubRip track open.
        videoUrl: sourceUrl,
        releaseHint: widget.releaseHint,
        expectedSizeBytes: widget.expectedSizeBytes,
        expectedVideoHash: widget.expectedVideoHash,
        preferredTrackLabel: preferredTrackLabel,
        onStatus: (message) {
          if (!mounted || _closing) return;
          setState(() => _aiPreflightMessage = message);
        },
      );
    } catch (error) {
      unawaited(
        AiSinhalaTraceService.write(
          'buffered-native-ai-error phase=$phase type=${error.runtimeType}',
        ),
      );
      if (mounted && !_closing) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiPreflightMessage =
              'Could not prepare a trusted English transcript for this source.';
        });
      }
      return false;
    }

    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return false;
    }

    if (prepared == null) {
      unawaited(
        AiSinhalaTraceService.write(
          'buffered-native-ai-miss phase=$phase '
          'sourceHost=${AiSinhalaTraceService.safeHost(sourceUrl)}',
        ),
      );
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.native);
        _aiSubtitleUnavailable = true;
        _aiPreflightMessage =
            'No trusted text transcript could be prepared for this exact video.';
      });
      return false;
    }

    // Do not call this "ready" until actual Sinhala text exists. Translate the
    // first window while the player remains paused and the loading overlay is
    // visible. Later windows continue in the background.
    try {
      if (mounted) {
        setState(() {
          _aiPreflightMessage =
              'English transcript locked. Translating the first Sinhala lines…';
        });
      }
      await AiSinhalaSubtitleService.ensureTranslatedAround(
        prepared,
        Duration.zero,
        lookBehind: 0,
        lookAhead: 36,
      );
    } catch (error) {
      unawaited(
        AiSinhalaTraceService.write(
          'buffered-native-ai-first-buffer-error phase=$phase '
          'type=${error.runtimeType}',
        ),
      );
      if (mounted && !_closing) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiPreflightMessage =
              'The first Sinhala subtitle buffer could not be translated.';
        });
      }
      return false;
    }

    if (prepared.translatedCount <= 0) {
      unawaited(
        AiSinhalaTraceService.write(
          'buffered-native-ai-first-buffer-empty phase=$phase',
        ),
      );
      if (mounted && !_closing) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = true;
          _aiPreflightMessage =
              'No Sinhala subtitle lines were produced for the opening buffer.';
        });
      }
      return false;
    }

    _nativeSubtitleClockTimer?.cancel();
    _liveCueClearTimer?.cancel();
    _audioAiBitmapClearTimer?.cancel();
    _audioAiBitmapClearTimer = null;
    _liveCueGeneration++;
    _preparedAiSubtitle = prepared;
    _generatedAiSubtitlePath = null;
    _generatedAiSubtitleLabel = null;
    _nativeAiMatchIndex = -1;
    _lastAiPrefetchBucket = -1;
    _timingTrackSelected = true;
    _timingTrackIsText = true;

    setState(() {
      _transitionAi(AiSinhalaRuntimeMode.prepared);
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage =
          'Sinhala opening buffer ready. Translating ahead during playback.';
    });

    _positionSubscription ??=
        widget.playback.player.stream.position.listen(_onPosition);
    if (widget.playback.player.platform is! mk.NativePlayer) {
      _subtitleTimingSubscription ??=
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
    }

    await _setNativeSubtitleDelayProperty(0);
    await _setNativeSubtitleVisibility(true);
    _startNativeSubtitleClock();
    await _loadManualSync();
    if (!mounted || _closing) return false;

    final position = widget.playback.player.state.position;
    final bucket = position.inSeconds ~/ 30;
    _lastAiPrefetchBucket = bucket;
    unawaited(_ensureAiTranslationNear(position, bucket: bucket));
    unawaited(_refreshNativeCueAfterSeek());

    unawaited(
      AiSinhalaTraceService.write(
        'buffered-native-ai-ready phase=$phase '
        'cues=${prepared.cues.length} translated=${prepared.translatedCount} '
        'source=${prepared.sourceMatch} '
        'sourceHost=${AiSinhalaTraceService.safeHost(sourceUrl)}',
      ),
    );
    return true;
  }

  Future<bool> _activateProgressiveNativeCueAi({
    Duration maxWait = const Duration(milliseconds: 6500),
    String phase = 'initial',
  }) async {
    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden) {
      return false;
    }

    final player = widget.playback.player;
    final deadline = DateTime.now().add(maxWait);
    mk.SubtitleTrack? track;

    do {
      track = _bestNativeEnglishTextTrack();
      if (track != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } while (mounted && !_closing && DateTime.now().isBefore(deadline));

    if (track == null) {
      final trackSummary = player.state.tracks.subtitle
          .where((candidate) => candidate.id.toLowerCase() != 'no')
          .take(8)
          .map((candidate) {
            final title = (candidate.title ?? '')
                .replaceAll(RegExp(r'[\\r\\n|]+'), ' ')
                .trim();
            final language = (candidate.language ?? '').trim();
            final codec = (candidate.codec ?? '').trim();
            return '${candidate.id}:$language:$codec:$title';
          })
          .join(' | ');
      unawaited(
        AiSinhalaTraceService.write(
          'native-cue-ai-miss phase=$phase '
          'tracks=${player.state.tracks.subtitle.length} '
          'detail="$trackSummary" '
          'host=${AiSinhalaTraceService.safeHost(widget.url)}',
        ),
      );
      if (maxWait > Duration.zero) {
        if (Platform.isWindows) {
          final bitmap = _bestNativeEnglishBitmapTrack();
          _windowsAiTextOnlyHeld = true;

          if (bitmap != null) {
            try {
              await player.setSubtitleTrack(bitmap);
              await _setNativeSubtitleVisibility(true);
              await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
            } catch (_) {}
          }

          if (mounted && !_closing) {
            setState(() {
              if (_aiState.mode != AiSinhalaRuntimeMode.native) {
                _transitionAi(AiSinhalaRuntimeMode.native);
              }
              _aiSubtitleUnavailable = true;
              _aiDisplaySubtitle = '';
              _aiPreflightMessage = bitmap != null
                  ? 'AI Sinhala is paused for this source because its English subtitle is image-based (PGS/VobSub). Native subtitles will be used instead of the unreliable audio-listening fallback.'
                  : 'AI Sinhala is paused for this source because no readable English SRT/ASS track was exposed. Native playback will continue normally.';
            });
          }
          unawaited(
            AiSinhalaTraceService.write(
              'audio-ai-held phase=$phase bitmap=${bitmap != null} '
              'reason=${bitmap != null ? 'image-subtitle' : 'no-text-track'}',
            ),
          );
          return false;
        }
        return _activateAudioAiFallback(phase: '$phase-no-text');
      }
      return false;
    }

    try {
      await player.setSubtitleTrack(track);
      _windowsAiTextOnlyHeld = false;
      _timingTrackSelected = true;
      _timingTrackIsText = true;
      _nativeAiMatchIndex = -1;

      final title =
          (track.title ?? '').replaceAll(RegExp(r'[\\r\\n]+'), ' ').trim();
      final language = (track.language ?? '').trim();
      final codec = (track.codec ?? '').trim();
      unawaited(
        AiSinhalaTraceService.write(
          'native-cue-ai-ready phase=$phase id=${track.id} '
          'language=$language codec=$codec title="$title"',
        ),
      );

      await _setNativeSubtitleVisibility(true);

      if (Platform.isWindows) {
        // MPV has already exposed a real English text track. Re-opening the
        // entire remote MKV with FFmpeg just to reconstruct that same subtitle
        // can take minutes because FFmpeg must walk the file. On Windows, use
        // the native cue text that MPV is already decoding and translate those
        // cues live. This keeps startup bounded to track discovery instead of
        // blocking at 0:00 on a full-file scan.
        final liveReady = await _enableEmbeddedLiveAiFallback(
          'Using the detected English text track directly; full-file rescanning is skipped on Windows.',
        );
        unawaited(
          AiSinhalaTraceService.write(
            'native-cue-ai-live phase=$phase id=${track.id} '
            'language=$language codec=$codec',
          ),
        );
        return liveReady;
      }

      final bufferedReady = await _prepareBufferedNativeCueAi(
        preferredTrackLabel: _subtitleTrackPreferenceLabel(track),
        phase: phase,
      );
      if (bufferedReady) return true;
      if (maxWait > Duration.zero) {
        return _activateAudioAiFallback(phase: '$phase-transcript-miss');
      }
      return false;
    } catch (error) {
      _timingTrackSelected = false;
      _timingTrackIsText = false;
      unawaited(
        AiSinhalaTraceService.write(
          'native-cue-ai-failed phase=$phase type=${error.runtimeType}',
        ),
      );
      return false;
    }
  }

  Future<void> _discoverNativeCueAiAfterPlayback() async {
    // Some remote containers do not publish concrete subtitle-track metadata
    // immediately. The regular MPV player may still auto-select an embedded
    // text subtitle and emit real cues. Observe BOTH signals for a short
    // window: explicit track metadata and actual subtitle text. This keeps the
    // path provider-independent and avoids ever treating media_kit's "auto"
    // selector itself as a subtitle track.
    var activated = false;
    StreamSubscription<List<String>>? cueProbe;

    Future<void> activateFromCue(List<String> lines) async {
      if (activated ||
          !mounted ||
          _closing ||
          !_aiPreferenceEnabled ||
          _subtitleChoiceOverridden ||
          _liveAiFallback) {
        return;
      }

      final source = lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .join('\n')
          .trim();
      if (!_looksLikeEnglishNativeCue(source)) return;

      final current = widget.playback.player.state.track.subtitle;
      if (_isImageSubtitleTrack(current)) return;

      var nativeSid = '';
      final platform = widget.playback.player.platform;
      if (platform is mk.NativePlayer) {
        try {
          nativeSid = (await platform.getProperty(
            'sid',
            waitForInitialization: false,
          ))
              .trim();
        } catch (_) {}
      }

      _timingTrackSelected = true;
      _timingTrackIsText = true;
      _nativeAiMatchIndex = -1;

      final title =
          (current.title ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      final language = (current.language ?? '').trim();
      final codec = (current.codec ?? '').trim();
      unawaited(
        AiSinhalaTraceService.write(
          'native-cue-ai-ready phase=cue-probe id=${current.id} '
          'nativeSid=$nativeSid language=$language codec=$codec title="$title" '
          'chars=${source.length}',
        ),
      );

      if (_aiState.mode != AiSinhalaRuntimeMode.native && mounted) {
        setState(() {
          _transitionAi(AiSinhalaRuntimeMode.native);
          _aiSubtitleUnavailable = false;
          _aiDisplaySubtitle = '';
        });
      }
      await _setNativeSubtitleVisibility(true);
      _windowsAiTextOnlyHeld = false;
      if (Platform.isWindows) {
        activated = await _enableEmbeddedLiveAiFallback(
          'A readable English text cue appeared after startup; switching to the exact native cue timeline.',
        );
        return;
      }
      _scheduleBufferedNativeCueAi(
        preferredTrackLabel: <String>[
          title,
          language,
          codec,
        ].where((value) => value.isNotEmpty).join(' • '),
        phase: 'cue-probe',
      );
      activated = true;
    }

    cueProbe = widget.playback.player.stream.subtitle.listen(
      (lines) => unawaited(activateFromCue(lines)),
    );

    try {
      for (var attempt = 0;
          attempt < 40 &&
              mounted &&
              !_closing &&
              _aiPreferenceEnabled &&
              !_subtitleChoiceOverridden &&
              !_liveAiFallback &&
              !activated;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));

        // The native renderer is the strongest proof that the regular player
        // really has a text subtitle, even when media_kit still reports only
        // its synthetic "auto" selector. Read the exact text MPV is currently
        // rendering and feed that first real cue into the AI path.
        final platform = widget.playback.player.platform;
        if (platform is mk.NativePlayer) {
          try {
            final text = (await platform.getProperty(
              'sub-text',
              waitForInitialization: false,
            ))
                .trim();
            if (text.isNotEmpty) {
              await activateFromCue(<String>[text]);
              if (activated || _liveAiFallback) return;
            }
          } catch (_) {}
        }

        if (_bestNativeEnglishTextTrack() == null) continue;
        final ready = await _activateProgressiveNativeCueAi(
          maxWait: Duration.zero,
          phase: 'late',
        );
        if (ready) {
          activated = true;
          return;
        }
      }
    } finally {
      await cueProbe.cancel();
    }

    if (!mounted ||
        _closing ||
        !_aiPreferenceEnabled ||
        _subtitleChoiceOverridden ||
        activated) {
      return;
    }

    final trackSummary = widget.playback.player.state.tracks.subtitle
        .take(10)
        .map((track) {
          final title =
              (track.title ?? '').replaceAll(RegExp(r'[\r\n|]+'), ' ').trim();
          final language = (track.language ?? '').trim();
          final codec = (track.codec ?? '').trim();
          return '${track.id}:$language:$codec:$title';
        })
        .join(' | ');
    unawaited(
      AiSinhalaTraceService.write(
        'native-cue-ai-final-miss detail="$trackSummary" '
        'host=${AiSinhalaTraceService.safeHost(widget.url)}',
      ),
    );
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
      if (mounted) {
        setState(() => _aiPreferenceEnabled = aiSettingEnabled);
      } else {
        _aiPreferenceEnabled = aiSettingEnabled;
      }
      final aiPreferred = widget.allowAiSinhala && aiSettingEnabled;
      final preprepared =
          aiPreferred ? widget.preparedAiSubtitleFile : null;

      unawaited(
        AiSinhalaTraceService.write(
          'player-open aiSetting=$aiSettingEnabled '
          'allowAi=${widget.allowAiSinhala} '
          'preflightAttempted=${widget.aiPreflightAttempted} '
          'preprepared=${preprepared != null} '
          'host=${AiSinhalaTraceService.safeHost(widget.url)}',
        ),
      );

      // Universal startup path: open the actual player first, then use the
      // subtitle tracks that the active demuxer reports. This is provider
      // independent and shared by Windows, macOS, Android mobile and Android TV.
      // Complete-file extraction remains available for manual/verified subtitle
      // flows, but it no longer blocks startup.
      final useProgressiveNativeCueAi = aiPreferred &&
          preprepared == null &&
          !widget.aiPreflightAttempted;
      var aiReady = preprepared != null;
      var reopenedAfterAiFailure = false;

      if (preprepared != null) {
        _generatedAiSubtitlePath = preprepared.path;
        _generatedAiSubtitleLabel = preprepared.label;
      }

      if (mounted && !_subtitleChoiceOverridden) {
        setState(() {
          if (preprepared != null) {
            _transitionAi(AiSinhalaRuntimeMode.prepared);
          } else if (useProgressiveNativeCueAi) {
            _transitionAi(AiSinhalaRuntimeMode.preparing);
          } else if (_aiState.mode != AiSinhalaRuntimeMode.native) {
            _transitionAi(AiSinhalaRuntimeMode.native);
          }
          _aiSubtitleUnavailable =
              aiPreferred && widget.aiPreflightAttempted && preprepared == null;
          _aiDisplaySubtitle = '';
          _aiPreflightMessage = preprepared != null
              ? 'Complete Sinhala subtitle was prepared before the player opened.'
              : useProgressiveNativeCueAi
                  ? 'Opening the selected source and detecting its native English subtitle track…'
                  : (widget.aiPreflightFailure ?? '');
        });
      }

      // Keep the player paused for at most a couple of seconds while MPV
      // publishes its real track list. Unlike the old architecture, this does
      // not download/translate the entire episode before playback.
      await widget.playback.open(
        widget.url,
        title: widget.title,
        play: !(aiReady || useProgressiveNativeCueAi),
      );

      if (aiReady && _generatedAiSubtitlePath != null) {
        await _setNativeSubtitleVisibility(false);
        await _loadGeneratedAiSubtitleTrack();
      } else if (useProgressiveNativeCueAi) {
        await _setNativeSubtitleVisibility(true);
        aiReady = await _activateProgressiveNativeCueAi();
        if (!aiReady && mounted && !_closing) {
          setState(() {
            if (_aiState.mode != AiSinhalaRuntimeMode.native) {
              _transitionAi(AiSinhalaRuntimeMode.native);
            }
            _aiDisplaySubtitle = '';
            if (!_windowsAiTextOnlyHeld) {
              _aiSubtitleUnavailable = false;
              _aiPreflightMessage =
                  'Playing normally while Orvix waits briefly for a native English subtitle track…';
            }
          });
        }
      } else {
        await _setNativeSubtitleVisibility(true);
      }

      if (aiPreferred &&
          useProgressiveNativeCueAi &&
          !aiReady &&
          mounted &&
          !_closing) {
        // Do not stop/reopen/pause/seek the media. Start normal playback now
        // and keep looking for native subtitle metadata in the background.
        unawaited(_discoverNativeCueAiAfterPlayback());
      } else if (aiPreferred &&
          widget.aiPreflightAttempted &&
          preprepared == null &&
          widget.aiPreflightFailure?.trim().isNotEmpty == true &&
          mounted &&
          !_closing) {
        // Standalone pre-player preparation failed. Do not re-run the old
        // player-driven play/pause/seek sampler on Windows: normal playback
        // starts once and the failure is surfaced as a non-fatal message.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.aiPreflightFailure!.trim()),
            duration: const Duration(seconds: 7),
          ),
        );
      }

      Duration? resume;
      if (widget.item != null && widget.mediaState != null) {
        resume = await widget.mediaState!.resumePosition(
          widget.item!,
          episode: widget.episode,
        );
        if (resume != null && resume > const Duration(seconds: 10)) {
          await widget.playback.player.seek(resume);
        }
      }

      if (!reopenedAfterAiFailure) {
        // AI startup opens the player paused. Whether Sinhala preparation
        // succeeds or falls back to native subtitles, playback must always be
        // released exactly once after that preparation attempt completes.
        unawaited(
          AiSinhalaTraceService.write(
            'player-play allowed aiReady=$aiReady '
            'audioAi=$_audioAiActive '
            'generated=${_generatedAiSubtitlePath != null}',
          ),
        );
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
          if (_aiState.mode != AiSinhalaRuntimeMode.native) {
            _transitionAi(AiSinhalaRuntimeMode.native);
          }
          _error = message;
        });
      }
    }
  }

  void _onPlaybackError(String message) {
    if (_closing ||
        _preflightWarmup ||
        _aiSubtitleLoading ||
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
      (track) =>
          _isRealSubtitleTrack(track) && !_isImageSubtitleTrack(track),
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

  mk.SubtitleTrack? _bestNativeEnglishBitmapTrack() {
    final tracks = widget.playback.player.state.tracks.subtitle
        .where(_isRealSubtitleTrack)
        .where(_isImageSubtitleTrack)
        .where(_isEnglishTrack)
        .toList(growable: false);
    if (tracks.isEmpty) return null;

    int score(mk.SubtitleTrack track) {
      final language = (track.language ?? '').toLowerCase();
      final title = (track.title ?? '').toLowerCase();
      var value = 0;
      if (language == 'eng' || language == 'en') value += 120;
      if (title == 'eng' || title.contains('english')) value += 110;
      if (title.contains('full')) value += 20;
      if (title.contains('forced')) value -= 120;
      if (title.contains('commentary')) value -= 160;
      return value;
    }

    tracks.sort((a, b) => score(b).compareTo(score(a)));
    return tracks.first;
  }

  mk.SubtitleTrack? _bestNativeEnglishTextTrack() {
    final tracks = widget.playback.player.state.tracks.subtitle
        .where(_isRealSubtitleTrack)
        .where((track) => !_isImageSubtitleTrack(track))
        .toList(growable: false);

    final english = tracks.where(_isEnglishTrack).toList(growable: false);
    if (english.isEmpty) {
      // A surprising number of MKV releases tag their real English text
      // subtitle as "und" (or leave both language/title blank). Do not reject
      // that source outright when it is the only unlabeled text track.
      final unknownText =
          tracks.where(_isUnlabeledTextTrack).toList(growable: false);
      if (unknownText.length == 1) return unknownText.first;
      return null;
    }

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

  Future<AiGeneratedSubtitleFile> _prepareRemoteDirectAiFallback() async {
    if (_localP2pStream || widget.item == null) {
      throw const AiSubtitleException(
        'Remote native-track calibration is not available for this source.',
      );
    }

    // Debrid/direct URLs do not pass through the Orvix exact-file
    // stream-server, so the local /subtitlesTracks extraction route cannot
    // expose their embedded subtitle file. The native player can still see the
    // embedded English track. Use a few real cues from that track only as an
    // oracle to identify + calibrate a full online transcript, then generate
    // one complete Sinhala SRT before playback.
    await _primeSubtitleTracksForAiPreflight();
    final nativeTrack = _bestNativeEnglishTextTrack();
    if (nativeTrack == null) {
      throw const AiSubtitleException(
        'This debrid/direct video did not expose an identifiable English text subtitle track.',
      );
    }

    if (mounted && !_closing) {
      setState(() {
        _aiPreflightMessage =
            'Exact OpenSubtitles match was unavailable. Reading a few cues from the video’s own English track…';
      });
    }

    final samples = await _captureNativeEnglishSamples();
    if (samples.length < 3) {
      throw const AiSubtitleException(
        'Could not read enough dialogue from the debrid video’s embedded English subtitle track.',
      );
    }

    if (mounted && !_closing) {
      setState(() {
        _aiPreflightMessage =
            'Matching the video’s own English cues to a full transcript…';
      });
    }

    final candidates = await OnlineSubtitleService.search(
      item: widget.item!,
      episode: widget.episode,
      releaseHint: widget.releaseHint,
      videoSize: widget.expectedSizeBytes,
      videoHash: widget.expectedVideoHash,
      preferredLanguage: 'eng',
      includeTranscriptFallbacks: true,
    );
    if (candidates.isEmpty) {
      throw const AiSubtitleException(
        'No English transcript candidates were available to match against the debrid video’s embedded subtitle.',
      );
    }

    final episodeIdentity = widget.episode == null
        ? 'movie'
        : 's${widget.episode!.season}e${widget.episode!.episode}';
    final videoIdentity = <Object?>[
      widget.item!.id,
      episodeIdentity,
      widget.releaseHint ?? '',
      widget.expectedSizeBytes ?? 0,
    ].join('|');

    return AiSinhalaSubtitleService.prepareGeneratedSinhalaFromNativeCalibration(
      title: widget.title,
      videoIdentity: videoIdentity,
      nativeSamples: samples,
      candidates: candidates,
      onStatus: (message) {
        if (!mounted || _closing) return;
        setState(() => _aiPreflightMessage = message);
      },
    );
  }

  Future<bool> _prepareAiSinhalaBeforePlayback() async {
    if (_closing) return false;
    final enabled = await AiSinhalaPreferencesService.isEnabled();
    if (!enabled || !mounted || _closing || _subtitleChoiceOverridden) {
      return false;
    }

    if (_aiState.mode == AiSinhalaRuntimeMode.native) {
      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.preparing);
      });
    }
    setState(() {
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage =
          'Finding the complete English subtitle embedded in this exact video…';
    });

    try {
      dynamic preferredTrack;
      for (var attempt = 0; attempt < 8 && mounted && !_closing; attempt++) {
        preferredTrack = _bestNativeEnglishTextTrack();
        if (preferredTrack != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      await _setNativeSubtitleVisibility(false);

      AiGeneratedSubtitleFile generated;
      try {
        generated = await AiSinhalaSubtitleService
            .prepareGeneratedSinhalaFromEmbeddedSubtitle(
          title: widget.title,
          videoUrl: widget.url,
          preferredTrackLabel: preferredTrack == null
              ? null
              : _subtitleTrackPreferenceLabel(preferredTrack),
          onStatus: (message) {
            if (!mounted || _closing) return;
            setState(() => _aiPreflightMessage = message);
          },
        );
      } on AiSubtitleException catch (error) {
        final reason = error.message.toLowerCase();
        final embeddedUnavailable =
            reason.contains('no readable embedded english text subtitle') ||
                reason.contains(
                  'embedded english subtitle could not be parsed safely',
                );
        if (!embeddedUnavailable || widget.item == null) rethrow;

        if (mounted && !_closing) {
          setState(() {
            _aiPreflightMessage =
                'No usable embedded English text track. Trying an exact video-file fingerprint match…';
          });
        }

        try {
          generated = await AiSinhalaSubtitleService.prepareGeneratedSinhalaFile(
            item: widget.item!,
            videoUrl: widget.url,
            episode: widget.episode,
            releaseHint: widget.releaseHint,
            expectedSizeBytes: widget.expectedSizeBytes,
            expectedVideoHash: widget.expectedVideoHash,
            onStatus: (message) {
              if (!mounted || _closing) return;
              setState(() => _aiPreflightMessage = message);
            },
          );
        } on AiSubtitleException {
          // Preserve the working local-P2P path exactly as-is. Only remote
          // direct/debrid media gets the native-track calibration fallback.
          // Local media-bridge sessions already gave us the exact debrid file.
          // If embedded extraction and exact hash matching both fail, stop
          // here and restore normal playback. Do not run the old play/pause/
          // seek cue-sampling fallback, which can destabilize cloud playback.
          if (_localP2pStream || _localMediaBridgeStream) rethrow;
          generated = await _prepareRemoteDirectAiFallback();
        }
      }

      if (!mounted || _closing || _subtitleChoiceOverridden) return false;

      _nativeSubtitleClockTimer?.cancel();
      _liveCueClearTimer?.cancel();
      _liveCueGeneration++;
      _preparedAiSubtitle = null;
      _generatedAiSubtitlePath = generated.path;
      _generatedAiSubtitleLabel = generated.label;
      _timingTrackSelected = false;
      _timingTrackIsText = false;
      _nativeAiMatchIndex = -1;

      setState(() {
        _transitionAi(AiSinhalaRuntimeMode.prepared);
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = generated.cacheHit
            ? 'Cached complete Sinhala subtitle ready • ${generated.label}'
            : 'Complete Sinhala subtitle ready • ${generated.label}';
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
        if (_aiState.mode != AiSinhalaRuntimeMode.native) {
          _transitionAi(AiSinhalaRuntimeMode.native);
        }
        _timingTrackSelected = false;
        _timingTrackIsText = false;
        _aiSubtitleUnavailable = true;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage = reason.isEmpty
            ? 'Complete embedded AI Sinhala could not be prepared.'
            : reason;
      });
      return false;
    }
  }

  Future<void> _loadGeneratedAiSubtitleTrack() async {
    final path = _generatedAiSubtitlePath;
    if (path == null || path.isEmpty || _closing) {
      throw const AiSubtitleException(
        'The prepared Sinhala subtitle file path was missing before player startup.',
      );
    }

    final file = File(path);
    if (!await file.exists() || await file.length() < 128) {
      throw const AiSubtitleException(
        'The prepared Sinhala subtitle file was missing or empty before player startup.',
      );
    }

    _nativeSubtitleClockTimer?.cancel();
    _liveCueClearTimer?.cancel();
    _liveCueGeneration++;
    _timingTrackSelected = false;
    _timingTrackIsText = false;
    _nativeAiMatchIndex = -1;

    final player = widget.playback.player;
    final subtitleUri = Platform.isWindows
        ? Uri.file(path, windows: true).toString()
        : Uri.file(path).toString();
    final subtitleTitle =
        'AI Sinhala • ${_generatedAiSubtitleLabel ?? 'embedded exact'}';
    final track = mk.SubtitleTrack.uri(
      subtitleUri,
      title: subtitleTitle,
      language: 'si',
    );

    if (mounted) {
      setState(() {
        _aiPreflightMessage =
            'Sinhala subtitle is ready. Attaching it to MPV before playback…';
      });
    }
    unawaited(
      AiSinhalaTraceService.write(
        'player-attach-start fileExists=true bytes=${await file.length()}',
      ),
    );

    Object? lastAttachError;
    var attached = false;

    // Wait for the newly opened media to publish at least basic metadata.
    // This is still fully paused. Attaching an external subtitle before this
    // point can be overwritten when libmpv finishes replacing the previous
    // file's track list.
    for (var attempt = 0; attempt < 30 && !_closing; attempt++) {
      final state = player.state;
      final hasAudio = state.tracks.audio
          .any((track) => track.id.toLowerCase() != 'no');
      final hasSubtitleMetadata = state.tracks.subtitle
          .any((track) => track.id.toLowerCase() != 'no');
      if (state.duration > Duration.zero || hasAudio || hasSubtitleMetadata) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // media_kit can resolve player.open() before libmpv has published its
    // initial track state. Older builds issued setSubtitleTrack exactly once
    // at that point and then started playback even when the external SRT had
    // not actually become the selected track. Keep the player paused and
    // retry until MPV itself confirms the Sinhala track is selected.
    for (var attempt = 0; attempt < 24 && !_closing; attempt++) {
      try {
        await player.setSubtitleTrack(track);
        await _setNativeSubtitleDelayProperty(0);
        await _setNativeSubtitleVisibility(true);
      } catch (error) {
        lastAttachError = error;
      }

      await Future<void>.delayed(
        Duration(milliseconds: attempt < 6 ? 120 : 220),
      );

      final selected = player.state.track.subtitle;
      final selectedId = selected.id.toLowerCase();
      final selectedTitle = (selected.title ?? '').toLowerCase();
      final selectedLanguage = (selected.language ?? '').toLowerCase();

      attached = selectedId != 'no' &&
          (selectedLanguage == 'si' ||
              selectedLanguage == 'sin' ||
              selectedTitle.contains('ai sinhala') ||
              selectedId.contains('orvix_si_'));
      if (attached) break;
    }

    if (!attached) {
      unawaited(
        AiSinhalaTraceService.write(
          'player-attach-failed error=${lastAttachError?.runtimeType ?? 'none'}',
        ),
      );
      throw AiSubtitleException(
        'MPV did not confirm the prepared Sinhala subtitle track before playback. '
        'Playback was kept paused instead of starting without Sinhala subtitles.',
      );
    }

    unawaited(
      AiSinhalaTraceService.write('player-attach-confirmed language=si'),
    );

    if (!mounted) return;
    setState(() {
      if (_aiState.mode != AiSinhalaRuntimeMode.prepared) {
        _transitionAi(AiSinhalaRuntimeMode.prepared);
      }
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage =
          'Sinhala subtitle attached and verified. Starting playback…';
    });
  }

  Future<void> _restoreNativeSubtitleFallback() async {
    await _removeAudioAiNativeTrack();
    _nativeSubtitleClockTimer?.cancel();
    _timingTrackSelected = false;
    _timingTrackIsText = false;
    _lastLiveCueKey = null;
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
    if (_isRealSubtitleTrack(current) &&
        (_isEnglishTrack(current) || _isUnlabeledTextTrack(current))) {
      await _setNativeSubtitleVisibility(true);
      await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
      return;
    }

    // Prefer an English track for the safe fallback. Keep retrying briefly
    // because network/P2P containers can publish track metadata asynchronously.
    for (var attempt = 0; attempt < 12 && mounted && !_closing; attempt++) {
      final tracks = player.state.tracks.subtitle
          .where(_isRealSubtitleTrack)
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
    if ((current.id ?? '').toString().trim().toLowerCase() != 'no') {
      await _setNativeSubtitleVisibility(true);
      await _setNativeSubtitleDelayProperty(_subtitleDelaySeconds);
    }
  }

  Future<bool> _enableEmbeddedLiveAiFallback(String reason) async {
    if (!mounted || _closing || _subtitleChoiceOverridden) return false;

    _liveTranslationFailures = 0;
    _liveCueGeneration++;
    _liveCueSequence = 0;
    _liveDisplayedSequence = 0;
    _lastLiveCueKey = null;
    _liveExactCues.clear();
    _liveExactInFlight.clear();
    _liveExactLateKeys.clear();
    _liveExactTraceCount = 0;
    _liveDialogueContext.clear();
    _liveExactSyncKey =
        'live-native-v1:${widget.title}:${_aiMediaSourceUrl.hashCode}:'
        '${widget.playback.player.state.track.subtitle.id}';

    final platform = widget.playback.player.platform;
    if (platform is mk.NativePlayer) {
      // Stop the old media_kit event stream BEFORE entering liveEmbedded mode.
      // Otherwise a cue can race through the legacy wall-clock translator in
      // the small async gap while the exact timeline is being initialized.
      await _subtitleTimingSubscription?.cancel();
      _subtitleTimingSubscription = null;
    }

    setState(() {
      _preparedAiSubtitle = null;
      _transitionAi(AiSinhalaRuntimeMode.liveEmbedded);
      _aiSubtitleUnavailable = false;
      _aiDisplaySubtitle = '';
      _aiPreflightMessage =
          'Buffering the video’s exact English subtitle timeline for Sinhala translation. $reason';
    });

    _positionSubscription ??=
        widget.playback.player.stream.position.listen(_onPosition);
    await _loadManualSync();

    if (platform is! mk.NativePlayer) {
      // Non-libmpv platforms retain the older event stream fallback.
      _subtitleTimingSubscription ??=
          widget.playback.player.stream.subtitle.listen(_onEmbeddedSubtitleCue);
    }

    // Advance the hidden native text track only to harvest future cues. Visible
    // Sinhala is NEVER scheduled by wall clock; it is rendered later from the
    // original ASS/SRT event start/end timestamps against the player's position.
    await _setNativeSubtitleVisibility(false);
    if (platform is mk.NativePlayer) {
      await _primeLiveExactLookahead();
    } else {
      await _setNativeSubtitleDelayProperty(-_liveAiLeadMs / 1000.0);
    }
    _startNativeSubtitleClock();
    if (platform is mk.NativePlayer) {
      unawaited(_pollLiveExactTextEvents());
    }
    return true;
  }

  Future<bool> _tryPrepareEmbeddedAiTiming() async {
    return _prepareAiSinhalaBeforePlayback();
  }

  Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled) async {
    await AiSinhalaPreferencesService.setEnabled(enabled);
    if (!mounted || _closing) return;
    setState(() => _aiPreferenceEnabled = enabled);

    if (!enabled) {
      await _removeAudioAiNativeTrack();
      _subtitleChoiceOverridden = false;
      _nativeSubtitleClockTimer?.cancel();
      _liveCueClearTimer?.cancel();
      await _subtitleTimingSubscription?.cancel();
      _subtitleTimingSubscription = null;
      _timingTrackSelected = false;
      _timingTrackIsText = false;
      _nativeAiMatchIndex = -1;
      _lastAiPrefetchBucket = -1;
      _lastLiveCueKey = null;
      _liveCueGeneration++;
      _liveExactCues.clear();
      _liveExactInFlight.clear();
      _liveExactLateKeys.clear();
      _liveDialogueContext.clear();
      _liveExactTraceCount = 0;
      _liveExactSyncKey = null;
      _windowsAiTextOnlyHeld = false;
      _preparedAiSubtitle = null;
      _generatedAiSubtitlePath = null;
      _generatedAiSubtitleLabel = null;
      _audioAiActive = false;
      _audioAiWindowWorks.clear();
      _audioAiWindowStarts.clear();
      _audioAiCoverageEndMs = 0;
      _audioAiNativeAttached = false;
      _audioAiBitmapTimingMode = false;
      _audioAiBitmapLastCueIndex = -1;
      _audioAiBitmapClearTimer?.cancel();
      _audioAiBitmapClearTimer = null;
      final audioSrt = _audioAiSrtFile;
      _audioAiSrtFile = null;
      if (audioSrt != null) {
        try {
          if (await audioSrt.exists()) await audioSrt.delete();
        } catch (_) {}
      }
      setState(() {
        if (_aiState.mode != AiSinhalaRuntimeMode.native) {
          _transitionAi(AiSinhalaRuntimeMode.native);
        }
        _aiDisplaySubtitle = '';
        _aiSubtitleUnavailable = false;
        _aiPreflightMessage = '';
      });
      await _restoreNativeSubtitleFallback();
      return;
    }

    // Enabling AI in an already-open player must use the same non-blocking
    // architecture as automatic startup. Never pause a movie for a full-file
    // translation: detect the active player's exact English text track and
    // translate its cues progressively while playback continues.
    _subtitleChoiceOverridden = false;
    _generatedAiSubtitlePath = null;
    _generatedAiSubtitleLabel = null;
    _preparedAiSubtitle = null;

    if (mounted) {
      setState(() {
        if (_aiState.mode != AiSinhalaRuntimeMode.native) {
          _transitionAi(AiSinhalaRuntimeMode.native);
        }
        _aiSubtitleUnavailable = false;
        _aiDisplaySubtitle = '';
        _aiPreflightMessage =
            'Detecting the active player’s native English subtitle track…';
      });
    }

    await _setNativeSubtitleVisibility(true);
    final activated = await _activateProgressiveNativeCueAi(
      maxWait: const Duration(milliseconds: 1200),
      phase: 'toggle',
    );

    if (!activated && mounted && !_closing) {
      setState(() {
        _aiDisplaySubtitle = '';
        if (!_windowsAiTextOnlyHeld) {
          _aiSubtitleUnavailable = false;
          _aiPreflightMessage =
              'Playing normally while Orvix waits for a native English subtitle track…';
        }
      });
      unawaited(_discoverNativeCueAiAfterPlayback());
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

    // Complete-file and rolling audio AI Sinhala both use native SRT tracks.
    // libmpv owns seek/timing for them; never hide the renderer after a jump.
    if (_generatedAiSubtitlePath != null) {
      unawaited(_setNativeSubtitleVisibility(true));
      return;
    }
    if (_audioAiActive && _audioAiNativeAttached) {
      unawaited(_setNativeSubtitleVisibility(true));
      _ensureAudioAiAhead(target);
      return;
    }
    if (_liveAiFallback) {
      _lastNativeSubtitleStartMs = null;
      _lastLiveCueKey = null;
      _liveExactLateKeys.clear();
      _refreshLiveExactSubtitle(target);
      unawaited(_pollLiveExactTextEvents());
      return;
    }

    _lastNativeSubtitleStartMs = null;
    _lastAiPrefetchBucket = -1;
    _nativeAiMatchIndex = -1;
    _lastLiveCueKey = null;
    _liveCueGeneration++;
    _liveCueClearTimer?.cancel();
    _liveCueClearTimer = null;
    unawaited(_setNativeSubtitleVisibility(false));

    if (mounted && _aiDisplaySubtitle.isNotEmpty) {
      setState(() => _aiDisplaySubtitle = '');
    }

    if (_audioAiActive && _preparedAiSubtitle != null) {
      _onPosition(target);
      _ensureAudioAiAhead(target);
    } else if (_aiSinhalaEnabled &&
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
    _liveExactCues.clear();
    _liveExactInFlight.clear();
    _liveExactLateKeys.clear();
    _liveDialogueContext.clear();

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
    final audioSrt = _audioAiSrtFile;
    _audioAiSrtFile = null;
    _audioAiNativeAttached = false;
    if (audioSrt != null) {
      try {
        if (await audioSrt.exists()) await audioSrt.delete();
      } catch (_) {}
    }
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

  Future<void> _applyActiveAiSubtitleDelay() async {
    if (_liveAiFallback) {
      // Manual sync belongs to visible Sinhala timing, not to the hidden
      // look-ahead track used only for harvesting future English cues.
      await _setNativeSubtitleDelayProperty(-_liveAiLeadMs / 1000.0);
      return;
    }
    if (_audioAiBitmapTimingMode) {
      await _setNativeSubtitleDelayProperty(_manualSyncOffsetMs / 1000.0);
      return;
    }
    if (_audioAiNativeAttached) {
      await _setNativeSubtitleDelayProperty(_effectiveSyncOffsetMs / 1000.0);
    }
  }

  String? get _activeAiSyncKey =>
      _preparedAiSubtitle?.key ?? (_liveAiFallback ? _liveExactSyncKey : null);

  Future<void> _loadManualSync() async {
    final key = _activeAiSyncKey;
    if (key == null) return;
    final value = await AiSinhalaPreferencesService.syncOffsetMs(key);
    if (!mounted) return;
    setState(() => _manualSyncOffsetMs = value);
    _refreshAiSubtitle();
  }

  Future<void> _adjustManualSync(int deltaMs) async {
    final key = _activeAiSyncKey;
    if (key == null) return;
    final next = (_manualSyncOffsetMs + deltaMs).clamp(-120000, 120000).toInt();
    if (mounted) setState(() => _manualSyncOffsetMs = next);
    await AiSinhalaPreferencesService.setSyncOffsetMs(key, next);
    await _applyActiveAiSubtitleDelay();
    _refreshAiSubtitle();
  }

  Future<void> _resetManualSync() async {
    final key = _activeAiSyncKey;
    if (key == null) return;
    if (mounted) setState(() => _manualSyncOffsetMs = 0);
    await AiSinhalaPreferencesService.setSyncOffsetMs(key, 0);
    await _applyActiveAiSubtitleDelay();
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
    if (!_aiSinhalaEnabled || !mounted) {
      return;
    }
    if (_liveAiFallback) {
      _refreshLiveExactSubtitle(position);
      return;
    }

    final prepared = _preparedAiSubtitle;
    if (prepared == null) {
      return;
    }

    if (_audioAiActive) {
      var adjustedMs = position.inMilliseconds - _effectiveSyncOffsetMs;
      if (adjustedMs < 0) adjustedMs = 0;
      final adjusted = Duration(milliseconds: adjustedMs);
      if (_audioAiBitmapTimingMode) {
        // Exact PGS/VobSub cue events own visible timing. Position only keeps
        // the slow STT workers ahead of playback.
        _ensureAudioAiAhead(position);
        return;
      }
      if (_audioAiNativeAttached) {
        // Native SRT owns display timing. Position is now only the prefetch
        // clock; this removes the Flutter overlay from the critical path.
        _ensureAudioAiAhead(adjusted);
        return;
      }
      final next = prepared.subtitleAt(adjusted);
      if (next != _aiDisplaySubtitle) {
        setState(() => _aiDisplaySubtitle = next);
      }
      _ensureAudioAiAhead(adjusted);
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
      if (_isRealSubtitleTrack(current) && _isEnglishTrack(current)) {
        chosen = current;
      } else {
        final allTracks = player.state.tracks.subtitle
            .where(_isRealSubtitleTrack)
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

  bool _isRealSubtitleTrack(dynamic track) {
    final id = (track.id ?? '').toString().trim().toLowerCase();
    // media_kit always injects pseudo tracks named "auto" and "no". They are
    // selectors, not actual subtitle streams, and therefore have no language,
    // codec or title metadata. Treating "auto" as the one unlabeled text track
    // caused beta.30 to report AI-ready without ever receiving a subtitle cue.
    return id.isNotEmpty && id != 'auto' && id != 'no';
  }

  String _liveExactCueKey(
    Duration start,
    Duration end,
    String text,
  ) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${start.inMilliseconds}|${end.inMilliseconds}|$normalized';
  }

  void _queueLiveExactEvents(String raw) {
    if (raw.trim().isEmpty) return;
    final events = NativeSubtitleEventParser.parseAssFull(raw);
    for (final event in events) {
      final key = _liveExactCueKey(event.start, event.end, event.text);
      if (_liveExactCues.containsKey(key) || !_liveExactInFlight.add(key)) {
        continue;
      }
      unawaited(_translateLiveExactEvent(key, event));
    }
  }

  Future<void> _primeLiveExactLookahead() async {
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer ||
        !_liveAiFallback ||
        !_timingTrackSelected ||
        !_timingTrackIsText ||
        _closing) {
      return;
    }

    // The bundled Windows libmpv (2024-10-21) supports sub-text/ass-full but
    // predates the newer sub-lines property. To avoid losing subtitles in the
    // first look-ahead window, sample the hidden track across 0..6 seconds
    // while startup is still paused, then leave it at the normal 6 s lead.
    //
    // 250 ms spacing is intentionally smaller than a normal subtitle cue and
    // keeps this bounded to 25 cheap property reads; no media re-open/seek or
    // full-file scan is involved.
    for (var offsetMs = 0;
        offsetMs <= _liveAiLeadMs && !_closing;
        offsetMs += 250) {
      try {
        await _setNativeSubtitleDelayProperty(-offsetMs / 1000.0);
        final raw = await platform.getProperty(
          'sub-text/ass-full',
          waitForInitialization: false,
        );
        _queueLiveExactEvents(raw);
      } catch (_) {
        // A point sample can legitimately have no active subtitle.
      }
    }
    await _setNativeSubtitleDelayProperty(-_liveAiLeadMs / 1000.0);
    unawaited(
      AiSinhalaTraceService.write(
        'live-exact-prime leadMs=$_liveAiLeadMs '
        'queued=${_liveExactCues.length + _liveExactInFlight.length}',
      ),
    );
  }

  Future<void> _pollLiveExactTextEvents() async {
    if (!_liveAiFallback ||
        !_timingTrackSelected ||
        !_timingTrackIsText ||
        !mounted ||
        _closing) {
      return;
    }
    final platform = widget.playback.player.platform;
    if (platform is! mk.NativePlayer) return;

    String raw;
    try {
      raw = await platform.getProperty(
        'sub-text/ass-full',
        waitForInitialization: false,
      );
    } catch (_) {
      return;
    }
    _queueLiveExactEvents(raw);
  }

  Future<void> _translateLiveExactEvent(
    String key,
    NativeSubtitleEvent event,
  ) async {
    final generation = _liveCueGeneration;
    final priorCues = _liveExactCues.values
        .where((cue) => cue.start < event.start)
        .toList(growable: false)
      ..sort((a, b) => a.start.compareTo(b.start));
    final context = priorCues
        .skip(priorCues.length > 6 ? priorCues.length - 6 : 0)
        .map((cue) => cue.source)
        .toList(growable: false);
    try {
      final translation = await AiSinhalaSubtitleService.translateCue(
        title: widget.title,
        text: event.text,
        context: context,
      );
      if (!mounted ||
          _closing ||
          !_liveAiFallback ||
          generation != _liveCueGeneration) {
        return;
      }

      _liveExactCues[key] = AiSubtitleCue(
        start: event.start,
        end: event.end,
        source: event.text,
        translation: translation,
      );

      final currentLookupMs =
          widget.playback.player.state.position.inMilliseconds -
              _manualSyncOffsetMs;
      if (currentLookupMs > event.start.inMilliseconds + 300 &&
          currentLookupMs < event.end.inMilliseconds) {
        _liveExactLateKeys.add(key);
        if (_liveExactTraceCount < 20) {
          _liveExactTraceCount++;
          unawaited(
            AiSinhalaTraceService.write(
              'live-exact-late-skip index=$_liveExactTraceCount '
              'startMs=${event.start.inMilliseconds} '
              'currentMs=$currentLookupMs',
            ),
          );
        }
      }

      // Bound memory for long movies while keeping enough history for short
      // backward seeks.
      final cutoff = widget.playback.player.state.position -
          const Duration(minutes: 3);
      if (_liveExactCues.length > 240) {
        _liveExactCues.removeWhere((_, cue) => cue.end < cutoff);
      }

      if (_liveExactTraceCount < 20) {
        _liveExactTraceCount++;
        unawaited(
          AiSinhalaTraceService.write(
            'live-exact-ready index=$_liveExactTraceCount '
            'startMs=${event.start.inMilliseconds} '
            'endMs=${event.end.inMilliseconds} '
            'chars=${event.text.length}',
          ),
        );
      }
      _refreshLiveExactSubtitle(
        widget.playback.player.state.position,
      );
    } catch (error) {
      if (_liveExactTraceCount < 20) {
        _liveExactTraceCount++;
        unawaited(
          AiSinhalaTraceService.write(
            'live-exact-error index=$_liveExactTraceCount '
            'startMs=${event.start.inMilliseconds} '
            'type=${error.runtimeType}',
          ),
        );
      }
    } finally {
      _liveExactInFlight.remove(key);
    }
  }

  void _refreshLiveExactSubtitle(Duration position) {
    if (!_liveAiFallback || !mounted || _closing) return;
    var lookupMs = position.inMilliseconds - _manualSyncOffsetMs;
    if (lookupMs < 0) lookupMs = 0;

    final active = _liveExactCues.entries
        .where(
          (entry) =>
              !_liveExactLateKeys.contains(entry.key) &&
              entry.value.start.inMilliseconds <= lookupMs &&
              entry.value.end.inMilliseconds > lookupMs &&
              entry.value.translation?.trim().isNotEmpty == true,
        )
        .map((entry) => entry.value)
        .toList(growable: false)
      ..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        if (byStart != 0) return byStart;
        return a.end.compareTo(b.end);
      });

    final lines = <String>[];
    final seen = <String>{};
    for (final cue in active) {
      final translated = cue.translation!.trim();
      if (seen.add(translated)) lines.add(translated);
    }
    final next = lines.join('\n');
    if (next != _aiDisplaySubtitle) {
      setState(() => _aiDisplaySubtitle = next);
    }
  }

  bool _looksLikeEnglishNativeCue(String raw) {
    final text = raw
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\{\\[^}]+\}'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return false;

    final words = RegExp(r"[A-Za-z][A-Za-z'’\-]*")
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((word) => word.length > 1)
        .toList(growable: false);
    if (words.length < 2) return false;

    final letters = RegExp(r'[A-Za-z]').allMatches(text).length;
    final otherLetters =
        RegExp(r'[\u0080-\uFFFF]').allMatches(text).length;
    return letters >= 4 && letters >= otherLetters * 2;
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
      _isRealSubtitleTrack(track) &&
      _isEnglishTrack(track) &&
      !_isImageSubtitleTrack(track);

  bool _isUnlabeledTextTrack(dynamic track) {
    if (!_isRealSubtitleTrack(track) || _isImageSubtitleTrack(track)) {
      return false;
    }
    final language =
        (track.language ?? '').toString().trim().toLowerCase();
    final title = (track.title ?? '').toString().trim().toLowerCase();
    final unknownLanguage = language.isEmpty ||
        language == 'und' ||
        language == 'unknown' ||
        language == 'undefined';
    final genericTitle = title.isEmpty ||
        title == 'default' ||
        title == 'subtitle' ||
        title == 'subtitles' ||
        title == 'full';
    return unknownLanguage && genericTitle;
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

    if (_timingTrackIsText && _liveAiFallback && Platform.isWindows) {
      // Poll the full ASS event representation instead of the flattened
      // sub-text string. MPV can have multiple overlapping subtitle events;
      // sub-text concatenates them and sub-start/sub-end only expose the
      // first/last aggregate timestamps, which caused beta.39's "editing"
      // effect and incorrect cue durations.
      await _pollLiveExactTextEvents();
      return;
    }

    final startMs = await _nativeSubtitleStartMs();
    if (startMs == null || !mounted) return;
    final previous = _lastNativeSubtitleStartMs;
    if (previous != null && (startMs - previous).abs() < 40) return;
    _lastNativeSubtitleStartMs = startMs;
    if (_timingTrackIsText) {
      final platform = widget.playback.player.platform;
      if (platform is mk.NativePlayer) {
        try {
          final text = (await platform.getProperty(
            'sub-text',
            waitForInitialization: false,
          ))
              .trim();
          if (text.isNotEmpty && mounted) {
            unawaited(_handleEmbeddedSubtitleCue(<String>[text]));
          }
        } catch (_) {}
      }
    } else {
      if (_audioAiActive && _audioAiBitmapTimingMode) {
        await _displayAudioAiAtBitmapTiming(startMs);
      } else {
        _voteBitmapTiming(startMs);
      }
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
    unawaited(_applyActiveAiSubtitleDelay());
    _refreshAiSubtitle();
  }

  Future<void> _displayAudioAiAtBitmapTiming(int sourceStartMs) async {
    final prepared = _preparedAiSubtitle;
    if (!_audioAiActive ||
        !_audioAiBitmapTimingMode ||
        prepared == null ||
        prepared.cues.isEmpty ||
        !mounted ||
        _closing) {
      return;
    }

    final expectedAiMs = sourceStartMs - _autoSyncOffsetMs;
    final searchStart = (_audioAiBitmapLastCueIndex + 1)
        .clamp(0, prepared.cues.length - 1)
        .toInt();
    final searchEnd =
        (searchStart + 10).clamp(0, prepared.cues.length).toInt();

    var bestIndex = -1;
    var bestDelta = 1 << 30;
    for (var i = searchStart; i < searchEnd; i++) {
      final cue = prepared.cues[i];
      final translation = cue.translation?.trim() ?? '';
      if (translation.isEmpty) continue;
      final delta = (cue.start.inMilliseconds - expectedAiMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }

    // Bitmap subtitles may contain SDH/sign cues that audio STT deliberately
    // omits. Never steal a distant dialogue line merely to fill every bitmap
    // event; blank is preferable to visibly wrong sync.
    if (bestIndex < 0 || bestDelta > 5000) {
      _audioAiBitmapClearTimer?.cancel();
      _audioAiBitmapClearTimer = null;
      if (_aiDisplaySubtitle.isNotEmpty && mounted) {
        setState(() => _aiDisplaySubtitle = '');
      }
      if (bestIndex < 0 || _audioAiBitmapLastCueIndex < 10) {
        unawaited(
          AiSinhalaTraceService.write(
            'audio-ai-bitmap-miss sourceStartMs=$sourceStartMs '
            'expectedAiMs=$expectedAiMs nearestDeltaMs=$bestDelta',
          ),
        );
      }
      return;
    }

    final cue = prepared.cues[bestIndex];
    _audioAiBitmapLastCueIndex = bestIndex;
    final sample = sourceStartMs - cue.start.inMilliseconds;
    _acceptAutoSyncSample(sample);

    final sourceEndMs = await _nativeSubtitleEndMs();
    var durationMs = sourceEndMs == null ? 0 : sourceEndMs - sourceStartMs;
    if (durationMs < 650 || durationMs > 12000) {
      durationMs = (cue.end.inMilliseconds - cue.start.inMilliseconds)
          .clamp(900, 6500)
          .toInt();
    }

    final translation = cue.translation?.trim() ?? '';
    if (translation.isEmpty || !mounted || _closing) return;

    _audioAiBitmapClearTimer?.cancel();
    if (_aiDisplaySubtitle != translation) {
      setState(() => _aiDisplaySubtitle = translation);
    }
    _audioAiBitmapClearTimer = Timer(
      Duration(milliseconds: durationMs),
      () {
        _audioAiBitmapClearTimer = null;
        if (!mounted || _closing || !_audioAiBitmapTimingMode) return;
        if (_aiDisplaySubtitle == translation) {
          setState(() => _aiDisplaySubtitle = '');
        }
      },
    );

    if (bestIndex < 12) {
      unawaited(
        AiSinhalaTraceService.write(
          'audio-ai-bitmap-sync sourceStartMs=$sourceStartMs '
          'cueStartMs=${cue.start.inMilliseconds} deltaMs=$sample '
          'durationMs=$durationMs index=$bestIndex',
        ),
      );
    }
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
      if (_liveAiFallback) {
        // In lead-buffered live mode MPV's hidden English cue also ends early.
        // Sinhala owns its own authored-duration timer, so an early empty event
        // must not clear the translated cue.
        return;
      }
      _liveCueGeneration++;
      if (_aiDisplaySubtitle.isNotEmpty && mounted) {
        setState(() => _aiDisplaySubtitle = '');
      }
      return;
    }

    if (_liveAiFallback) {
      final nativeStartMs = await _nativeSubtitleStartMs();
      final nativeEndMs = await _nativeSubtitleEndMs();
      final fallbackPositionMs =
          widget.playback.player.state.position.inMilliseconds;
      final dedupClockMs =
          nativeStartMs ?? ((fallbackPositionMs ~/ 250) * 250);
      final normalized = source
          .toLowerCase()
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final cueKey = '$dedupClockMs|$normalized';
      if (_lastLiveCueKey == cueKey) {
        if (_liveCueTraceCount < 8) {
          unawaited(
            AiSinhalaTraceService.write(
              'live-cue-duplicate startMs=$dedupClockMs chars=${source.length}',
            ),
          );
        }
        return;
      }
      _lastLiveCueKey = cueKey;
      await _translateLiveSubtitleCue(
        source,
        cueStartMs: nativeStartMs,
        cueEndMs: nativeEndMs,
      );
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

  Future<void> _translateLiveSubtitleCue(
    String source, {
    int? cueStartMs,
    int? cueEndMs,
  }) async {
    final modeGeneration = _liveCueGeneration;
    final sequence = ++_liveCueSequence;
    final requestStartedAt = DateTime.now();
    final traceCue = _liveCueTraceCount < 8;
    if (traceCue) {
      _liveCueTraceCount++;
      unawaited(
        AiSinhalaTraceService.write(
          'live-cue-start index=$_liveCueTraceCount seq=$sequence chars=${source.length}',
        ),
      );
    }

    final estimatedDurationMs =
        (1200 + source.length * 42).clamp(1600, 5200).toInt();
    var cueDurationMs = (cueStartMs != null && cueEndMs != null)
        ? cueEndMs - cueStartMs
        : estimatedDurationMs;
    if (cueDurationMs < 700 || cueDurationMs > 10000) {
      cueDurationMs = estimatedDurationMs;
    }

    try {
      final translation = await AiSinhalaSubtitleService.translateCue(
        title: widget.title,
        text: source,
        context: _liveDialogueContext,
      );
      if (!mounted ||
          !_liveAiFallback ||
          modeGeneration != _liveCueGeneration ||
          _closing) {
        return;
      }

      final elapsedMs =
          DateTime.now().difference(requestStartedAt).inMilliseconds;
      final waitMs = _liveAiLeadMs - elapsedMs;
      if (waitMs < -300) {
        if (traceCue) {
          unawaited(
            AiSinhalaTraceService.write(
              'live-cue-late index=$_liveCueTraceCount seq=$sequence '
              'elapsedMs=$elapsedMs leadMs=$_liveAiLeadMs',
            ),
          );
        }
        await _registerLiveTranslationFailure('translation arrived too late');
        return;
      }

      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
      if (!mounted ||
          !_liveAiFallback ||
          modeGeneration != _liveCueGeneration ||
          _closing ||
          sequence <= _liveDisplayedSequence) {
        return;
      }

      _liveTranslationFailures = 0;
      _liveDisplayedSequence = sequence;
      _liveCueClearTimer?.cancel();
      await _setNativeSubtitleVisibility(false);
      if (!mounted || !_liveAiFallback) return;
      setState(() => _aiDisplaySubtitle = translation);

      _liveDialogueContext.add(source);
      if (_liveDialogueContext.length > 6) {
        _liveDialogueContext.removeAt(0);
      }

      if (traceCue) {
        unawaited(
          AiSinhalaTraceService.write(
            'live-cue-ok index=$_liveCueTraceCount seq=$sequence '
            'elapsedMs=$elapsedMs bufferedMs=${waitMs > 0 ? waitMs : 0} '
            'durationMs=$cueDurationMs translatedChars=${translation.length}',
          ),
        );
      }

      _liveCueClearTimer = Timer(
        Duration(milliseconds: cueDurationMs.clamp(700, 8000)),
        () {
          _liveCueClearTimer = null;
          if (!mounted ||
              !_liveAiFallback ||
              modeGeneration != _liveCueGeneration ||
              _liveDisplayedSequence != sequence) {
            return;
          }
          setState(() => _aiDisplaySubtitle = '');
        },
      );
    } catch (error) {
      if (traceCue) {
        unawaited(
          AiSinhalaTraceService.write(
            'live-cue-error index=$_liveCueTraceCount seq=$sequence '
            'type=${error.runtimeType}',
          ),
        );
      }
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
                  if (widget.allowAiSinhala) ...[
                    _AiSinhalaSwitchTile(
                      value: _aiPreferenceEnabled,
                      busy: _aiSubtitleLoading,
                      detail: _aiSubtitleLoading
                          ? 'Preparing AI Sinhala from the source’s English subtitle track…'
                          : _aiSinhalaEnabled
                              ? (_generatedAiSubtitlePath != null
                                  ? 'On • complete Sinhala SRT loaded with original timing'
                                  : _liveAiFallback
                                      ? 'On • translating exact native English subtitle events'
                                      : 'On • AI Sinhala subtitles active')
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
                  if (_aiSinhalaEnabled &&
                      _generatedAiSubtitlePath != null) ...[
                    const _EmptyTrackMessage(
                      'Complete Sinhala subtitle loaded as a native SRT track. '
                      'Its timestamps come directly from the embedded English subtitle.',
                    ),
                    const SizedBox(height: 12),
                  ] else if (_aiSinhalaEnabled) ...[
                    _subtitleAppearanceControls(setSheetState),
                    const SizedBox(height: 12),
                  ] else ...[
                    const _EmptyTrackMessage(
                      'Source subtitle appearance is preserved by the native player.',
                    ),
                    const SizedBox(height: 12),
                    _subtitleSyncControls(setSheetState),
                    const SizedBox(height: 12),
                  ],
                  if (_aiSubtitleLoading)
                    const _EmptyTrackMessage(
                      'AI Sinhala is preparing the first reliable subtitle buffer. Playback resumes as soon as that startup check finishes.',
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
                  if (_aiSinhalaEnabled &&
                      (_preparedAiSubtitle != null || _liveAiFallback)) ...[
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
                            _liveAiFallback
                                ? 'Timing comes from the exact native English subtitle event timestamps. Adjust only if this release itself has an offset.'
                                : _autoSyncSamples.isNotEmpty
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
                if (_error == null &&
                    !_aiSubtitleLoading &&
                    !_playbackStarted)
                  PlayerLoadingOverlay(
                    item: widget.item,
                    title: widget.title,
                    message: 'Starting playback…',
                    detail: widget.episode == null
                        ? 'Opening the selected stream…'
                        : widget.title,
                  ),
                if (_error == null &&
                    !_aiSubtitleLoading &&
                    _playbackStarted)
                  StreamBuilder<bool>(
                    stream: player.stream.buffering,
                    initialData: player.state.buffering,
                    builder: (context, snapshot) {
                      if (snapshot.data != true) {
                        return const SizedBox.shrink();
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
                if (_error == null && _aiSubtitleLoading)
                  PlayerLoadingOverlay(
                    item: widget.item,
                    title: widget.title,
                    message: 'Preparing AI Sinhala',
                    detail: _aiPreflightMessage.trim().isEmpty
                        ? 'Detecting the source’s native English subtitle track…'
                        : _aiPreflightMessage,
                  ),
                if (_aiSinhalaEnabled &&
                    !_audioAiNativeAttached &&
                    _aiDisplaySubtitle.isNotEmpty)
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
