import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/external_subtitle_track.dart';
import '../services/local_p2p_startup_policy.dart';
import '../services/local_torrent_service.dart';
import '../services/media_state_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/orvix_exo_player.dart';
import '../services/platform_profile.dart';
import '../services/skip_segment_service.dart';
import '../services/subtitle_file_picker.dart';
import '../services/subtitle_preferences_service.dart';
import '../widgets/player_loading_overlay.dart';

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

enum ExoAspectMode { fit, fill, zoom }

extension ExoAspectModeLabel on ExoAspectMode {
  String get label => switch (this) {
        ExoAspectMode.fit => 'Fit',
        ExoAspectMode.fill => 'Fill',
        ExoAspectMode.zoom => 'Zoom',
      };

  BoxFit get fit => switch (this) {
        ExoAspectMode.fit => BoxFit.contain,
        ExoAspectMode.fill => BoxFit.fill,
        ExoAspectMode.zoom => BoxFit.cover,
      };
}

enum _ExoPanel { none, subtitles, onlineSubtitles, audio, speed }

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

  static Future<String> _downloadSubtitle(OnlineSubtitleResult result) async {
    final file = await OnlineSubtitleService.materialize(result);
    return decodeSubtitleBytes(await file.readAsBytes());
  }

  /// Subtitle files are often Windows-1252/Latin-1 rather than UTF-8.
  @visibleForTesting
  static String decodeSubtitleBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  final String url;
  final String title;
  final MediaStateService? mediaState;
  final MediaItem? item;
  final EpisodeItem? episode;
  final Map<String, String>? httpHeaders;
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

