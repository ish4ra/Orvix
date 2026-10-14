import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/exo_playback_diagnostics.dart';
import '../services/exo_player_preferences_service.dart';
import '../services/external_subtitle_track.dart';
import '../services/subtitle_text_cleanup.dart';
import '../services/local_p2p_startup_policy.dart';
import '../services/local_torrent_service.dart';
import '../services/media_state_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/orvix_exo_player.dart';
import '../services/platform_profile.dart';
import '../services/player_orientation_controller.dart';
import '../services/skip_segment_service.dart';
import '../services/subtitle_file_picker.dart';
import '../services/subtitle_preferences_service.dart';
import '../widgets/exo_subtitle_view.dart';
import '../widgets/player_loading_overlay.dart';

export '../services/exo_player_preferences_service.dart' show ExoAspectMode;

class AndroidExoPlayerResult {
  const AndroidExoPlayerResult({
    this.failed = false,
    this.switchToMpv = false,
    this.started = false,
    this.playNext = false,
    this.error,
  });

  final bool failed;
  final bool switchToMpv;
  final bool started;

  /// The user asked for the next episode from the player.
  final bool playNext;
  final String? error;
}

/// Orvix palette for the ExoPlayer screen.
class ExoPlayerColors {
  ExoPlayerColors._();

  static const lime = Color(0xFFB9FF45);
  static const lightLime = Color(0xFFCBFF75);
  static const background = Color(0xFF050806);
  static const canvas = Color(0xFF070A08);
  static const surface = Color(0xFF0B0F0C);
  static const card = Color(0xFF0D120E);
  static const text = Color(0xFFF2F5F1);
  static const muted = Color(0xFF9AA39C);
}

extension ExoAspectModeLabel on ExoAspectMode {
  String get label => switch (this) {
        ExoAspectMode.fit => 'Fit',
        ExoAspectMode.fill => 'Fill',
        ExoAspectMode.zoom => 'Zoom',
      };

  /// Fit shows the whole picture; Fill covers the screen and crops the
  /// overflow; Zoom enlarges the fitted picture. None of them stretch.
  BoxFit get fit => switch (this) {
        ExoAspectMode.fit => BoxFit.contain,
        ExoAspectMode.fill => BoxFit.cover,
        ExoAspectMode.zoom => BoxFit.contain,
      };
}

/// Where the picture lands in [box] for a video of [videoAspect] in [mode].
/// Shared by the video layer and the image-subtitle layer so both agree.
@visibleForTesting
Rect exoVideoRect(
  Size box,
  double videoAspect,
  ExoAspectMode mode, {
  double zoom = 1.0,
}) {
  if (box.isEmpty || videoAspect <= 0 || !videoAspect.isFinite) {
    return Offset.zero & box;
  }
  final boxAspect = box.width / box.height;
  final cover = mode == ExoAspectMode.fill;
  final widthBound = cover ? videoAspect < boxAspect : videoAspect >= boxAspect;
  var width = widthBound ? box.width : box.height * videoAspect;
  var height = widthBound ? box.width / videoAspect : box.height;
  if (mode == ExoAspectMode.zoom) {
    width *= zoom;
    height *= zoom;
  }
  return Rect.fromLTWH(
    (box.width - width) / 2,
    (box.height - height) / 2,
    width,
    height,
  );
}

enum _ExoPanel {
  none,
  subtitles,
  onlineSubtitles,
  subtitleStyle,
  audio,
  speed,
  settings,
  info,
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
    this.onStartupStage,
    this.nextEpisodeLabel,
    this.releaseHint,
    this.expectedSizeBytes,
    this.expectedVideoHash,
  });

  /// Answers whether the local torrent engine is alive. Tests replace it.
  @visibleForTesting
  static Future<bool> Function() debugEngineAnswering =
      LocalTorrentService.instance.engineAnswering;

  /// Searches OpenSubtitles. Tests replace it.
  @visibleForTesting
  static Future<List<OnlineSubtitleResult>> Function({
    required MediaItem item,
    EpisodeItem? episode,
    String? releaseHint,
    int? videoSize,
    String? videoHash,
    String preferredLanguage,
  }) debugSearchSubtitles = OnlineSubtitleService.search;

  /// Downloads one OpenSubtitles result as text. Tests replace it.
  @visibleForTesting
  static Future<String> Function(OnlineSubtitleResult result)
      debugDownloadSubtitle = _downloadSubtitle;

  /// Replaces SystemChrome orientation/system-UI calls in tests.
  @visibleForTesting
  static PlayerOrientationController Function(bool isTv)?
      debugOrientationController;

  static Future<String> _downloadSubtitle(OnlineSubtitleResult result) async {
    final file = await OnlineSubtitleService.materialize(result);
    return decodeSubtitleBytes(await file.readAsBytes());
  }

  /// Subtitle files are often Windows-1252 rather than UTF-8, and some are
  /// UTF-16. See [SubtitleTextCleanup.decode].
  @visibleForTesting
  static String decodeSubtitleBytes(List<int> bytes) =>
      SubtitleTextCleanup.decode(bytes);

  /// No timer ends a stream that Media3 is still loading. These only change
  /// the wording of the loading screen.
  static const slowRemoteNoticeAfter = Duration(seconds: 20);
  static const slowBufferNoticeAfter = Duration(seconds: 8);

  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final Map<String, String>? httpHeaders;

  /// Close with [AndroidExoPlayerResult.switchToMpv] on a failure before the
  /// first frame. Orvix's own routes no longer use it (the error screen
  /// offers MPV as an explicit choice); kept for callers that ask for it.
  final bool autoFallbackToMpv;

  /// Privacy-safe startup stages for the Free P2P playback trace.
  final void Function(String stage, String result, Map<String, Object?> detail)?
      onStartupStage;

  /// When set, the player offers the next episode.
  final String? nextEpisodeLabel;
  final String? releaseHint;
  final int? expectedSizeBytes;
  final String? expectedVideoHash;

  @override
  State<AndroidExoPlayerScreen> createState() => _AndroidExoPlayerScreenState();
}

class _AndroidExoPlayerScreenState extends State<AndroidExoPlayerScreen>
    with WidgetsBindingObserver {
  // The full-screen video surface takes focus only when asked (controls
  // hidden). As a traversal candidate its centre could win a DPAD move on a
  // wide screen, and focus would vanish from the controls.
  final FocusNode _surfaceFocus =
      FocusNode(debugLabel: 'exo-surface', skipTraversal: true);
  final FocusNode _backFocus = FocusNode(debugLabel: 'exo-back');
  final FocusNode _timelineFocus = FocusNode(debugLabel: 'exo-timeline');
  final FocusNode _rewindFocus = FocusNode(debugLabel: 'exo-rewind');
  final FocusNode _playFocus = FocusNode(debugLabel: 'exo-play');
  final FocusNode _forwardFocus = FocusNode(debugLabel: 'exo-forward');
  final FocusNode _subtitlesFocus = FocusNode(debugLabel: 'exo-subtitles');
  final FocusNode _audioFocus = FocusNode(debugLabel: 'exo-audio');
  final FocusNode _speedFocus = FocusNode(debugLabel: 'exo-speed');
  final FocusNode _aspectFocus = FocusNode(debugLabel: 'exo-aspect');
  final FocusNode _settingsFocus = FocusNode(debugLabel: 'exo-settings');
  final FocusNode _switchFocus = FocusNode(debugLabel: 'exo-switch');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'exo-panel-first');
  final FocusNode _errorFocus = FocusNode(debugLabel: 'exo-error-primary');
  final FocusScopeNode _panelScope = FocusScopeNode(debugLabel: 'exo-panel');

  OrvixExoController? _controller;
  OrvixExoValue _value = const OrvixExoValue();
  Timer? _hideTimer;
  Timer? _saveTimer;
  Timer? _slowTimer;
  Timer? _autoSubtitleTimer;
  Timer? _noticeTimer;
  Timer? _scrubTimer;
  // External subtitles are timed in Dart: the native position arrives every
  // 500 ms, so it is extrapolated between reports and repainted often.
  final Stopwatch _sinceState = Stopwatch()..start();
  final Stopwatch _bufferingFor = Stopwatch();

  /// Bytes received when the current mid-playback buffering began, so the
  /// buffering indicator can tell "data is arriving" from "nothing yet".
  int _bufferStartBytes = 0;
  Timer? _externalSubtitleTimer;
  LocalP2pStartupMonitor? _p2pStartup;
  final ExoP2pRetryPolicy _p2pRetry = ExoP2pRetryPolicy();
  late final ExoDiagnosticsLog _log;
  late final PlayerOrientationController _orientation;
  bool _controlsVisible = true;
  bool _closing = false;
  bool _started = false;
  bool _reopening = false;
  bool _slowStartNotice = false;
  String? _error;
  ExoErrorDiagnosis? _errorDiagnosis;
  String? _notice;
  Duration _lastPosition = Duration.zero;
  Timer? _attemptTimer;
  bool _attemptWasLong = false;
  int _attempts = 0;
  ExoStartupStage? _loggedStage;
  Duration? _scrubTarget;

  // Android local Free P2P: a torrent that has not delivered video yet is
  // still connecting. The native player retries reads for as long as it is
  // open, and only real terminal evidence ends the attempt.
  late final bool _localP2p =
      LocalP2pStartupPolicy.appliesTo(isAndroid: true, url: widget.url);

  _ExoPanel _panel = _ExoPanel.none;
  FocusNode? _panelOpener;
  ExoAspectMode _aspect = ExoAspectMode.fit;
  double _zoom = ExoPlayerPreferencesService.defaultZoom;
  int _seekStepSeconds = ExoPlayerPreferencesService.defaultSeekStep;
  ExternalSubtitleTrack? _external;
  bool _subtitlesOff = false;
  bool _userChoseSubtitle = false;
  Duration _subtitleOffset = Duration.zero;
  ExoSubtitleStyle _style = const ExoSubtitleStyle();
  String _preferredLanguage = SubtitlePreferencesService.defaultPreferredLanguage;
  String? _savedSubtitleLanguage;
  String? _savedAudioLanguage;
  Future<List<OnlineSubtitleResult>>? _onlineSearch;
  bool _loadingSubtitle = false;

  List<SkipSegment> _skipSegments = const [];
  SkipSegment? _activeSkipSegment;
  bool _skipDismissed = false;

  bool get _tv => PlatformProfile.isAndroidTv;
  Duration get _seekStep => Duration(seconds: _seekStepSeconds);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _log = ExoDiagnosticsLog(
      platform: _tv ? 'Android TV' : 'Android Mobile',
      mediaKind: exoMediaKind(widget.url),
    );
    _orientation = AndroidExoPlayerScreen.debugOrientationController?.call(_tv) ??
        PlayerOrientationController(isTv: _tv);
    unawaited(_start());
    unawaited(_loadSkipSegments());
  }

  bool _fullscreenRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Phones play in landscape fullscreen (MPV does the same); tablets keep
    // their orientation; TV is landscape already.
    if (!_fullscreenRequested) {
      _fullscreenRequested = true;
      unawaited(_orientation.enter(MediaQuery.sizeOf(context).shortestSide));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_orientation.resume());
      _log.add('app', {'state': 'resumed'});
    } else if (state == AppLifecycleState.paused) {
      _log.add('app', {'state': 'paused'});
      // A film that is already playing pauses with the app (Home on a TV
      // remote, switching apps on a phone). A stream that is still starting
      // keeps loading so it is ready when the user returns.
      if (_started && (_value.playing || _value.playWhenReady)) {
        unawaited(_controller?.pause());
      }
    }
  }

  Future<void> _start() async {
    await _loadPreferences();
    if (!mounted || _closing) return;
    await _open();
  }

  Future<void> _loadPreferences() async {
    try {
      final style = await ExoPlayerPreferencesService.subtitleStyle();
      final language = await SubtitlePreferencesService.preferredLanguage();
      final aspect = await ExoPlayerPreferencesService.aspectMode();
      final zoom = await ExoPlayerPreferencesService.zoom();
      final seekStep = await ExoPlayerPreferencesService.seekStepSeconds();
      final enabled = await ExoPlayerPreferencesService.subtitlesEnabled();
      final subtitleLanguage =
          await ExoPlayerPreferencesService.subtitleLanguage();
      final audioLanguage = await ExoPlayerPreferencesService.audioLanguage();
      if (!mounted) return;
      setState(() {
        _style = style;
        _preferredLanguage = language;
        _aspect = aspect;
        _zoom = zoom;
        _seekStepSeconds = seekStep;
        _subtitlesOff = !enabled;
        _savedSubtitleLanguage = subtitleLanguage;
        _savedAudioLanguage = audioLanguage;
      });
    } catch (_) {
      // Defaults stay in place; playback and subtitles still work.
    }
  }

  Future<Duration> _resumePosition() async {
    final mediaState = widget.mediaState;
    final item = widget.item;
    if (mediaState == null || item == null) return Duration.zero;
    try {
      final resume =
          await mediaState.resumePosition(item, episode: widget.episode);
      if (resume != null && resume > const Duration(seconds: 5)) return resume;
    } catch (_) {}
    return Duration.zero;
  }

  Future<void> _open({Duration? resumeAt}) async {
    final start = resumeAt ?? await _resumePosition();
    if (!mounted || _closing) return;
    _attempts++;
    final controller = OrvixExoController(
      url: widget.url,
      headers: widget.httpHeaders ?? const <String, String>{},
      patientStartup: _localP2p,
      preferredTextLanguage: _savedSubtitleLanguage ?? _preferredLanguage,
      preferredAudioLanguage: _savedAudioLanguage ?? 'en',
      textDisabled: _subtitlesOff,
      startPosition: start,
    );
    controller.onDiagnostic = (event) {
      _log.add(event['kind']?.toString() ?? 'diag', event);
    };
    _controller = controller;
    controller.addListener(_onValue);
    _log.add('open', {
      'attempt': _attempts,
      'patient': _localP2p,
      'resumeS': start.inSeconds,
    });
    _attemptWasLong = false;
    _attemptTimer?.cancel();
    _attemptTimer = Timer(_p2pRetry.rapidFailure, () => _attemptWasLong = true);
    try {
      await controller.open();
    } catch (error) {
      if (!mounted || _closing || !identical(_controller, controller)) return;
      _log.add('openFailed', {'error': error.runtimeType});
      await _fail(
        'The Android player could not be created on this device.',
        diagnosis: const ExoErrorDiagnosis(
          category: ExoErrorCategory.lifecycle,
          title: 'Player could not start',
          message: 'The Android player could not be created on this device.',
          suggestMpv: true,
          transientOnLocalP2p: false,
        ),
      );
      return;
    }
    if (!mounted || _closing || !identical(_controller, controller)) return;
    if (_subtitleOffset != Duration.zero) {
      unawaited(controller.setSubtitleOffset(_subtitleOffset));
    }
    if (_subtitlesOff || _external != null) {
      unawaited(controller.selectTextTrack(null));
    }
    if (_started) return;
    if (_localP2p) {
      _p2pStartup ??= LocalP2pStartupMonitor(
        playerGaveUp: () async => false,
        engineAnswering: () => AndroidExoPlayerScreen.debugEngineAnswering(),
        started: () => _started || _closing,
        onSlow: () {
          if (mounted && !_closing) setState(() => _slowStartNotice = true);
        },
        onTerminal: (reason) => unawaited(_fail(reason)),
        onStage: widget.onStartupStage,
      )..begin();
    } else {
      // Not a deadline: Media3's own connect/read timeouts and retry policy
      // decide when a remote stream has failed. This only changes the text.
      _slowTimer ??= Timer(AndroidExoPlayerScreen.slowRemoteNoticeAfter, () {
        if (_started || _closing || !mounted) return;
        _log.add('slowStart', {'stage': _value.startupStage.name});
        setState(() => _slowStartNotice = true);
      });
    }
  }

  void _onValue() {
    final controller = _controller;
    if (controller == null || !mounted || _closing) return;
    final value = controller.value;
    if (value.position > Duration.zero) _lastPosition = value.position;

    final stage = value.startupStage;
    if (!_started && stage != _loggedStage) {
      _loggedStage = stage;
      _log.add('stage', {
        'stage': stage.name,
        'bytes': value.bytesLoaded,
        'http': value.httpStatus,
      });
    }

    if (!_started && value.started) {
      _started = true;
      _slowTimer?.cancel();
      _p2pStartup?.stop();
      _attemptTimer?.cancel();
      _slowStartNotice = false;
      _log.add('playing', {
        'firstFrameMs': value.firstFrame?.inMilliseconds,
        'firstByteMs': value.firstByte?.inMilliseconds,
      });
      _saveTimer?.cancel();
      _saveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_persistProgress()),
      );
      _scheduleAutoSubtitle();
      // On TV the remote lands on Play/Pause; touch keeps the surface.
      _showControls(focusPlay: _tv);
    }

    if (_started && value.buffering) {
      if (!_bufferingFor.isRunning) {
        _bufferStartBytes = value.bytesLoaded;
        _bufferingFor
          ..reset()
          ..start();
        _log.add('buffering', {'atS': value.position.inSeconds});
      }
    } else if (_bufferingFor.isRunning) {
      _log.add('bufferingEnded', {'ms': _bufferingFor.elapsedMilliseconds});
      _bufferingFor
        ..stop()
        ..reset();
    }

    if (value.hasError && !_reopening && _error == null) {
      unawaited(_handleError(controller, value));
    }
    _updateSkipSegment(value.position);
    if (value.position != _value.position || value.playing != _value.playing) {
      _sinceState.reset();
    }
    setState(() => _value = value);
  }

  Future<void> _handleError(
    OrvixExoController controller,
    OrvixExoValue value,
  ) async {
    final error = value.error ??
        OrvixExoError(
          code: value.errorCode ?? 'ERROR_CODE_UNSPECIFIED',
          message: value.errorMessage ?? '',
        );
    final diagnosis = ExoErrorClassifier.classify(error);
    _log.add('error', {
      'code': error.code,
      'category': diagnosis.category.name,
      'http': error.httpStatus,
      'type': error.errorType,
      'causes': error.causes,
      'renderer': error.rendererMime,
      'support': error.rendererSupport,
    });
    final message = value.errorMessage?.trim().isNotEmpty == true
        ? value.errorMessage!
        : 'ExoPlayer reported a playback error.';
    if (!_localP2p) {
      await _fail(diagnosis.message, diagnosis: diagnosis);
      return;
    }
    // Local torrent: errors a slow swarm causes reopen the same stream at the
    // same position; genuine errors end the attempt.
    _reopening = true;
    try {
      final terminal = LocalP2pStartupPolicy.exoErrorCodeIsTerminal(
            value.errorCode,
          ) ||
          LocalP2pStartupPolicy.exoErrorIsTerminal(message);
      final engineUp = await AndroidExoPlayerScreen.debugEngineAnswering();
      if (!mounted || _closing || !identical(_controller, controller)) return;
      final retry = !terminal &&
          _p2pRetry.shouldRetry(
            description: message,
            attemptWasLong: _attemptWasLong,
            engineAnswering: engineUp,
          );
      if (!retry) {
        widget.onStartupStage?.call('playerStart', 'terminal', {
          'code': value.errorCode,
          'engineAnswering': engineUp,
        });
        await _fail(
          engineUp
              ? diagnosis.message
              : 'The local torrent engine stopped answering.',
          diagnosis: diagnosis,
        );
        return;
      }
      if (_p2pRetry.attempts <= 3) {
        widget.onStartupStage?.call('playerError', 'transient', {
          'code': value.errorCode,
          'count': _p2pRetry.attempts,
        });
      }
      _log.add('reopen', {'reason': value.errorCode, 'count': _p2pRetry.attempts});
      controller.removeListener(_onValue);
      _controller = null;
      controller.dispose();
      if (mounted && !_started) setState(() => _slowStartNotice = true);
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || _closing) return;
      await _open(resumeAt: _started ? _lastPosition : null);
    } finally {
      _reopening = false;
    }
  }

  Future<void> _fail(String message, {ExoErrorDiagnosis? diagnosis}) async {
    if (!mounted || _closing) return;
    _slowTimer?.cancel();
    _p2pStartup?.stop();
    _hideTimer?.cancel();
    _log.add('failed', {
      'category': diagnosis?.category.name ?? 'startup',
      'started': _started,
    });
    setState(() {
      _error = message;
      _errorDiagnosis = diagnosis;
      _slowStartNotice = false;
      _panel = _ExoPanel.none;
    });

    if (widget.autoFallbackToMpv && !_started) {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!mounted || _closing) return;
      await _close(failed: true, switchToMpv: true, error: message);
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _errorFocus.requestFocus();
    });
  }

  /// Opens the same source again in ExoPlayer, at the last position.
  Future<void> _retry() async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      old.removeListener(_onValue);
      await old.close();
    }
    if (!mounted || _closing) return;
    _log.add('retry', {'byUser': true});
    _p2pStartup = null;
    _slowTimer = null;
    setState(() {
      _error = null;
      _errorDiagnosis = null;
      _value = const OrvixExoValue();
      _slowStartNotice = false;
    });
    _surfaceFocus.requestFocus();
    await _open(resumeAt: _started ? _lastPosition : null);
  }

  Future<void> _loadSkipSegments() async {
    try {
      if (!await SkipSegmentPreferencesService.isEnabled()) return;
      final item = widget.item;
      if (item == null) return;
      final imdb = IntroDbService.imdbIdFrom(item.id) ??
          IntroDbService.imdbIdFrom(widget.episode?.id ?? '');
      if (imdb == null) return;
      final episode = widget.episode;
      final segments = await IntroDbService().segments(
        imdbId: imdb,
        season: episode?.season,
        episode: episode?.episode,
      );
      if (!mounted || _closing) return;
      setState(() => _skipSegments = segments);
    } catch (_) {}
  }

  void _updateSkipSegment(Duration position) {
    if (_skipSegments.isEmpty) return;
    final current = _skipSegments.cast<SkipSegment?>().firstWhere(
          (segment) => segment!.contains(position),
          orElse: () => null,
        );
    if (identical(current, _activeSkipSegment)) return;
    _activeSkipSegment = current;
    _skipDismissed = false;
  }

  Future<void> _skipActiveSegment() async {
    final segment = _activeSkipSegment;
    if (segment == null) return;
    var target = segment.end;
    final duration = _value.duration;
    if (duration > Duration.zero && target >= duration) {
      target = duration - const Duration(milliseconds: 1);
    }
    await _controller?.seekTo(target);
    if (!mounted) return;
    setState(() {
      _activeSkipSegment = null;
      _skipDismissed = true;
    });
    _showControls();
  }

  // ---------------------------------------------------------------- subtitles

  void _scheduleAutoSubtitle() {
    _autoSubtitleTimer?.cancel();
    _autoSubtitleTimer = Timer(const Duration(seconds: 6), () {
      unawaited(_autoSelectSubtitle());
    });
  }

  /// Never leaves the user silently without subtitles: when the stream has
  /// no selected subtitle track, the best OpenSubtitles match in the
  /// preferred language is loaded, as the MPV player does. A user who turned
  /// subtitles off keeps them off.
  Future<void> _autoSelectSubtitle() async {
    if (!mounted || _closing || _userChoseSubtitle || _subtitlesOff) return;
    if (_external != null) return;
    final text = _value.textTracks;
    if (text.any((track) => track.selected)) return;
    final wanted = OnlineSubtitleService.normalizeLanguage(
      _savedSubtitleLanguage ?? _preferredLanguage,
    );
    final preferred = text.where(
      (track) =>
          track.supported &&
          OnlineSubtitleService.normalizeLanguage(track.language ?? '') ==
              wanted,
    );
    if (preferred.isNotEmpty) {
      await _selectEmbedded(preferred.first, userChoice: false);
      return;
    }
    final item = widget.item;
    if (item == null) return;
    try {
      final results = await _searchOnline();
      if (!mounted || _closing || _userChoseSubtitle || _external != null) {
        return;
      }
      final match = results.where((r) => r.language == wanted).toList();
      if (match.isEmpty) return;
      await _loadOnline(match.first, userChoice: false);
    } catch (_) {
      // Automatic subtitles are best effort; the panel still offers them.
    }
  }

  Future<List<OnlineSubtitleResult>> _searchOnline() {
    final item = widget.item;
    if (item == null) return Future.value(const <OnlineSubtitleResult>[]);
    return _onlineSearch ??= AndroidExoPlayerScreen.debugSearchSubtitles(
      item: item,
      episode: widget.episode,
      releaseHint: widget.releaseHint,
      videoSize: widget.expectedSizeBytes,
      videoHash: widget.expectedVideoHash,
      preferredLanguage: _preferredLanguage,
    );
  }

  void _rememberSubtitleChoice({required bool enabled, String? language}) {
    unawaited(ExoPlayerPreferencesService.setSubtitlesEnabled(enabled)
        .catchError((Object _) {}));
    if (enabled && language != null && language.trim().isNotEmpty) {
      _savedSubtitleLanguage = language;
      unawaited(ExoPlayerPreferencesService.setSubtitleLanguage(language)
          .catchError((Object _) {}));
    }
  }

  Future<void> _selectEmbedded(
    OrvixExoTrack track, {
    bool userChoice = true,
  }) async {
    if (userChoice) {
      _userChoseSubtitle = true;
      _rememberSubtitleChoice(enabled: true, language: track.language);
    }
    setState(() {
      _external = null;
      _subtitlesOff = false;
    });
    _syncExternalSubtitleTimer();
    await _controller?.selectTextTrack(track);
    _log.add('subtitle', {'kind': 'embedded', 'mime': track.mimeType});
    if (userChoice) {
      _showNotice('Subtitles: ${track.displayName}');
      _closePanel();
    }
  }

  Future<void> _subtitlesOffNow() async {
    _userChoseSubtitle = true;
    _rememberSubtitleChoice(enabled: false);
    setState(() {
      _external = null;
      _subtitlesOff = true;
    });
    _syncExternalSubtitleTimer();
    await _controller?.selectTextTrack(null);
    _showNotice('Subtitles off');
    _closePanel();
  }

  Future<void> _applyExternal(
    ExternalSubtitleTrack track, {
    bool userChoice = true,
  }) async {
    if (track.isEmpty) {
      _showNotice('That subtitle file has no readable lines.');
      return;
    }
    if (userChoice) {
      _userChoseSubtitle = true;
      _rememberSubtitleChoice(enabled: true, language: track.language);
    }
    setState(() {
      _external = track;
      _subtitlesOff = false;
    });
    _syncExternalSubtitleTimer();
    await _controller?.selectTextTrack(null);
    _log.add('subtitle', {'kind': 'external', 'source': track.source});
    _showNotice('Subtitles: ${track.label}');
  }

  Future<void> _loadOnline(
    OnlineSubtitleResult result, {
    bool userChoice = true,
  }) async {
    if (_loadingSubtitle) return;
    setState(() => _loadingSubtitle = true);
    try {
      final text = await AndroidExoPlayerScreen.debugDownloadSubtitle(result);
      if (!mounted || _closing) return;
      await _applyExternal(
        ExternalSubtitleTrack.parse(
          text,
          label: '${result.languageLabel} • OpenSubtitles',
          language: result.language,
          source: 'online',
        ),
        userChoice: userChoice,
      );
      if (userChoice) _closePanel();
    } catch (_) {
      if (mounted && userChoice) {
        _showNotice('Could not download that subtitle. Try another one.');
      }
    } finally {
      if (mounted) setState(() => _loadingSubtitle = false);
    }
  }

  Future<void> _loadSubtitleFile() async {
    try {
      final path = await pickExternalSubtitlePath();
      if (path == null || path.isEmpty || !mounted) return;
      final text = AndroidExoPlayerScreen.decodeSubtitleBytes(
        await File(path).readAsBytes(),
      );
      final name = path.split(Platform.pathSeparator).last;
      await _applyExternal(ExternalSubtitleTrack.parse(text, label: name));
      _closePanel();
    } catch (_) {
      if (mounted) _showNotice('Could not read that subtitle file.');
    }
  }

  /// Positive delays show subtitles later, negative earlier. The delay is
  /// kept across seeks and reopened streams; [Duration.zero] resets it.
  Future<void> _changeSubtitleOffset(Duration delta) async {
    final next = delta == Duration.zero ? Duration.zero : _subtitleOffset + delta;
    const limit = Duration(minutes: 10);
    final clamped = next > limit
        ? limit
        : next < -limit
            ? -limit
            : next;
    setState(() => _subtitleOffset = clamped);
    await _controller?.setSubtitleOffset(clamped);
  }

  Future<void> _updateStyle(ExoSubtitleStyle next) async {
    setState(() => _style = next);
    try {
      await ExoPlayerPreferencesService.setSubtitleStyle(next);
    } catch (_) {}
  }

  Future<void> _resetStyle() async {
    try {
      final style = await ExoPlayerPreferencesService.resetSubtitleStyle();
      if (!mounted) return;
      setState(() => _style = style);
    } catch (_) {
      if (mounted) setState(() => _style = const ExoSubtitleStyle());
    }
    _showNotice('Subtitle style reset');
  }

  Duration get _estimatedPosition {
    final value = _value;
    if (!value.playing) return value.position;
    final ahead = Duration(
      microseconds:
          (_sinceState.elapsedMicroseconds * value.speed).round().clamp(0, 1000000),
    );
    return value.position + ahead;
  }

  void _syncExternalSubtitleTimer() {
    if (_external == null || _closing) {
      _externalSubtitleTimer?.cancel();
      _externalSubtitleTimer = null;
      return;
    }
    _externalSubtitleTimer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (mounted && _value.playing) setState(() {});
      },
    );
  }

  List<String> get _subtitleLines {
    if (_subtitlesOff) return const <String>[];
    final external = _external;
    if (external != null) {
      return external.linesAt(_estimatedPosition, offset: _subtitleOffset);
    }
    return _value.cueText;
  }

  // ------------------------------------------------------------------ actions

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _showControls({bool focusPlay = false}) {
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (focusPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_error != null || _panel != _ExoPanel.none || !_started) return;
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _error != null || _panel != _ExoPanel.none) return;
      if (!(_value.playing)) return;
      setState(() => _controlsVisible = false);
      _surfaceFocus.requestFocus();
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
    _surfaceFocus.requestFocus();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (_value.playing || _value.playWhenReady) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _showControls();
  }

  Duration _clampToMedia(Duration target) {
    if (target < Duration.zero) return Duration.zero;
    final duration = _value.duration;
    if (duration > Duration.zero && target > duration) return duration;
    return target;
  }

  Future<void> _seekRelative(Duration offset) async {
    final controller = _controller;
    if (controller == null || !_started) return;
    _scrubTimer?.cancel();
    _scrubTarget = null;
    await controller.seekTo(_clampToMedia(_value.position + offset));
    _showControls();
  }

  /// A held DPAD key scrubs: the target moves on every repeat and the seek
  /// is sent once, when the key is released or the remote goes quiet.
  void _scrub(Duration offset) {
    if (_controller == null || !_started) return;
    final base = _scrubTarget ?? _value.position;
    setState(() => _scrubTarget = _clampToMedia(base + offset));
    _showControls();
    _scrubTimer?.cancel();
    _scrubTimer = Timer(const Duration(milliseconds: 450), _commitScrub);
  }

  void _commitScrub() {
    _scrubTimer?.cancel();
    final target = _scrubTarget;
    if (target == null) return;
    _scrubTarget = null;
    unawaited(_controller?.seekTo(target));
    if (mounted) setState(() {});
  }

  KeyEventResult _seekKey(KeyEvent event, {required bool forward}) {
    final offset = forward ? _seekStep : -_seekStep;
    if (event is KeyRepeatEvent) {
      _scrub(offset);
    } else if (event is KeyDownEvent) {
      unawaited(_seekRelative(offset));
    }
    return KeyEventResult.handled;
  }

  void _openPanel(_ExoPanel panel, {FocusNode? opener}) {
    _hideTimer?.cancel();
    if (_panel == _ExoPanel.none) {
      _panelOpener = opener ?? FocusManager.instance.primaryFocus;
    }
    setState(() {
      _panel = panel;
      _controlsVisible = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelFocus.requestFocus();
    });
  }

  /// Closes the panel and returns the remote to the control that opened it.
  void _closePanel() {
    if (_panel == _ExoPanel.none) return;
    final opener = _panelOpener;
    _panelOpener = null;
    setState(() => _panel = _ExoPanel.none);
    _showControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (opener != null && opener.context != null && opener.canRequestFocus) {
        opener.requestFocus();
      } else {
        _playFocus.requestFocus();
      }
    });
  }

  /// Puts the remote on the panel's first row when nothing inside the panel
  /// has focus (for example after results finished loading).
  void _ensurePanelFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _panel == _ExoPanel.none) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || !primary.ancestors.contains(_panelScope)) {
        _panelFocus.requestFocus();
      }
    });
  }

  void _switchPanel(_ExoPanel panel) {
    setState(() => _panel = panel);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelFocus.requestFocus();
    });
  }

  Future<void> _setAspect(ExoAspectMode mode) async {
    setState(() => _aspect = mode);
    _showNotice('Picture: ${mode.label}'
        '${mode == ExoAspectMode.zoom ? ' ${(_zoom * 100).round()}%' : ''}');
    _log.add('aspect', {'mode': mode.name});
    try {
      await ExoPlayerPreferencesService.setAspectMode(mode);
    } catch (_) {}
  }

  void _cycleAspect() {
    unawaited(_setAspect(ExoAspectMode
        .values[(_aspect.index + 1) % ExoAspectMode.values.length]));
    _showControls();
  }

  Future<void> _changeZoom(double delta) async {
    final next = (_zoom + delta)
        .clamp(ExoPlayerPreferencesService.minZoom,
            ExoPlayerPreferencesService.maxZoom)
        .toDouble();
    setState(() {
      _zoom = double.parse(next.toStringAsFixed(2));
      _aspect = ExoAspectMode.zoom;
    });
    try {
      await ExoPlayerPreferencesService.setZoom(_zoom);
      await ExoPlayerPreferencesService.setAspectMode(ExoAspectMode.zoom);
    } catch (_) {}
  }

  Future<void> _cycleSeekStep(int direction) async {
    const steps = ExoPlayerPreferencesService.seekSteps;
    final index = steps.indexOf(_seekStepSeconds);
    final next = steps[(index + direction).clamp(0, steps.length - 1)];
    setState(() => _seekStepSeconds = next);
    try {
      await ExoPlayerPreferencesService.setSeekStepSeconds(next);
    } catch (_) {}
  }

  Future<void> _selectAudio(OrvixExoTrack? track) async {
    await _controller?.selectAudioTrack(track);
    _savedAudioLanguage = track?.language;
    try {
      await ExoPlayerPreferencesService.setAudioLanguage(track?.language);
    } catch (_) {}
    _log.add('audio', {'mime': track?.mimeType ?? 'auto'});
    if (mounted) {
      _showNotice(track == null ? 'Audio: Automatic' : 'Audio: ${track.displayName}');
    }
  }

  Future<void> _copyReport() async {
    final diagnosis = _errorDiagnosis;
    final report = _log.report(
      _value,
      classified: diagnosis == null
          ? null
          : '${diagnosis.category.name}: ${diagnosis.title}',
    );
    try {
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) _showNotice('Playback report copied');
    } catch (_) {
      if (mounted) _showNotice('Could not copy the report');
    }
  }

  void _onBack() {
    if (_panel == _ExoPanel.onlineSubtitles ||
        _panel == _ExoPanel.subtitleStyle) {
      _switchPanel(_ExoPanel.subtitles);
      return;
    }
    if (_panel == _ExoPanel.info && _error == null) {
      _switchPanel(_ExoPanel.settings);
      return;
    }
    if (_panel != _ExoPanel.none) {
      if (_error != null) {
        setState(() => _panel = _ExoPanel.none);
        _errorFocus.requestFocus();
        return;
      }
      _closePanel();
      return;
    }
    if (_tv && _controlsVisible && _started && _error == null) {
      _hideControls();
      return;
    }
    unawaited(_close(failed: _error != null, error: _error));
  }

  /// Media keys work wherever focus is; DPAD keys only act on the video when
  /// no control has focus.
  KeyEventResult _onSurfaceKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      final key = event.logicalKey;
      if (_scrubTarget != null &&
          (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.mediaRewind ||
              key == LogicalKeyboardKey.mediaFastForward)) {
        _commitScrub();
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_error == null && _panel == _ExoPanel.none) {
      if (key == LogicalKeyboardKey.mediaPlayPause) {
        if (event is KeyDownEvent) unawaited(_togglePlay());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaPlay) {
        if (event is KeyDownEvent) {
          unawaited(_controller?.play());
          _showControls();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaPause) {
        if (event is KeyDownEvent) {
          unawaited(_controller?.pause());
          _showControls();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaRewind) {
        return _seekKey(event, forward: false);
      }
      if (key == LogicalKeyboardKey.mediaFastForward) {
        return _seekKey(event, forward: true);
      }
      if (key == LogicalKeyboardKey.contextMenu && _started) {
        if (event is KeyDownEvent) {
          _openPanel(_ExoPanel.settings, opener: _settingsFocus);
        }
        return KeyEventResult.handled;
      }
    }
    // A real control owns focus: let Flutter's focus traversal and
    // ActivateAction handle DPAD and OK.
    if (!_surfaceFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_controlsVisible) {
        unawaited(_togglePlay());
      } else {
        _showControls(focusPlay: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _seekKey(event, forward: false);
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return _seekKey(event, forward: true);
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onTimelineKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (_scrubTarget != null) _commitScrub();
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _seekKey(event, forward: false);
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return _seekKey(event, forward: true);
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent) unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    // TV: Back sits alone in the top-left corner, outside the timeline's
    // column, so directional search would land on the video surface.
    if (_tv && key == LogicalKeyboardKey.arrowUp) {
      if (event is KeyDownEvent) _backFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _persistProgress() async {
    final mediaState = widget.mediaState;
    final item = widget.item;
    if (mediaState == null || item == null || !_started) return;
    final value = _value;
    if (value.duration <= Duration.zero) return;
    try {
      await mediaState.saveProgress(
        item,
        episode: widget.episode,
        position: value.position,
        duration: value.duration,
      );
    } catch (_) {}
  }

  Future<void> _close({
    bool failed = false,
    bool switchToMpv = false,
    bool playNext = false,
    String? error,
  }) async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _slowTimer?.cancel();
    _autoSubtitleTimer?.cancel();
    _externalSubtitleTimer?.cancel();
    _attemptTimer?.cancel();
    _scrubTimer?.cancel();
    _p2pStartup?.stop();
    _log.add('close', {
      'started': _started,
      'failed': failed,
      'switchToMpv': switchToMpv,
    });

    final started = _started;
    await _persistProgress();
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onValue);
      try {
        await controller.pause();
      } catch (_) {}
      await controller.close();
    }
    // Restore the app's orientation and system bars before the next screen
    // (MPV or the title page) builds.
    await _orientation.exit();

    if (!mounted) return;
    Navigator.of(context).pop(
      AndroidExoPlayerResult(
        failed: failed,
        switchToMpv: switchToMpv,
        started: started,
        playNext: playNext,
        error: error,
      ),
    );
  }

  String _format(Duration value) {
    final total = value.inSeconds.clamp(0, 24 * 60 * 60);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_orientation.exit());
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _slowTimer?.cancel();
    _autoSubtitleTimer?.cancel();
    _noticeTimer?.cancel();
    _externalSubtitleTimer?.cancel();
    _attemptTimer?.cancel();
    _scrubTimer?.cancel();
    _p2pStartup?.stop();
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onValue);
      controller.dispose();
    }
    for (final node in [
      _surfaceFocus,
      _backFocus,
      _timelineFocus,
      _rewindFocus,
      _playFocus,
      _forwardFocus,
      _subtitlesFocus,
      _audioFocus,
      _speedFocus,
      _aspectFocus,
      _settingsFocus,
      _switchFocus,
      _panelFocus,
      _errorFocus,
      _panelScope,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  // ----------------------------------------------------------------------- UI

  String get _loadingMessage {
    final stage = _value.startupStage;
    if (_localP2p) {
      if (_slowStartNotice) return 'Still connecting to peers…';
      return switch (stage) {
        ExoStartupStage.opening ||
        ExoStartupStage.connecting =>
          'Connecting to peers…',
        ExoStartupStage.receiving => 'Loading video…',
        ExoStartupStage.decoding ||
        ExoStartupStage.playing =>
          'Starting playback…',
      };
    }
    if (_slowStartNotice) {
      return stage == ExoStartupStage.connecting ||
              stage == ExoStartupStage.opening
          ? 'Still waiting for the source…'
          : 'Still loading…';
    }
    return switch (stage) {
      ExoStartupStage.opening ||
      ExoStartupStage.connecting =>
        'Connecting to the source…',
      ExoStartupStage.receiving => 'Loading video…',
      ExoStartupStage.decoding ||
      ExoStartupStage.playing =>
        'Starting playback…',
    };
  }

  String? get _loadingDetail {
    if (_slowStartNotice) {
      return _localP2p
          ? 'This torrent is starting slowly. Keep waiting, '
              'or go Back to choose another source.'
          : 'This source is slow to respond. Keep waiting, '
              'or go Back to choose another source.';
    }
    final bytes = _value.bytesLoaded;
    if (bytes > 0) {
      final mb = bytes / (1024 * 1024);
      return 'Received ${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
    }
    return widget.episode == null ? null : widget.title;
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final showLoading = !_started && _error == null;
    final buffering = _started && value.buffering && _error == null;
    final slowBuffer = buffering &&
        _bufferingFor.elapsed >= AndroidExoPlayerScreen.slowBufferNoticeAfter;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: ExoPlayerColors.background,
        body: Focus(
          autofocus: true,
          focusNode: _surfaceFocus,
          onKeyEvent: _onSurfaceKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_panel != _ExoPanel.none) {
                _closePanel();
              } else if (_controlsVisible && _started) {
                _hideControls();
              } else {
                _showControls();
              }
            },
            onDoubleTapDown: (details) {
              if (!_started || _error != null) return;
              final width = MediaQuery.sizeOf(context).width;
              unawaited(_seekRelative(
                details.localPosition.dx < width / 2 ? -_seekStep : _seekStep,
              ));
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                if (value.textureId != null) _video(value),
                _subtitleLayer(value),
                if (showLoading)
                  PlayerLoadingOverlay(
                    item: widget.item,
                    title: widget.title,
                    message: _loadingMessage,
                    detail: _loadingDetail,
                  ),
                // A stall shorter than this shows nothing, so a brief
                // rebuffer never flashes a spinner over the picture.
                if (buffering &&
                    _tv &&
                    _bufferingFor.elapsed >= const Duration(milliseconds: 400))
                  _TvBufferingIndicator(
                    status: exoBufferingStatus(
                      localP2p: _localP2p,
                      bufferingFor: _bufferingFor.elapsed,
                      bytesSinceStart: value.bytesLoaded - _bufferStartBytes,
                    ),
                    lifted: _controlsVisible,
                  )
                else if (buffering && !_tv)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                            color: ExoPlayerColors.lime,
                            strokeWidth: 3,
                          ),
                        ),
                        if (slowBuffer) ...[
                          const SizedBox(height: 12),
                          _NoticeChip(
                            text: _localP2p
                                ? 'Waiting for peers…'
                                : 'Buffering…',
                          ),
                        ],
                      ],
                    ),
                  ),
                if (_controlsVisible && _error == null && _started)
                  ExcludeFocus(
                    excluding: _panel != _ExoPanel.none,
                    child: _tv ? _tvControls(value) : _controls(value),
                  ),
                if (showLoading) _loadingBackButton(),
                if (_activeSkipSegment != null && !_skipDismissed &&
                    _error == null && _panel == _ExoPanel.none)
                  Positioned(
                    left: _tv ? 56 : 28,
                    bottom: _controlsVisible ? (_tv ? 236 : 150) : 40,
                    child: _ExoButton(
                      icon: Icons.skip_next_rounded,
                      label: _activeSkipSegment!.label,
                      onPressed: _skipActiveSegment,
                      onFocusChange: _onControlFocus,
                    ),
                  ),
                if (_notice != null)
                  Positioned(
                    top: 28,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(child: _NoticeChip(text: _notice!)),
                    ),
                  ),
                if (_error != null)
                  ExcludeFocus(
                    excluding: _panel != _ExoPanel.none,
                    child: _errorView(),
                  ),
                if (_panel != _ExoPanel.none) _panelView(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onControlFocus(bool focused) {
    if (focused) {
      _hideTimer?.cancel();
      if (!_controlsVisible && mounted) {
        setState(() => _controlsVisible = true);
      }
    } else {
      _scheduleHide();
    }
  }

  Widget _video(OrvixExoValue value) {
    Widget texture = Texture(textureId: value.textureId!);
    final quarterTurns = (value.rotation ~/ 90) % 4;
    if (quarterTurns != 0) {
      texture = RotatedBox(quarterTurns: quarterTurns, child: texture);
    }
    // Decoded size with the pixel aspect ratio already applied natively, so
    // anamorphic video keeps its real shape. Before the first frame the
    // picture is black anyway.
    var width = value.hasVideoSize ? value.videoWidth.toDouble() : 1920.0;
    var height = value.hasVideoSize ? value.videoHeight.toDouble() : 1080.0;
    if (quarterTurns.isOdd) {
      final swap = width;
      width = height;
      height = swap;
    }
    Widget picture = FittedBox(
      fit: _aspect.fit,
      child: SizedBox(width: width, height: height, child: texture),
    );
    if (_aspect == ExoAspectMode.zoom) {
      picture = Transform.scale(scale: _zoom, child: picture);
    }
    return ClipRect(child: SizedBox.expand(child: picture));
  }

  double get _videoAspect {
    final value = _value;
    if (!value.hasVideoSize) return 16 / 9;
    final quarterTurns = (value.rotation ~/ 90) % 4;
    return quarterTurns.isOdd
        ? value.videoHeight / value.videoWidth
        : value.videoWidth / value.videoHeight;
  }

  Widget _subtitleLayer(OrvixExoValue value) {
    final lines = _subtitleLines;
    final bitmaps = _subtitlesOff || _external != null
        ? const <OrvixExoBitmapCue>[]
        : value.bitmapCues;
    if (lines.isEmpty && bitmaps.isEmpty) return const SizedBox.shrink();
    final lift = _controlsVisible && _started && _panel == _ExoPanel.none
        ? (_tv ? 210.0 : 132.0)
        : 0.0;
    final atTop = _external == null && value.cuesAtTop;
    final alignment = switch (_style.alignment) {
      SubtitleAlignment.left => Alignment.centerLeft,
      SubtitleAlignment.center => Alignment.center,
      SubtitleAlignment.right => Alignment.centerRight,
    };
    final side = _tv ? 64.0 : 24.0;
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final videoRect = exoVideoRect(
              constraints.biggest,
              _videoAspect,
              _aspect,
              zoom: _zoom,
            );
            return Stack(
              children: [
                for (final cue in bitmaps)
                  if (cue.width != null && cue.width! > 0)
                    Positioned(
                      left: videoRect.left +
                          videoRect.width * (cue.left ?? (1 - cue.width!) / 2),
                      top: videoRect.top +
                          videoRect.height * (cue.top ?? .8),
                      width: videoRect.width * cue.width!,
                      child: Image.memory(
                        cue.png,
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                      ),
                    ),
                if (lines.isNotEmpty)
                  Positioned(
                    left: side,
                    right: side,
                    top: atTop ? _style.bottomOffset + (_tv ? 24 : 12) : null,
                    bottom: atTop ? null : _style.bottomOffset + lift,
                    child: Align(
                      alignment: alignment,
                      child: ExoSubtitleText(
                        text: lines.join('\n'),
                        style: _style,
                        scale: _tv ? 1.0 : .82,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _loadingBackButton() => Positioned(
        top: 0,
        left: 0,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(_tv ? 32 : 18),
            child: _ExoButton(
              focusNode: _backFocus,
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Back',
              onPressed: () => unawaited(_close()),
              onFocusChange: _onControlFocus,
            ),
          ),
        ),
      );

  Widget _controls(OrvixExoValue value) {
    final duration = value.duration;
    final position = _scrubTarget ?? value.position;
    final played = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    final buffered = duration.inMilliseconds <= 0
        ? 0.0
        : (value.buffered.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    final compact = MediaQuery.sizeOf(context).width < 640;
    final remaining = duration > position ? duration - position : Duration.zero;
    final subtitleLabel = _subtitlesOff ? 'Subtitles off' : 'Subtitles';
    final step = _seekStepSeconds;
    final horizontal = _tv ? 56.0 : (compact ? 14.0 : 36.0);

    final buttons = <Widget>[
      _ExoButton(
        focusNode: _rewindFocus,
        icon: _seekIcon(step, forward: false),
        semanticLabel: 'Back $step seconds',
        onPressed: () => unawaited(_seekRelative(-_seekStep)),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _playFocus,
        autofocus: _tv,
        icon: value.playing || value.playWhenReady
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        semanticLabel: value.playing || value.playWhenReady ? 'Pause' : 'Play',
        prominent: true,
        onPressed: () => unawaited(_togglePlay()),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _forwardFocus,
        icon: _seekIcon(step, forward: true),
        semanticLabel: 'Forward $step seconds',
        onPressed: () => unawaited(_seekRelative(_seekStep)),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _subtitlesFocus,
        icon: _subtitlesOff
            ? Icons.closed_caption_disabled_rounded
            : Icons.closed_caption_rounded,
        label: compact ? null : subtitleLabel,
        semanticLabel: 'Subtitles',
        onPressed: () =>
            _openPanel(_ExoPanel.subtitles, opener: _subtitlesFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _audioFocus,
        icon: Icons.audiotrack_rounded,
        label: compact ? null : 'Audio',
        semanticLabel: 'Audio',
        onPressed: () => _openPanel(_ExoPanel.audio, opener: _audioFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _speedFocus,
        icon: Icons.speed_rounded,
        label: compact ? null : '${_speedLabel(value.speed)}x',
        semanticLabel: 'Playback speed',
        onPressed: () => _openPanel(_ExoPanel.speed, opener: _speedFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _aspectFocus,
        icon: Icons.aspect_ratio_rounded,
        label: _aspect.label,
        semanticLabel: 'Aspect ratio ${_aspect.label}',
        onPressed: _cycleAspect,
        onFocusChange: _onControlFocus,
      ),
      if (widget.nextEpisodeLabel != null)
        _ExoButton(
          icon: Icons.skip_next_rounded,
          label: compact ? null : 'Next',
          semanticLabel: 'Next episode',
          onPressed: () => unawaited(_close(playNext: true)),
          onFocusChange: _onControlFocus,
        ),
      _ExoButton(
        focusNode: _settingsFocus,
        icon: Icons.tune_rounded,
        label: compact ? null : 'Settings',
        semanticLabel: 'Player settings',
        onPressed: () =>
            _openPanel(_ExoPanel.settings, opener: _settingsFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: _switchFocus,
        icon: Icons.swap_horiz_rounded,
        label: compact ? null : 'MPV',
        semanticLabel: 'Switch to MPV',
        onPressed: () => unawaited(_close(switchToMpv: true)),
        onFocusChange: _onControlFocus,
      ),
    ];

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xD9050806),
            Color(0x00050806),
            Color(0x00050806),
            Color(0xF2050806),
          ],
          stops: [0, .22, .55, 1],
        ),
      ),
      child: SafeArea(
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  _tv ? 28 : 14,
                  horizontal,
                  0,
                ),
                child: Row(
                  children: [
                    _ExoButton(
                      focusNode: _backFocus,
                      icon: Icons.arrow_back_rounded,
                      semanticLabel: 'Back',
                      onPressed: () => unawaited(_close()),
                      onFocusChange: _onControlFocus,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ExoPlayerColors.text,
                              fontSize: _tv ? 20 : 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (widget.nextEpisodeLabel != null)
                            Text(
                              'Next: ${widget.nextEpisodeLabel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ExoPlayerColors.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  0,
                  horizontal,
                  _tv ? 36 : (compact ? 14 : 26),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          _format(position),
                          style: TextStyle(
                            color: _scrubTarget != null
                                ? ExoPlayerColors.lime
                                : ExoPlayerColors.text,
                            fontSize: _tv ? 14 : 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Timeline(
                            focusNode: _timelineFocus,
                            played: played,
                            buffered: buffered,
                            onKeyEvent: _onTimelineKey,
                            onFocusChange: _onControlFocus,
                            onSeekFraction: duration > Duration.zero
                                ? (fraction) {
                                    unawaited(_controller?.seekTo(Duration(
                                      milliseconds:
                                          (duration.inMilliseconds * fraction)
                                              .round(),
                                    )));
                                    _showControls();
                                  }
                                : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Semantics(
                          label: 'Remaining ${_format(remaining)} of '
                              '${_format(duration)}',
                          child: ExcludeSemantics(
                            child: Text(
                              '-${_format(remaining)}',
                              style: TextStyle(
                                color: ExoPlayerColors.muted,
                                fontSize: _tv ? 14 : 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < buttons.length; i++) ...[
                            if (i > 0) SizedBox(width: compact ? 6 : 10),
                            buttons[i],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Android TV controls: a compact title, a slim timeline, one strong
  /// Play/Pause between the skip buttons, and the tools as quiet labelled
  /// buttons. Settings and MPV show their label when focused. Same focus
  /// nodes, actions and semantics as the phone layout in [_controls].
  Widget _tvControls(OrvixExoValue value) {
    final duration = value.duration;
    final position = _scrubTarget ?? value.position;
    final played = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    final buffered = duration.inMilliseconds <= 0
        ? 0.0
        : (value.buffered.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    final remaining = duration > position ? duration - position : Duration.zero;
    final step = _seekStepSeconds;
    final playing = value.playing || value.playWhenReady;
    const timeStyle = TextStyle(
      color: ExoPlayerColors.text,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    final tools = <Widget>[
      _ExoTvButton(
        focusNode: _subtitlesFocus,
        kind: _ExoTvButtonKind.tool,
        icon: _subtitlesOff
            ? Icons.closed_caption_disabled_rounded
            : Icons.closed_caption_rounded,
        label: _subtitlesOff ? 'Subtitles off' : 'Subtitles',
        semanticLabel: 'Subtitles',
        onPressed: () =>
            _openPanel(_ExoPanel.subtitles, opener: _subtitlesFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoTvButton(
        focusNode: _audioFocus,
        kind: _ExoTvButtonKind.tool,
        icon: Icons.graphic_eq_rounded,
        label: 'Audio',
        semanticLabel: 'Audio',
        onPressed: () => _openPanel(_ExoPanel.audio, opener: _audioFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoTvButton(
        focusNode: _speedFocus,
        kind: _ExoTvButtonKind.tool,
        icon: Icons.speed_rounded,
        label: '${_speedLabel(value.speed)}x',
        semanticLabel: 'Playback speed',
        onPressed: () => _openPanel(_ExoPanel.speed, opener: _speedFocus),
        onFocusChange: _onControlFocus,
      ),
      _ExoTvButton(
        focusNode: _aspectFocus,
        kind: _ExoTvButtonKind.tool,
        icon: Icons.aspect_ratio_rounded,
        label: _aspect.label,
        semanticLabel: 'Aspect ratio ${_aspect.label}',
        onPressed: _cycleAspect,
        onFocusChange: _onControlFocus,
      ),
      if (widget.nextEpisodeLabel != null)
        _ExoTvButton(
          kind: _ExoTvButtonKind.tool,
          icon: Icons.skip_next_rounded,
          label: 'Next episode',
          semanticLabel: 'Next episode',
          onPressed: () => unawaited(_close(playNext: true)),
          onFocusChange: _onControlFocus,
        ),
    ];

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xB3050806),
            Color(0x00050806),
            Color(0x00050806),
            Color(0x99050806),
            Color(0xF2050806),
          ],
          stops: [0, .2, .45, .7, 1],
        ),
      ),
      child: SafeArea(
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Padding(
            // Inside the 5% overscan-safe area of a TV picture.
            padding: const EdgeInsets.fromLTRB(48, 28, 48, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ExoTvButton(
                  focusNode: _backFocus,
                  kind: _ExoTvButtonKind.transport,
                  icon: Icons.arrow_back_rounded,
                  semanticLabel: 'Back',
                  onPressed: () => unawaited(_close()),
                  onFocusChange: _onControlFocus,
                ),
                const Spacer(),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ExoPlayerColors.text,
                    fontSize: 22,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.2,
                  ),
                ),
                if (widget.nextEpisodeLabel != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    'Next: ${widget.nextEpisodeLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ExoPlayerColors.muted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      _format(position),
                      style: timeStyle.copyWith(
                        color: _scrubTarget != null
                            ? ExoPlayerColors.lime
                            : ExoPlayerColors.text,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _Timeline(
                        focusNode: _timelineFocus,
                        played: played,
                        buffered: buffered,
                        onKeyEvent: _onTimelineKey,
                        onFocusChange: _onControlFocus,
                        onSeekFraction: duration > Duration.zero
                            ? (fraction) {
                                unawaited(_controller?.seekTo(Duration(
                                  milliseconds:
                                      (duration.inMilliseconds * fraction)
                                          .round(),
                                )));
                                _showControls();
                              }
                            : null,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Semantics(
                      label: 'Remaining ${_format(remaining)} of '
                          '${_format(duration)}',
                      child: ExcludeSemantics(
                        child: Text(
                          '-${_format(remaining)}',
                          style: timeStyle.copyWith(
                            color: ExoPlayerColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _ExoTvButton(
                      focusNode: _rewindFocus,
                      kind: _ExoTvButtonKind.transport,
                      icon: _seekIcon(step, forward: false),
                      semanticLabel: 'Back $step seconds',
                      onPressed: () => unawaited(_seekRelative(-_seekStep)),
                      onFocusChange: _onControlFocus,
                    ),
                    const SizedBox(width: 12),
                    _ExoTvButton(
                      focusNode: _playFocus,
                      autofocus: true,
                      kind: _ExoTvButtonKind.primary,
                      icon: playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      semanticLabel: playing ? 'Pause' : 'Play',
                      onPressed: () => unawaited(_togglePlay()),
                      onFocusChange: _onControlFocus,
                    ),
                    const SizedBox(width: 12),
                    _ExoTvButton(
                      focusNode: _forwardFocus,
                      kind: _ExoTvButtonKind.transport,
                      icon: _seekIcon(step, forward: true),
                      semanticLabel: 'Forward $step seconds',
                      onPressed: () => unawaited(_seekRelative(_seekStep)),
                      onFocusChange: _onControlFocus,
                    ),
                    Container(
                      width: 1,
                      height: 28,
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      color: Colors.white.withValues(alpha: .16),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < tools.length; i++) ...[
                              if (i > 0) const SizedBox(width: 4),
                              tools[i],
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ExoTvButton(
                      focusNode: _settingsFocus,
                      kind: _ExoTvButtonKind.icon,
                      icon: Icons.tune_rounded,
                      label: 'Settings',
                      semanticLabel: 'Player settings',
                      onPressed: () =>
                          _openPanel(_ExoPanel.settings, opener: _settingsFocus),
                      onFocusChange: _onControlFocus,
                    ),
                    const SizedBox(width: 8),
                    _ExoTvButton(
                      focusNode: _switchFocus,
                      kind: _ExoTvButtonKind.icon,
                      icon: Icons.swap_horiz_rounded,
                      label: 'Switch to MPV',
                      semanticLabel: 'Switch to MPV',
                      onPressed: () => unawaited(_close(switchToMpv: true)),
                      onFocusChange: _onControlFocus,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _seekIcon(int seconds, {required bool forward}) =>
      switch ((seconds, forward)) {
        (5, false) => Icons.replay_5_rounded,
        (5, true) => Icons.forward_5_rounded,
        (10, false) => Icons.replay_10_rounded,
        (10, true) => Icons.forward_10_rounded,
        (30, false) => Icons.replay_30_rounded,
        (30, true) => Icons.forward_30_rounded,
        (_, false) => Icons.fast_rewind_rounded,
        (_, true) => Icons.fast_forward_rounded,
      };

  static String _speedLabel(double speed) {
    final fixed = speed.toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Widget _panelView() {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 640;
    final width = narrow
        ? size.width
        : math.min(_tv ? 500.0 : 440.0, size.width * (_tv ? .4 : .42));
    final (title, items) = switch (_panel) {
      _ExoPanel.subtitles => ('Subtitles', _subtitleItems()),
      _ExoPanel.onlineSubtitles => ('OpenSubtitles', _onlineItems()),
      _ExoPanel.subtitleStyle => ('Subtitle style', _styleItems()),
      _ExoPanel.audio => ('Audio', _audioItems()),
      _ExoPanel.speed => ('Playback speed', _speedItems()),
      _ExoPanel.settings => ('Player settings', _settingsItems()),
      _ExoPanel.info => ('Playback info', _infoItems()),
      _ExoPanel.none => ('', const <Widget>[]),
    };
    final panel = Container(
      width: width,
      height: narrow ? size.height * .78 : size.height,
      decoration: BoxDecoration(
        color: ExoPlayerColors.surface.withValues(alpha: .97),
        border: Border(
          left: narrow
              ? BorderSide.none
              : BorderSide(color: Colors.white.withValues(alpha: .08)),
          top: narrow
              ? BorderSide(color: Colors.white.withValues(alpha: .08))
              : BorderSide.none,
        ),
        borderRadius: narrow
            ? const BorderRadius.vertical(top: Radius.circular(20))
            : null,
      ),
      child: SafeArea(
        left: false,
        child: FocusScope(
          node: _panelScope,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(22, _tv ? 28 : 18, 22, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: ExoPlayerColors.text,
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (_tv)
                        const Text(
                          'Back to close',
                          style: TextStyle(
                            color: ExoPlayerColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_panel == _ExoPanel.subtitleStyle) _stylePreview(),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(12, 0, _tv ? 28 : 12, 18),
                    children: items,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onBack,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: .35),
          child: Align(
            alignment:
                narrow ? Alignment.bottomCenter : Alignment.centerRight,
            child: GestureDetector(onTap: () {}, child: panel),
          ),
        ),
      ),
    );
  }

  Widget _stylePreview() => Container(
        margin: const EdgeInsets.fromLTRB(22, 0, 22, 10),
        height: 92,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: const LinearGradient(
            colors: [Color(0xFF2A3A4A), Color(0xFF6B7F5A), Color(0xFFD9C9A3)],
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ExcludeSemantics(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: ExoSubtitleText(
              text: 'Subtitles look like this\nඋපසිරැසි මෙලෙස පෙනේ',
              style: _style,
              scale: .8,
            ),
          ),
        ),
      );

  List<Widget> _subtitleItems() {
    final tracks = _value.textTracks;
    final embeddedSelected = !_subtitlesOff && _external == null;
    final imageSelected = embeddedSelected &&
        tracks.any((track) => track.selected && track.isBitmapSubtitle);
    return [
      _PanelTile(
        focusNode: _panelFocus,
        title: 'Off',
        selected: _subtitlesOff,
        onPressed: () => unawaited(_subtitlesOffNow()),
      ),
      if (tracks.isNotEmpty) const _PanelHeader('In this video'),
      for (final track in tracks)
        _PanelTile(
          title: track.displayName,
          subtitle: [
            if (track.codecName != null) track.codecName!,
            if (track.isBitmapSubtitle) 'Image subtitles',
            if (track.isAssSubtitle) 'Shown as plain text',
          ].join(' • ').let((text) => text.isEmpty ? null : text),
          selected: embeddedSelected && track.selected,
          enabled: track.supported,
          onPressed: () => unawaited(_selectEmbedded(track)),
        ),
      if (_external != null) ...[
        const _PanelHeader('Loaded'),
        _PanelTile(
          title: _external!.label,
          selected: !_subtitlesOff,
          onPressed: () => unawaited(_applyExternal(_external!)),
        ),
      ],
      const _PanelHeader('More subtitles'),
      _PanelTile(
        icon: Icons.travel_explore_rounded,
        title: 'Search OpenSubtitles',
        subtitle: widget.item == null ? 'Needs title metadata' : null,
        enabled: widget.item != null,
        onPressed: () => _switchPanel(_ExoPanel.onlineSubtitles),
      ),
      if (!_tv)
        _PanelTile(
          icon: Icons.folder_open_rounded,
          title: 'Load subtitle file',
          subtitle: 'SRT, WebVTT, ASS/SSA',
          onPressed: () => unawaited(_loadSubtitleFile()),
        ),
      const _PanelHeader('Style and timing'),
      if (imageSelected)
        const _PanelNote(
          'This track is image subtitles (PGS/VobSub): Media3 draws them as '
          'pictures, so font, color and outline do not change them. Timing '
          'still works.',
        ),
      _AdjustTile(
        label: 'Size',
        value: _style.fontSize.round().toString(),
        onDecrease: () => unawaited(
          _updateStyle(_style.copyWith(fontSize: _style.fontSize - 2)),
        ),
        onIncrease: () => unawaited(
          _updateStyle(_style.copyWith(fontSize: _style.fontSize + 2)),
        ),
      ),
      _AdjustTile(
        label: 'Timing',
        value: _offsetLabel(_subtitleOffset),
        hint: 'Later is +, earlier is −',
        onDecrease: () => unawaited(
          _changeSubtitleOffset(const Duration(milliseconds: -250)),
        ),
        onIncrease: () => unawaited(
          _changeSubtitleOffset(const Duration(milliseconds: 250)),
        ),
      ),
      if (_subtitleOffset != Duration.zero)
        _PanelTile(
          icon: Icons.restart_alt_rounded,
          title: 'Reset timing',
          onPressed: () => unawaited(_changeSubtitleOffset(Duration.zero)),
        ),
      _PanelTile(
        icon: Icons.format_color_text_rounded,
        title: 'Subtitle style',
        subtitle: 'Font, color, outline, background, position',
        onPressed: () => _switchPanel(_ExoPanel.subtitleStyle),
      ),
    ];
  }

  static String _offsetLabel(Duration offset) {
    final seconds = offset.inMilliseconds / 1000;
    final text = seconds.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
    return seconds > 0 ? '+${text}s' : '${text}s';
  }

  static String _percent(double value) => '${(value * 100).round()}%';

  static T _cycle<T>(List<T> values, T current, int direction) {
    final index = values.indexOf(current);
    return values[(index + direction) % values.length];
  }

  int _cycleColor(int current, int direction) {
    final colors = [for (final (_, value) in subtitleColorChoices) value];
    final index = colors.indexWhere((c) => c & 0xFFFFFF == current & 0xFFFFFF);
    return colors[((index < 0 ? 0 : index) + direction) % colors.length];
  }

  List<Widget> _styleItems() {
    final s = _style;
    void update(ExoSubtitleStyle next) => unawaited(_updateStyle(next));
    final shadowEdge = s.edge == SubtitleEdgeStyle.dropShadow ||
        s.edge == SubtitleEdgeStyle.raised ||
        s.edge == SubtitleEdgeStyle.depressed;
    return [
      const _PanelHeader('Text'),
      _AdjustTile(
        focusNode: _panelFocus,
        label: 'Size',
        value: s.fontSize.round().toString(),
        onDecrease: () => update(s.copyWith(fontSize: s.fontSize - 2)),
        onIncrease: () => update(s.copyWith(fontSize: s.fontSize + 2)),
      ),
      _AdjustTile(
        label: 'Font',
        value: s.typeface.label,
        onDecrease: () => update(s.copyWith(
            typeface: _cycle(SubtitleTypeface.values, s.typeface, -1))),
        onIncrease: () => update(s.copyWith(
            typeface: _cycle(SubtitleTypeface.values, s.typeface, 1))),
      ),
      _AdjustTile(
        label: 'Weight',
        value: s.weight.label,
        onDecrease: () => update(
            s.copyWith(weight: _cycle(SubtitleWeight.values, s.weight, -1))),
        onIncrease: () => update(
            s.copyWith(weight: _cycle(SubtitleWeight.values, s.weight, 1))),
      ),
      _AdjustTile(
        label: 'Text color',
        value: subtitleColorName(s.textColor),
        swatch: Color(s.textColor),
        onDecrease: () =>
            update(s.copyWith(textColor: _cycleColor(s.textColor, -1))),
        onIncrease: () =>
            update(s.copyWith(textColor: _cycleColor(s.textColor, 1))),
      ),
      _AdjustTile(
        label: 'Text opacity',
        value: _percent(s.textOpacity),
        onDecrease: () =>
            update(s.copyWith(textOpacity: s.textOpacity - .1)),
        onIncrease: () =>
            update(s.copyWith(textOpacity: s.textOpacity + .1)),
      ),
      const _PanelHeader('Edge'),
      _AdjustTile(
        label: 'Edge style',
        value: s.edge.label,
        onDecrease: () => update(
            s.copyWith(edge: _cycle(SubtitleEdgeStyle.values, s.edge, -1))),
        onIncrease: () => update(
            s.copyWith(edge: _cycle(SubtitleEdgeStyle.values, s.edge, 1))),
      ),
      if (s.edge != SubtitleEdgeStyle.none)
        _AdjustTile(
          label: 'Edge color',
          value: subtitleColorName(s.edgeColor),
          swatch: Color(s.edgeColor),
          onDecrease: () =>
              update(s.copyWith(edgeColor: _cycleColor(s.edgeColor, -1))),
          onIncrease: () =>
              update(s.copyWith(edgeColor: _cycleColor(s.edgeColor, 1))),
        ),
      if (s.edge == SubtitleEdgeStyle.outline)
        _AdjustTile(
          label: 'Outline thickness',
          value: s.outlineWidth.toStringAsFixed(1),
          onDecrease: () =>
              update(s.copyWith(outlineWidth: s.outlineWidth - .5)),
          onIncrease: () =>
              update(s.copyWith(outlineWidth: s.outlineWidth + .5)),
        ),
      if (shadowEdge)
        _AdjustTile(
          label: 'Shadow intensity',
          value: _percent(s.shadowStrength),
          onDecrease: () =>
              update(s.copyWith(shadowStrength: s.shadowStrength - .1)),
          onIncrease: () =>
              update(s.copyWith(shadowStrength: s.shadowStrength + .1)),
        ),
      const _PanelHeader('Background'),
      _AdjustTile(
        label: 'Line background',
        value: s.background ? 'On' : 'Off',
        onDecrease: () => update(s.copyWith(background: !s.background)),
        onIncrease: () => update(s.copyWith(background: !s.background)),
      ),
      if (s.background) ...[
        _AdjustTile(
          label: 'Background color',
          value: subtitleColorName(s.backgroundColor),
          swatch: Color(s.backgroundColor),
          onDecrease: () => update(s.copyWith(
              backgroundColor: _cycleColor(s.backgroundColor, -1))),
          onIncrease: () => update(s.copyWith(
              backgroundColor: _cycleColor(s.backgroundColor, 1))),
        ),
        _AdjustTile(
          label: 'Background opacity',
          value: _percent(s.backgroundOpacity),
          onDecrease: () => update(
              s.copyWith(backgroundOpacity: s.backgroundOpacity - .1)),
          onIncrease: () => update(
              s.copyWith(backgroundOpacity: s.backgroundOpacity + .1)),
        ),
      ],
      _AdjustTile(
        label: 'Window opacity',
        value: _percent(s.windowOpacity),
        onDecrease: () =>
            update(s.copyWith(windowOpacity: s.windowOpacity - .1)),
        onIncrease: () =>
            update(s.copyWith(windowOpacity: s.windowOpacity + .1)),
      ),
      if (s.windowOpacity > 0)
        _AdjustTile(
          label: 'Window color',
          value: subtitleColorName(s.windowColor),
          swatch: Color(s.windowColor),
          onDecrease: () =>
              update(s.copyWith(windowColor: _cycleColor(s.windowColor, -1))),
          onIncrease: () =>
              update(s.copyWith(windowColor: _cycleColor(s.windowColor, 1))),
        ),
      const _PanelHeader('Layout'),
      _AdjustTile(
        label: 'Position',
        value: '${s.bottomOffset.round()}',
        hint: 'Distance from the bottom',
        onDecrease: () =>
            update(s.copyWith(bottomOffset: s.bottomOffset - 8)),
        onIncrease: () =>
            update(s.copyWith(bottomOffset: s.bottomOffset + 8)),
      ),
      _AdjustTile(
        label: 'Alignment',
        value: s.alignment.label,
        onDecrease: () => update(s.copyWith(
            alignment: _cycle(SubtitleAlignment.values, s.alignment, -1))),
        onIncrease: () => update(s.copyWith(
            alignment: _cycle(SubtitleAlignment.values, s.alignment, 1))),
      ),
      _AdjustTile(
        label: 'Line spacing',
        value: s.lineHeight.toStringAsFixed(1),
        onDecrease: () => update(s.copyWith(lineHeight: s.lineHeight - .1)),
        onIncrease: () => update(s.copyWith(lineHeight: s.lineHeight + .1)),
      ),
      const SizedBox(height: 6),
      _PanelTile(
        icon: Icons.restart_alt_rounded,
        title: 'Reset subtitle style',
        subtitle: 'Size, background and position reset for MPV too',
        onPressed: () => unawaited(_resetStyle()),
      ),
    ];
  }

  List<Widget> _onlineItems() {
    return [
      FutureBuilder<List<OnlineSubtitleResult>>(
        future: _searchOnline(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(28),
              child: Center(
                child: CircularProgressIndicator(color: ExoPlayerColors.lime),
              ),
            );
          }
          final results = [...?snapshot.data];
          final preferred =
              OnlineSubtitleService.normalizeLanguage(_preferredLanguage);
          results.sort((a, b) {
            final pa = a.language == preferred ? 0 : 1;
            final pb = b.language == preferred ? 0 : 1;
            if (pa != pb) return pa.compareTo(pb);
            return b.score.compareTo(a.score);
          });
          _ensurePanelFocus();
          if (results.isEmpty) {
            return _PanelTile(
              focusNode: _panelFocus,
              title: 'No online subtitles found',
              subtitle: 'Try another source or load a file.',
              onPressed: () => _switchPanel(_ExoPanel.subtitles),
            );
          }
          return Column(
            children: [
              for (var i = 0; i < results.length && i < 60; i++)
                _PanelTile(
                  focusNode: i == 0 ? _panelFocus : null,
                  title: results[i].languageLabel,
                  subtitle: results[i].label,
                  enabled: !_loadingSubtitle,
                  onPressed: () => unawaited(_loadOnline(results[i])),
                ),
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _audioItems() {
    final tracks = _value.audioTracks;
    if (tracks.isEmpty) {
      return [
        _PanelTile(
          focusNode: _panelFocus,
          title: 'Default audio',
          selected: true,
          onPressed: _closePanel,
        ),
      ];
    }
    return [
      _PanelTile(
        focusNode: _panelFocus,
        icon: Icons.language_rounded,
        title: 'Automatic',
        subtitle: 'Your language when available',
        onPressed: () {
          unawaited(_selectAudio(null));
          _closePanel();
        },
      ),
      for (var i = 0; i < tracks.length; i++)
        _PanelTile(
          title: tracks[i].displayName,
          subtitle: [
            if (tracks[i].codecName != null) tracks[i].codecName!,
            if (tracks[i].sampleRate != null)
              '${(tracks[i].sampleRate! / 1000).toStringAsFixed(1)} kHz',
          ].join(' • ').let((text) => text.isEmpty ? tracks[i].codecs : text),
          selected: tracks[i].selected,
          enabled: tracks[i].supported,
          onPressed: () {
            unawaited(_selectAudio(tracks[i]));
            _closePanel();
          },
        ),
    ];
  }

  List<Widget> _speedItems() {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final current =
        speeds.indexWhere((speed) => (_value.speed - speed).abs() < .01);
    return [
      for (var i = 0; i < speeds.length; i++)
        _PanelTile(
          focusNode: i == (current < 0 ? 2 : current) ? _panelFocus : null,
          title: speeds[i] == 1.0 ? 'Normal' : '${_speedLabel(speeds[i])}x',
          selected: i == current,
          onPressed: () {
            unawaited(_controller?.setSpeed(speeds[i]));
            _closePanel();
          },
        ),
    ];
  }

  List<Widget> _settingsItems() {
    return [
      _AdjustTile(
        focusNode: _panelFocus,
        label: 'Picture',
        value: _aspect.label,
        hint: 'Fit shows everything, Fill crops to the screen',
        onDecrease: () => unawaited(
          _setAspect(_cycle(ExoAspectMode.values, _aspect, -1)),
        ),
        onIncrease: () => unawaited(
          _setAspect(_cycle(ExoAspectMode.values, _aspect, 1)),
        ),
      ),
      _AdjustTile(
        label: 'Zoom level',
        value: _percent(_zoom),
        hint: 'Used by Zoom',
        onDecrease: () => unawaited(_changeZoom(-.05)),
        onIncrease: () => unawaited(_changeZoom(.05)),
      ),
      _AdjustTile(
        label: 'Skip step',
        value: '${_seekStepSeconds}s',
        hint: 'Rewind, Forward and the remote\'s left/right',
        onDecrease: () => unawaited(_cycleSeekStep(-1)),
        onIncrease: () => unawaited(_cycleSeekStep(1)),
      ),
      const _PanelHeader('More'),
      _PanelTile(
        icon: Icons.format_color_text_rounded,
        title: 'Subtitle style',
        onPressed: () => _switchPanel(_ExoPanel.subtitleStyle),
      ),
      _PanelTile(
        icon: Icons.info_outline_rounded,
        title: 'Playback info',
        subtitle: 'Codecs, decoder, network and a copyable report',
        onPressed: () => _switchPanel(_ExoPanel.info),
      ),
      _PanelTile(
        icon: Icons.swap_horiz_rounded,
        title: 'Play with MPV',
        subtitle: 'Opens this source in the MPV player',
        onPressed: () => unawaited(_close(switchToMpv: true)),
      ),
    ];
  }

  List<Widget> _infoItems() {
    final value = _value;
    final video = value.videoTracks.where((t) => t.selected).firstOrNull;
    final audio = value.audioTracks.where((t) => t.selected).firstOrNull;
    final text = value.textTracks.where((t) => t.selected).firstOrNull;
    String mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    final rows = <(String, String)>[
      ('Engine', 'ExoPlayer (Media3)'),
      ('Source', exoMediaKind(widget.url)),
      ('Status', value.started ? value.state.name : value.startupStage.name),
      if (value.hasVideoSize)
        ('Picture', '${value.videoWidth}×${value.videoHeight} • ${_aspect.label}'),
      if (video != null)
        (
          'Video',
          [
            video.codecName ?? video.mimeType ?? '-',
            if (video.frameRate != null)
              '${video.frameRate!.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '')} fps',
            if (video.support != null && video.support != 'handled')
              video.support!,
          ].join(' • ')
        ),
      if (value.videoDecoder != null) ('Video decoder', value.videoDecoder!),
      if (audio != null)
        ('Audio', audio.displayName + (audio.codecName == null ? '' : ' • ${audio.codecName}')),
      if (value.audioDecoder != null) ('Audio decoder', value.audioDecoder!),
      ('Subtitles', _subtitlesOff
          ? 'Off'
          : _external?.label ?? text?.displayName ?? 'None'),
      ('Subtitle tracks', exoSubtitleTrackSummary(value)),
      if (text != null && _external == null && !_subtitlesOff)
        ('Subtitle cues', exoSubtitleCueSummary(value, text)),
      ('Received', mb(value.bytesLoaded)),
      if (value.httpStatus != null) ('HTTP', '${value.httpStatus}'),
      if (value.firstFrame != null)
        ('First frame', '${(value.firstFrame!.inMilliseconds / 1000).toStringAsFixed(1)} s'),
      if (value.droppedFrames > 0) ('Dropped frames', '${value.droppedFrames}'),
      if (value.loadErrors > 0) ('Retried loads', '${value.loadErrors}'),
      if (value.error != null) ('Error', value.error!.code),
    ];
    return [
      _PanelTile(
        focusNode: _panelFocus,
        icon: Icons.copy_rounded,
        title: 'Copy playback report',
        subtitle: 'No links, hashes or account details',
        onPressed: () => unawaited(_copyReport()),
      ),
      const SizedBox(height: 8),
      for (final (label, text) in rows) _InfoRow(label: label, value: text),
    ];
  }

  Widget _errorView() {
    final diagnosis = _errorDiagnosis;
    final suggestMpv = diagnosis?.suggestMpv ?? true;
    final buttons = <Widget>[
      _ExoButton(
        focusNode: suggestMpv ? _errorFocus : null,
        icon: Icons.swap_horiz_rounded,
        label: 'Try MPV',
        semanticLabel: 'Try MPV',
        onPressed: () => unawaited(
          _close(failed: true, switchToMpv: true, error: _error),
        ),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        focusNode: suggestMpv ? null : _errorFocus,
        icon: Icons.refresh_rounded,
        label: 'Retry',
        semanticLabel: 'Retry in ExoPlayer',
        onPressed: () => unawaited(_retry()),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        icon: Icons.info_outline_rounded,
        label: 'Details',
        semanticLabel: 'Playback details',
        onPressed: () => _openPanel(_ExoPanel.info),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        icon: Icons.arrow_back_rounded,
        label: 'Back',
        semanticLabel: 'Back',
        onPressed: () => unawaited(_close(failed: true, error: _error)),
        onFocusChange: _onControlFocus,
      ),
    ];
    return ColoredBox(
      color: ExoPlayerColors.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: ExoPlayerColors.lime,
                    size: 42,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Could not play this stream',
                    style: TextStyle(
                      color: ExoPlayerColors.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (diagnosis != null &&
                      diagnosis.title != 'Could not play this stream') ...[
                    const SizedBox(height: 6),
                    Text(
                      diagnosis.title,
                      style: const TextStyle(
                        color: ExoPlayerColors.lime,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ExoPlayerColors.muted,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: buttons,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: Text(
                label,
                style: const TextStyle(
                  color: ExoPlayerColors.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  color: ExoPlayerColors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}

class _NoticeChip extends StatelessWidget {
  const _NoticeChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: ExoPlayerColors.card.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: ExoPlayerColors.lime.withValues(alpha: .45),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            text,
            style: const TextStyle(
              color: ExoPlayerColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
}

class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.focusNode,
    required this.played,
    required this.buffered,
    required this.onKeyEvent,
    required this.onFocusChange,
    required this.onSeekFraction,
  });

  final FocusNode focusNode;
  final double played;
  final double buffered;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<bool> onFocusChange;
  final ValueChanged<double>? onSeekFraction;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  bool _focused = false;

  void _seekAt(Offset local, double width) {
    if (width <= 0) return;
    widget.onSeekFraction?.call((local.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      label: 'Timeline',
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: widget.onKeyEvent,
        onFocusChange: (value) {
          setState(() => _focused = value);
          widget.onFocusChange(value);
        },
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) =>
                _seekAt(details.localPosition, constraints.maxWidth),
            onHorizontalDragUpdate: (details) =>
                _seekAt(details.localPosition, constraints.maxWidth),
            child: SizedBox(
              height: 28,
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      height: _focused ? 7 : 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: widget.buffered,
                      child: Container(
                        height: _focused ? 7 : 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .30),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: widget.played,
                      child: Container(
                        height: _focused ? 7 : 5,
                        decoration: BoxDecoration(
                          color: ExoPlayerColors.lime,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment(widget.played * 2 - 1, 0),
                        child: Container(
                          width: _focused ? 18 : 12,
                          height: _focused ? 18 : 12,
                          decoration: BoxDecoration(
                            color: _focused
                                ? ExoPlayerColors.lightLime
                                : ExoPlayerColors.lime,
                            shape: BoxShape.circle,
                            border: _focused
                                ? Border.all(color: Colors.white, width: 2)
                                : null,
                          ),
                        ),
                      ),
                    ),
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

class _ExoButton extends StatefulWidget {
  const _ExoButton({
    required this.icon,
    required this.onPressed,
    required this.onFocusChange,
    this.focusNode,
    this.label,
    this.semanticLabel,
    this.prominent = false,
    this.autofocus = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChange;
  final FocusNode? focusNode;
  final String? label;
  final String? semanticLabel;
  final bool prominent;
  final bool autofocus;

  @override
  State<_ExoButton> createState() => _ExoButtonState();
}

class _ExoButtonState extends State<_ExoButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tv = PlatformProfile.isAndroidTv;
    final size = widget.prominent ? (tv ? 64.0 : 60.0) : (tv ? 50.0 : 46.0);
    final radius = BorderRadius.circular(widget.prominent ? size / 2 : 14);
    final foreground = _focused ? ExoPlayerColors.background : ExoPlayerColors.text;
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: AnimatedScale(
        scale: _focused && tv ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _focused
                ? ExoPlayerColors.lime
                : widget.prominent
                    ? ExoPlayerColors.card.withValues(alpha: .92)
                    : ExoPlayerColors.card.withValues(alpha: .80),
            borderRadius: radius,
            border: Border.all(
              color: _focused
                  ? ExoPlayerColors.lightLime
                  : Colors.white.withValues(alpha: .10),
              width: _focused ? 2 : 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              focusColor: Colors.transparent,
              hoverColor: ExoPlayerColors.lime.withValues(alpha: .06),
              splashColor: ExoPlayerColors.lime.withValues(alpha: .12),
              borderRadius: radius,
              onFocusChange: (value) {
                setState(() => _focused = value);
                widget.onFocusChange(value);
              },
              onTap: widget.onPressed,
              child: SizedBox(
                height: size,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.label == null ? 0 : 14,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: widget.label == null ? size - 2 : 24,
                        child: Icon(
                          widget.icon,
                          color: foreground,
                          size: widget.prominent ? 32 : 24,
                        ),
                      ),
                      if (widget.label != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          widget.label!,
                          style: TextStyle(
                            color: foreground,
                            fontSize: tv ? 14 : 13,
                            fontWeight: FontWeight.w800,
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
      ),
    );
  }
}

/// A short, non-focusable explanation inside a player menu.
class _PanelNote extends StatelessWidget {
  const _PanelNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        child: Text(
          text,
          style: const TextStyle(
            color: ExoPlayerColors.muted,
            fontSize: 12.5,
            height: 1.35,
          ),
        ),
      );
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: ExoPlayerColors.muted,
            fontSize: 11,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

class _PanelTile extends StatefulWidget {
  const _PanelTile({
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.focusNode,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<_PanelTile> createState() => _PanelTileState();
}

class _PanelTileState extends State<_PanelTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // TV: focus is a white row with dark text, selection a lime check, so a
    // focused row never looks selected (the player controls do the same).
    final tvFocus = _focused && PlatformProfile.isAndroidTv;
    final color = tvFocus
        ? ExoPlayerColors.background
        : widget.enabled
            ? (widget.selected || _focused
                ? ExoPlayerColors.lime
                : ExoPlayerColors.text)
            : ExoPlayerColors.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        decoration: BoxDecoration(
          color: tvFocus
              ? Colors.white
              : _focused
                  ? ExoPlayerColors.lime.withValues(alpha: .14)
                  : widget.selected
                      ? ExoPlayerColors.card
                      : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused && !tvFocus
                ? ExoPlayerColors.lime
                : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusNode: widget.focusNode,
            canRequestFocus: widget.enabled,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            onFocusChange: (value) => setState(() => _focused = value),
            onTap: widget.enabled ? widget.onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, color: color, size: 20),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (widget.subtitle != null)
                          Text(
                            widget.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: tvFocus
                                  ? const Color(0xFF465048)
                                  : ExoPlayerColors.muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.selected)
                    Icon(
                      Icons.check_rounded,
                      color: tvFocus
                          ? ExoPlayerColors.background
                          : ExoPlayerColors.lime,
                      size: 20,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One adjustable setting: a single focusable row. On a remote, Left and
/// Right change the value and OK steps it forward; on touch, the − and +
/// buttons do the same. Up/Down move between rows, so the row never traps
/// focus.
class _AdjustTile extends StatefulWidget {
  const _AdjustTile({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    this.hint,
    this.swatch,
    this.focusNode,
  });

  final String label;
  final String value;
  final String? hint;
  final Color? swatch;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final FocusNode? focusNode;

  @override
  State<_AdjustTile> createState() => _AdjustTileState();
}

class _AdjustTileState extends State<_AdjustTile> {
  bool _focused = false;

  /// TV focus: a white row with dark content, as in [_PanelTileState].
  bool get _tvFocus => _focused && PlatformProfile.isAndroidTv;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onDecrease();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.onIncrease();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space)) {
      widget.onIncrease();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _step(IconData icon, String semantic, VoidCallback onPressed) =>
      Semantics(
        button: true,
        label: semantic,
        child: ExcludeFocus(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onPressed,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                icon,
                size: 20,
                color: _tvFocus
                    ? ExoPlayerColors.background
                    : _focused
                        ? ExoPlayerColors.lime
                        : ExoPlayerColors.text,
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _onKey,
        onFocusChange: (value) => setState(() => _focused = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: _tvFocus
                ? Colors.white
                : _focused
                    ? ExoPlayerColors.lime.withValues(alpha: .14)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused && !_tvFocus
                  ? ExoPlayerColors.lime
                  : Colors.transparent,
              width: 1.6,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: _tvFocus
                              ? ExoPlayerColors.background
                              : _focused
                                  ? ExoPlayerColors.lime
                                  : ExoPlayerColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.hint != null)
                        Text(
                          widget.hint!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _tvFocus
                                ? const Color(0xFF465048)
                                : ExoPlayerColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                    ],
                  ),
                ),
                _step(Icons.remove_rounded, '${widget.label} down',
                    widget.onDecrease),
                if (widget.swatch != null)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: widget.swatch,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .5),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 92,
                  child: Text(
                    widget.value,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _tvFocus
                          ? ExoPlayerColors.background
                          : ExoPlayerColors.lime,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _step(Icons.add_rounded, '${widget.label} up',
                    widget.onIncrease),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ExoTvButtonKind {
  /// Play/Pause: the one strong control.
  primary,

  /// Skip back/forward and Back: round, quiet until focused.
  transport,

  /// A labelled tool (Subtitles, Audio, speed, picture, next episode).
  tool,

  /// An icon that shows its label while focused (Settings, MPV).
  icon,
}

/// Android TV player button. Focus is a white fill with dark content (lime
/// for Play/Pause), so focus never looks like a selected state or a glow.
class _ExoTvButton extends StatefulWidget {
  const _ExoTvButton({
    required this.icon,
    required this.onPressed,
    required this.onFocusChange,
    required this.kind,
    this.focusNode,
    this.label,
    this.semanticLabel,
    this.autofocus = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChange;
  final _ExoTvButtonKind kind;
  final FocusNode? focusNode;
  final String? label;
  final String? semanticLabel;
  final bool autofocus;

  @override
  State<_ExoTvButton> createState() => _ExoTvButtonState();
}

class _ExoTvButtonState extends State<_ExoTvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final focused = _focused;
    final kind = widget.kind;
    final round = kind == _ExoTvButtonKind.primary ||
        kind == _ExoTvButtonKind.transport;
    final size = switch (kind) {
      _ExoTvButtonKind.primary => 58.0,
      _ExoTvButtonKind.transport => 46.0,
      _ExoTvButtonKind.tool || _ExoTvButtonKind.icon => 44.0,
    };
    final Color fill;
    final Color foreground;
    switch (kind) {
      case _ExoTvButtonKind.primary:
        fill = focused ? ExoPlayerColors.lime : Colors.white.withValues(alpha: .92);
        foreground = ExoPlayerColors.background;
      case _ExoTvButtonKind.transport:
      case _ExoTvButtonKind.icon:
        fill = focused ? Colors.white : Colors.white.withValues(alpha: .12);
        foreground = focused ? ExoPlayerColors.background : ExoPlayerColors.text;
      case _ExoTvButtonKind.tool:
        fill = focused ? Colors.white : Colors.transparent;
        foreground = focused
            ? ExoPlayerColors.background
            : ExoPlayerColors.text.withValues(alpha: .9);
    }
    final showLabel = widget.label != null && kind == _ExoTvButtonKind.tool;
    // Icon buttons name themselves in a small label above while focused,
    // without changing width, so nothing next to them moves.
    final floatingLabel =
        widget.label != null && kind == _ExoTvButtonKind.icon && focused;
    final radius = BorderRadius.circular(size / 2);
    final iconSize = switch (kind) {
      _ExoTvButtonKind.primary => 34.0,
      _ExoTvButtonKind.transport => 26.0,
      _ => 22.0,
    };
    final button = Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: AnimatedScale(
        scale: focused && kind == _ExoTvButtonKind.primary ? 1.08 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(color: fill, borderRadius: radius),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              focusColor: Colors.transparent,
              hoverColor: Colors.white.withValues(alpha: .06),
              splashColor: Colors.white.withValues(alpha: .1),
              borderRadius: radius,
              onFocusChange: (value) {
                setState(() => _focused = value);
                widget.onFocusChange(value);
              },
              onTap: widget.onPressed,
              child: SizedBox(
                height: size,
                width: round || kind == _ExoTvButtonKind.icon ? size : null,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: showLabel ? 16 : 0,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(widget.icon, color: foreground, size: iconSize),
                      if (showLabel) ...[
                        const SizedBox(width: 8),
                        Text(
                          widget.label!,
                          maxLines: 1,
                          style: TextStyle(
                            color: foreground,
                            fontSize: 14.5,
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
      ),
    );
    if (kind != _ExoTvButtonKind.icon || widget.label == null) return button;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        button,
        Positioned(
          bottom: size + 10,
          right: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: floatingLabel ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.label!,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: ExoPlayerColors.background,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the TV buffering indicator says during mid-playback buffering.
enum ExoBufferPhase {
  /// A short stall: a small ring only.
  brief,

  /// Long buffering while data keeps arriving.
  receiving,

  /// Long buffering of a local torrent with no new data.
  waitingForPeers,

  /// Long buffering of a remote source with no new data.
  slowSource,
}

@immutable
class ExoBufferingStatus {
  const ExoBufferingStatus(this.phase, {this.title, this.detail});

  final ExoBufferPhase phase;
  final String? title;
  final String? detail;
}

/// Describes mid-playback buffering from what the player really reports:
/// how long it has lasted and how many bytes arrived since it began. There
/// is no deadline: a slow Free P2P torrent keeps waiting.
ExoBufferingStatus exoBufferingStatus({
  required bool localP2p,
  required Duration bufferingFor,
  required int bytesSinceStart,
}) {
  if (bufferingFor < AndroidExoPlayerScreen.slowBufferNoticeAfter) {
    return const ExoBufferingStatus(ExoBufferPhase.brief);
  }
  if (bytesSinceStart > 0) {
    final mb = bytesSinceStart / (1024 * 1024);
    final amount = mb < 1
        ? '${(bytesSinceStart / 1024).round()} KB'
        : mb < 10
            ? '${mb.toStringAsFixed(1)} MB'
            : '${mb.round()} MB';
    return ExoBufferingStatus(
      ExoBufferPhase.receiving,
      title: 'Buffering',
      detail: localP2p
          ? '$amount from peers so far'
          : '$amount received so far',
    );
  }
  return localP2p
      ? const ExoBufferingStatus(
          ExoBufferPhase.waitingForPeers,
          title: 'Waiting for peers…',
          detail: 'No new data yet. Orvix keeps waiting; Back picks another '
              'source.',
        )
      : const ExoBufferingStatus(
          ExoBufferPhase.slowSource,
          title: 'Buffering…',
          detail: 'The source is slow to send data.',
        );
}

/// Mid-playback buffering on TV: a small ring for a short stall, then a
/// compact translucent pill that says what is happening. It never takes
/// focus and leaves the picture visible.
class _TvBufferingIndicator extends StatelessWidget {
  const _TvBufferingIndicator({required this.status, required this.lifted});

  final ExoBufferingStatus status;

  /// The controls are showing: sit above the bottom cluster.
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    const ring = CircularProgressIndicator(
      strokeWidth: 2.5,
      color: ExoPlayerColors.lime,
    );
    final Widget content;
    if (status.phase == ExoBufferPhase.brief) {
      content = Container(
        key: const ValueKey('exo-tv-buffering-ring'),
        width: 52,
        height: 52,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .45),
          shape: BoxShape.circle,
        ),
        child: ring,
      );
    } else {
      content = Container(
        key: const ValueKey('exo-tv-buffering-pill'),
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.fromLTRB(16, 11, 22, 11),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: .1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 20, height: 20, child: ring),
            const SizedBox(width: 14),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.title ?? '',
                    style: const TextStyle(
                      color: ExoPlayerColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (status.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      status.detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ExoPlayerColors.muted,
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }
    return IgnorePointer(
      child: ExcludeFocus(
        child: Semantics(
          liveRegion: true,
          label: status.title ?? 'Buffering',
          child: Align(
            alignment: lifted ? const Alignment(0, -.1) : Alignment.center,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