class _AndroidExoPlayerScreenState extends State<AndroidExoPlayerScreen> {
  final FocusNode _surfaceFocus = FocusNode(debugLabel: 'exo-surface');
  final FocusNode _backFocus = FocusNode(debugLabel: 'exo-back');
  final FocusNode _timelineFocus = FocusNode(debugLabel: 'exo-timeline');
  final FocusNode _playFocus = FocusNode(debugLabel: 'exo-play');
  final FocusNode _switchFocus = FocusNode(debugLabel: 'exo-switch');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'exo-panel-first');

  OrvixExoController? _controller;
  OrvixExoValue _value = const OrvixExoValue();
  Timer? _hideTimer;
  Timer? _saveTimer;
  Timer? _startupTimer;
  Timer? _autoSubtitleTimer;
  Timer? _noticeTimer;
  // External subtitles are timed in Dart: the native position arrives every
  // 500 ms, so it is extrapolated between reports and repainted often.
  final Stopwatch _sinceState = Stopwatch()..start();
  Timer? _externalSubtitleTimer;
  LocalP2pStartupMonitor? _p2pStartup;
  final ExoP2pRetryPolicy _p2pRetry = ExoP2pRetryPolicy();
  bool _controlsVisible = true;
  bool _closing = false;
  bool _started = false;
  bool _reopening = false;
  bool _slowStartNotice = false;
  String? _error;
  String? _notice;
  Duration _lastPosition = Duration.zero;
  Timer? _attemptTimer;
  bool _attemptWasLong = false;

  // Android local Free P2P: a torrent that has not delivered video yet is
  // still connecting. The native player retries reads for as long as it is
  // open, and only real terminal evidence ends the attempt.
  late final bool _localP2p =
      LocalP2pStartupPolicy.appliesTo(isAndroid: true, url: widget.url);

  _ExoPanel _panel = _ExoPanel.none;
  ExoAspectMode _aspect = ExoAspectMode.fit;
  ExternalSubtitleTrack? _external;
  bool _subtitlesOff = false;
  bool _userChoseSubtitle = false;
  Duration _subtitleOffset = Duration.zero;
  double _subtitleFontSize = SubtitlePreferencesService.defaultFontSize;
  bool _subtitleBackground = SubtitlePreferencesService.defaultBackground;
  double _subtitleBackgroundOpacity =
      SubtitlePreferencesService.defaultBackgroundOpacity;
  double _subtitleBottomOffset = SubtitlePreferencesService.defaultBottomOffset;
  String _preferredLanguage = SubtitlePreferencesService.defaultPreferredLanguage;
  Future<List<OnlineSubtitleResult>>? _onlineSearch;
  bool _loadingSubtitle = false;

  List<SkipSegment> _skipSegments = const [];
  SkipSegment? _activeSkipSegment;
  bool _skipDismissed = false;

  bool get _tv => PlatformProfile.isAndroidTv;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    unawaited(_loadSkipSegments());
  }

  Future<void> _start() async {
    await _loadSubtitlePreferences();
    if (!mounted || _closing) return;
    await _open();
  }

  Future<void> _loadSubtitlePreferences() async {
    try {
      final values = await Future.wait<Object>([
        SubtitlePreferencesService.fontSize(),
        SubtitlePreferencesService.backgroundEnabled(),
        SubtitlePreferencesService.backgroundOpacity(),
        SubtitlePreferencesService.bottomOffset(),
        SubtitlePreferencesService.preferredLanguage(),
      ]);
      if (!mounted) return;
      setState(() {
        _subtitleFontSize = values[0] as double;
        _subtitleBackground = values[1] as bool;
        _subtitleBackgroundOpacity = values[2] as double;
        _subtitleBottomOffset = values[3] as double;
        _preferredLanguage = values[4] as String;
      });
    } catch (_) {
      // Defaults stay in place; subtitles still render.
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
    final controller = OrvixExoController(
      url: widget.url,
      headers: widget.httpHeaders ?? const <String, String>{},
      patientStartup: _localP2p,
      preferredTextLanguage: _preferredLanguage,
      preferredAudioLanguage: 'en',
      startPosition: start,
    );
    _controller = controller;
    controller.addListener(_onValue);
    _attemptWasLong = false;
    _attemptTimer?.cancel();
    _attemptTimer = Timer(_p2pRetry.rapidFailure, () => _attemptWasLong = true);
    try {
      await controller.open();
    } catch (error) {
      if (!mounted || _closing || !identical(_controller, controller)) return;
      await _fail('ExoPlayer could not open this stream: $error');
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
      _startupTimer ??= Timer(const Duration(seconds: 35), () {
        if (_started || _closing) return;
        unawaited(_fail(
          'ExoPlayer could not initialize this stream within 35 seconds.',
        ));
      });
    }
  }

  void _onValue() {
    final controller = _controller;
    if (controller == null || !mounted || _closing) return;
    final value = controller.value;
    if (value.position > Duration.zero) _lastPosition = value.position;

    if (!_started && value.started) {
      _started = true;
      _startupTimer?.cancel();
      _p2pStartup?.stop();
      _attemptTimer?.cancel();
      _slowStartNotice = false;
      _saveTimer?.cancel();
      _saveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_persistProgress()),
      );
      _scheduleAutoSubtitle();
      // On TV the remote lands on Play/Pause; touch keeps the surface.
      _showControls(focusPlay: _tv);
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
    final message = value.errorMessage?.trim().isNotEmpty == true
        ? value.errorMessage!
        : 'ExoPlayer reported a playback error.';
    if (!_localP2p) {
      await _fail('ExoPlayer could not play this stream: $message');
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
        await _fail('ExoPlayer could not play this stream: $message');
        return;
      }
      if (_p2pRetry.attempts <= 3) {
        widget.onStartupStage?.call('playerError', 'transient', {
          'code': value.errorCode,
          'count': _p2pRetry.attempts,
        });
      }
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

  Future<void> _fail(String message) async {
    if (!mounted || _closing) return;
    _startupTimer?.cancel();
    _p2pStartup?.stop();
    _hideTimer?.cancel();
    setState(() {
      _error = message;
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
      if (mounted) _switchFocus.requestFocus();
    });
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
  /// preferred language is loaded, as the MPV player does.
  Future<void> _autoSelectSubtitle() async {
    if (!mounted || _closing || _userChoseSubtitle || _subtitlesOff) return;
    if (_external != null) return;
    final text = _value.textTracks;
    if (text.any((track) => track.selected)) return;
    final preferred = text.where(
      (track) =>
          track.supported &&
          OnlineSubtitleService.normalizeLanguage(track.language ?? '') ==
              OnlineSubtitleService.normalizeLanguage(_preferredLanguage),
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
      final language = OnlineSubtitleService.normalizeLanguage(
        _preferredLanguage,
      );
      final match = results.where((r) => r.language == language).toList();
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

  Future<void> _selectEmbedded(
    OrvixExoTrack track, {
    bool userChoice = true,
  }) async {
    if (userChoice) _userChoseSubtitle = true;
    setState(() {
      _external = null;
      _subtitlesOff = false;
    });
    _syncExternalSubtitleTimer();
    await _controller?.selectTextTrack(track);
    if (userChoice) {
      _showNotice('Subtitles: ${track.displayName}');
      _closePanel();
    }
  }

  Future<void> _subtitlesOffNow() async {
    _userChoseSubtitle = true;
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
    if (userChoice) _userChoseSubtitle = true;
    setState(() {
      _external = track;
      _subtitlesOff = false;
    });
    _syncExternalSubtitleTimer();
    await _controller?.selectTextTrack(null);
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

  Future<void> _changeSubtitleOffset(Duration delta) async {
    final next = delta == Duration.zero ? Duration.zero : _subtitleOffset + delta;
    setState(() => _subtitleOffset = next);
    await _controller?.setSubtitleOffset(next);
  }

  Future<void> _changeFontSize(double delta) async {
    final next = (_subtitleFontSize + delta).clamp(18.0, 72.0).toDouble();
    setState(() => _subtitleFontSize = next);
    try {
      await SubtitlePreferencesService.setFontSize(next);
    } catch (_) {}
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

  Future<void> _seekRelative(Duration offset) async {
    final controller = _controller;
    if (controller == null || !_started) return;
    var target = _value.position + offset;
    if (target < Duration.zero) target = Duration.zero;
    final duration = _value.duration;
    if (duration > Duration.zero && target > duration) target = duration;
    await controller.seekTo(target);
    _showControls();
  }

  void _openPanel(_ExoPanel panel) {
    _hideTimer?.cancel();
    setState(() {
      _panel = panel;
      _controlsVisible = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelFocus.requestFocus();
    });
  }

  void _closePanel() {
    if (_panel == _ExoPanel.none) return;
    setState(() => _panel = _ExoPanel.none);
    _showControls(focusPlay: true);
  }

  void _cycleAspect() {
    setState(() {
      _aspect = ExoAspectMode.values[
          (_aspect.index + 1) % ExoAspectMode.values.length];
    });
    _showNotice('Aspect: ${_aspect.label}');
    _showControls();
  }

  void _onBack() {
    if (_panel == _ExoPanel.onlineSubtitles) {
      setState(() => _panel = _ExoPanel.subtitles);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _panelFocus.requestFocus();
      });
      return;
    }
    if (_panel != _ExoPanel.none) {
      _closePanel();
      return;
    }
    if (_tv && _controlsVisible && _started && _error == null) {
      _hideControls();
      return;
    }
    unawaited(_close(failed: _error != null, error: _error));
  }

  KeyEventResult _onSurfaceKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // A real control owns focus: let Flutter's focus traversal and
    // ActivateAction handle DPAD and OK.
    if (!_surfaceFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_controlsVisible) {
        unawaited(_togglePlay());
      } else {
        _showControls(focusPlay: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      unawaited(_seekRelative(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(_seekRelative(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onTimelineKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekRelative(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekRelative(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      unawaited(_togglePlay());
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
    _startupTimer?.cancel();
    _autoSubtitleTimer?.cancel();
    _externalSubtitleTimer?.cancel();
    _attemptTimer?.cancel();
    _p2pStartup?.stop();

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
    _closing = true;
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _startupTimer?.cancel();
    _autoSubtitleTimer?.cancel();
    _noticeTimer?.cancel();
    _externalSubtitleTimer?.cancel();
    _attemptTimer?.cancel();
    _p2pStartup?.stop();
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onValue);
      controller.dispose();
    }
    _surfaceFocus.dispose();
    _backFocus.dispose();
    _timelineFocus.dispose();
    _playFocus.dispose();
    _switchFocus.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final showLoading = !_started && _error == null;
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
              if (!_started) return;
              final width = MediaQuery.sizeOf(context).width;
              unawaited(_seekRelative(
                details.localPosition.dx < width / 2
                    ? const Duration(seconds: -10)
                    : const Duration(seconds: 10),
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
                    message: _slowStartNotice
                        ? 'Still connecting to peers…'
                        : 'Starting playback…',
                    detail: _slowStartNotice
                        ? 'This torrent is starting slowly. Keep waiting, '
                            'or go Back to choose another source.'
                        : widget.episode == null
                            ? null
                            : widget.title,
                  ),
                if (_started && value.buffering && _error == null)
                  const Center(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: ExoPlayerColors.lime,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                if (_controlsVisible && _error == null && _started)
                  _controls(value),
                if (showLoading) _loadingBackButton(),
                if (_activeSkipSegment != null && !_skipDismissed &&
                    _error == null)
                  Positioned(
                    left: 28,
                    bottom: _controlsVisible ? 150 : 40,
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
                    child: Center(child: _NoticeChip(text: _notice!)),
                  ),
                if (_panel != _ExoPanel.none && _error == null) _panelView(),
                if (_error != null) _errorView(),
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
    var width = value.hasVideoSize ? value.videoWidth.toDouble() : 1920.0;
    var height = value.hasVideoSize ? value.videoHeight.toDouble() : 1080.0;
    if (quarterTurns.isOdd) {
      final swap = width;
      width = height;
      height = swap;
    }
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: _aspect.fit,
          child: SizedBox(width: width, height: height, child: texture),
        ),
      ),
    );
  }

  Widget _subtitleLayer(OrvixExoValue value) {
    final lines = _subtitleLines;
    final bitmaps =
        _subtitlesOff || _external != null ? const <OrvixExoBitmapCue>[] : value.bitmapCues;
    if (lines.isEmpty && bitmaps.isEmpty) return const SizedBox.shrink();
    final lift = _controlsVisible && _started ? 132.0 : 0.0;
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final videoRect = _videoRect(constraints.biggest, value);
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
                    left: 24,
                    right: 24,
                    bottom: _subtitleBottomOffset + lift,
                    child: Center(
                      child: _SubtitleText(
                        text: lines.join('\n'),
                        fontSize: _subtitleFontSize * (_tv ? 1.0 : .82),
                        background: _subtitleBackground,
                        backgroundOpacity: _subtitleBackgroundOpacity,
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

  Rect _videoRect(Size box, OrvixExoValue value) {
    final ratio = value.aspectRatio;
    if (_aspect == ExoAspectMode.fill || box.isEmpty) return Offset.zero & box;
    final boxRatio = box.width / box.height;
    final contain = _aspect == ExoAspectMode.fit;
    final widthBound = contain ? ratio >= boxRatio : ratio < boxRatio;
    final width = widthBound ? box.width : box.height * ratio;
    final height = widthBound ? box.width / ratio : box.height;
    return Rect.fromLTWH(
      (box.width - width) / 2,
      (box.height - height) / 2,
      width,
      height,
    );
  }

  Widget _loadingBackButton() => Positioned(
        top: 0,
        left: 0,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
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
    final position = value.position;
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
    final hasEmbeddedText = value.textTracks.isNotEmpty;
    final subtitleLabel = _subtitlesOff
        ? 'Subtitles off'
        : _external != null
            ? 'Subtitles'
            : hasEmbeddedText
                ? 'Subtitles'
                : 'Subtitles';

    final buttons = <Widget>[
      _ExoButton(
        icon: Icons.replay_10_rounded,
        semanticLabel: 'Back 10 seconds',
        onPressed: () => unawaited(_seekRelative(const Duration(seconds: -10))),
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
        icon: Icons.forward_10_rounded,
        semanticLabel: 'Forward 10 seconds',
        onPressed: () => unawaited(_seekRelative(const Duration(seconds: 10))),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        icon: Icons.closed_caption_rounded,
        label: compact ? null : subtitleLabel,
        semanticLabel: 'Subtitles',
        onPressed: () => _openPanel(_ExoPanel.subtitles),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        icon: Icons.audiotrack_rounded,
        label: compact ? null : 'Audio',
        semanticLabel: 'Audio',
        onPressed: () => _openPanel(_ExoPanel.audio),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
        icon: Icons.speed_rounded,
        label: compact ? null : '${_speedLabel(value.speed)}x',
        semanticLabel: 'Playback speed',
        onPressed: () => _openPanel(_ExoPanel.speed),
        onFocusChange: _onControlFocus,
      ),
      _ExoButton(
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
                padding: EdgeInsets.fromLTRB(compact ? 12 : 28, 14,
                    compact ? 12 : 28, 0),
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
                            style: const TextStyle(
                              color: ExoPlayerColors.text,
                              fontSize: 17,
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
                padding: EdgeInsets.fromLTRB(compact ? 14 : 36, 0,
                    compact ? 14 : 36, compact ? 14 : 26),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          _format(position),
                          style: const TextStyle(
                            color: ExoPlayerColors.text,
                            fontSize: 12,
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
                        Text(
                          _format(duration),
                          style: const TextStyle(
                            color: ExoPlayerColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
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

  static String _speedLabel(double speed) {
    final fixed = speed.toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Widget _panelView() {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 640;
    final width = narrow ? size.width : math.min(440.0, size.width * .42);
    final (title, items) = switch (_panel) {
      _ExoPanel.subtitles => ('Subtitles', _subtitleItems()),
      _ExoPanel.onlineSubtitles => ('OpenSubtitles', _onlineItems()),
      _ExoPanel.audio => ('Audio', _audioItems()),
      _ExoPanel.speed => ('Playback speed', _speedItems()),
      _ExoPanel.none => ('', const <Widget>[]),
    };
    final panel = Container(
      width: width,
      height: narrow ? size.height * .72 : size.height,
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
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: ExoPlayerColors.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                  children: items,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closePanel,
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

  List<Widget> _subtitleItems() {
    final tracks = _value.textTracks;
    final embeddedSelected = !_subtitlesOff && _external == null;
    var first = true;
    FocusNode? firstFocus() {
      if (!first) return null;
      first = false;
      return _panelFocus;
    }

    return [
      _PanelTile(
        focusNode: firstFocus(),
        title: 'Off',
        selected: _subtitlesOff,
        onPressed: () => unawaited(_subtitlesOffNow()),
      ),
      if (tracks.isNotEmpty) const _PanelHeader('In this video'),
      for (final track in tracks)
        _PanelTile(
          title: track.displayName,
          subtitle: track.isBitmapSubtitle ? 'Image subtitles' : null,
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
        onPressed: () => setState(() {
          _panel = _ExoPanel.onlineSubtitles;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _panelFocus.requestFocus();
          });
        }),
      ),
      if (!_tv)
        _PanelTile(
          icon: Icons.folder_open_rounded,
          title: 'Load subtitle file',
          subtitle: 'SRT, WebVTT, ASS/SSA',
          onPressed: () => unawaited(_loadSubtitleFile()),
        ),
      const _PanelHeader('Style and timing'),
      _StepperTile(
        label: 'Size',
        value: _subtitleFontSize.round().toString(),
        onMinus: () => unawaited(_changeFontSize(-2)),
        onPlus: () => unawaited(_changeFontSize(2)),
      ),
      _StepperTile(
        label: 'Timing',
        value: _offsetLabel(_subtitleOffset),
        onMinus: () => unawaited(
          _changeSubtitleOffset(const Duration(milliseconds: -250)),
        ),
        onPlus: () => unawaited(
          _changeSubtitleOffset(const Duration(milliseconds: 250)),
        ),
      ),
      if (_subtitleOffset != Duration.zero)
        _PanelTile(
          icon: Icons.restart_alt_rounded,
          title: 'Reset timing',
          onPressed: () => unawaited(_changeSubtitleOffset(Duration.zero)),
        ),
    ];
  }

  static String _offsetLabel(Duration offset) {
    final seconds = offset.inMilliseconds / 1000;
    final text = seconds.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
    return seconds > 0 ? '+${text}s' : '${text}s';
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
          if (results.isEmpty) {
            return _PanelTile(
              focusNode: _panelFocus,
              title: 'No online subtitles found',
              subtitle: 'Try another source or load a file.',
              onPressed: () => setState(() => _panel = _ExoPanel.subtitles),
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
      for (var i = 0; i < tracks.length; i++)
        _PanelTile(
          focusNode: i == 0 ? _panelFocus : null,
          title: tracks[i].displayName,
          subtitle: tracks[i].codecs,
          selected: tracks[i].selected,
          enabled: tracks[i].supported,
          onPressed: () {
            unawaited(_controller?.selectAudioTrack(tracks[i]));
            _closePanel();
          },
        ),
    ];
  }

  List<Widget> _speedItems() {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return [
      for (var i = 0; i < speeds.length; i++)
        _PanelTile(
          focusNode: i == 0 ? _panelFocus : null,
          title: speeds[i] == 1.0 ? 'Normal' : '${_speedLabel(speeds[i])}x',
          selected: (_value.speed - speeds[i]).abs() < .01,
          onPressed: () {
            unawaited(_controller?.setSpeed(speeds[i]));
            _closePanel();
          },
        ),
    ];
  }

  Widget _errorView() {
    return ColoredBox(
      color: ExoPlayerColors.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(28),
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
                  children: [
                    _ExoButton(
                      focusNode: _switchFocus,
                      icon: Icons.swap_horiz_rounded,
                      label: 'Try MPV',
                      semanticLabel: 'Try MPV',
                      onPressed: () => unawaited(
                        _close(failed: true, switchToMpv: true, error: _error),
                      ),
                      onFocusChange: _onControlFocus,
                    ),
                    _ExoButton(
                      icon: Icons.arrow_back_rounded,
                      label: 'Back',
                      semanticLabel: 'Back',
                      onPressed: () =>
                          unawaited(_close(failed: true, error: _error)),
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
}

class _SubtitleText extends StatelessWidget {
  const _SubtitleText({
    required this.text,
    required this.fontSize,
    required this.background,
    required this.backgroundOpacity,
  });

  final String text;
  final double fontSize;
  final bool background;
  final double backgroundOpacity;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      height: 1.25,
      fontWeight: FontWeight.w600,
      shadows: background
          ? null
          : const [
              Shadow(blurRadius: 3, color: Colors.black),
              Shadow(offset: Offset(1, 1), blurRadius: 2, color: Colors.black),
            ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background
            ? Colors.black.withValues(alpha: backgroundOpacity)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(text, textAlign: TextAlign.center, style: style),
      ),
    );
  }
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
    return Focus(
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
    final size = widget.prominent ? 60.0 : 46.0;
    final radius = BorderRadius.circular(widget.prominent ? 30 : 14);
    final foreground = _focused ? ExoPlayerColors.lime : ExoPlayerColors.text;
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _focused
              ? ExoPlayerColors.lime.withValues(alpha: .16)
              : widget.prominent
                  ? ExoPlayerColors.card.withValues(alpha: .92)
                  : ExoPlayerColors.card.withValues(alpha: .80),
          borderRadius: radius,
          border: Border.all(
            color: _focused
                ? ExoPlayerColors.lime
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
                          fontSize: 13,
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
    );
  }
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
    final color = widget.enabled
        ? (widget.selected || _focused
            ? ExoPlayerColors.lime
            : ExoPlayerColors.text)
        : ExoPlayerColors.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        decoration: BoxDecoration(
          color: _focused
              ? ExoPlayerColors.lime.withValues(alpha: .14)
              : widget.selected
                  ? ExoPlayerColors.card
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? ExoPlayerColors.lime : Colors.transparent,
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
                            style: const TextStyle(
                              color: ExoPlayerColors.muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.selected)
                    const Icon(
                      Icons.check_rounded,
                      color: ExoPlayerColors.lime,
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

class _StepperTile extends StatelessWidget {
  const _StepperTile({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: ExoPlayerColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ExoButton(
              icon: Icons.remove_rounded,
              semanticLabel: '$label down',
              onPressed: onMinus,
              onFocusChange: (_) {},
            ),
            SizedBox(
              width: 76,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: ExoPlayerColors.lime,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _ExoButton(
              icon: Icons.add_rounded,
              semanticLabel: '$label up',
              onPressed: onPlus,
              onFocusChange: (_) {},
            ),
          ],
        ),
      );
}
