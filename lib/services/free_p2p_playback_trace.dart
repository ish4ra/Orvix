import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'platform_profile.dart';
import 'source_provider_service.dart';
import 'telemetry_redaction.dart';

/// How a Free P2P playback attempt ended. Each value names the stage that
/// decided it, so an engine problem is never reported as a dead swarm and a
/// player problem is never blamed on the torrent.
enum FreeP2pPlaybackOutcome {
  /// Still preparing, or handed to the player with no answer yet.
  inProgress,

  /// The player reported that playback started.
  playing,

  /// The user backed out before the player opened.
  cancelled,

  /// The local torrent engine could not start or stopped answering.
  engineFailure,

  /// The engine answered, but magnet metadata did not resolve in time.
  metadataTimeout,

  /// The engine rejected the torrent (bad info hash, engine error payload,
  /// HTTP error).
  sourceError,

  /// The player reported a startup failure.
  playerFailure,

  /// The player was closed before it reported a start or a failure.
  closedBeforeStart,

  /// Failed for a reason the stages above do not explain.
  failed,
}

/// One playback attempt: which source was chosen, what the live check knew
/// about it at that moment, and the time and result of every stage from the
/// torrent engine to the player. Only categorical values, numbers, provider
/// names and hosts are kept; never a magnet, tracker, title, URL path,
/// query or credential.
class FreeP2pPlaybackAttempt {
  FreeP2pPlaybackAttempt._(
    this.id,
    this._source, {
    required this.selection,
    required this.liveCheck,
    required this.liveEvidence,
    required this.choice,
    required String? torrentLabel,
    required DateTime Function() clock,
  })  : _clock = clock,
        _torrentLabel = torrentLabel,
        _startedAt = clock();

  final int id;
  final SourceResult _source;

  /// Opaque per-report torrent name (T1, T2, …). Rows and attempts of the
  /// same torrent share it, without revealing the info hash.
  final String? _torrentLabel;

  /// How the source was chosen: oneClick, fallback, normalPlay, quickPlay,
  /// manual or other.
  final String selection;

  /// Why an automatic choice picked this source, from the live evidence the
  /// choice was based on. Null for a manual choice.
  final Map<String, Object?>? choice;

  /// Live-check state of the source when it was chosen (for example live,
  /// notChecked, checking, stalled), or directHttp.
  final String liveCheck;

  /// The probe's measured evidence for the source when it was chosen, if any.
  final Map<String, Object?>? liveEvidence;

  final DateTime Function() _clock;
  final DateTime _startedAt;
  final List<Map<String, Object?>> _stages = <Map<String, Object?>>[];
  FreeP2pPlaybackOutcome _outcome = FreeP2pPlaybackOutcome.inProgress;
  String? _outcomeDetail;
  int? _endedMs;
  DateTime? _endedAt;

  static const int maxStages = 16;
  static const int maxDetailLength = 160;

  FreeP2pPlaybackOutcome get outcome => _outcome;

  bool get isOpen => _outcome == FreeP2pPlaybackOutcome.inProgress;

  int get elapsedMs => _clock().difference(_startedAt).inMilliseconds;

  /// Time since the attempt ended, or null while it is open.
  Duration? get sinceEnd {
    final ended = _endedAt;
    return ended == null ? null : _clock().difference(ended);
  }

  List<Map<String, Object?>> get stages => List.unmodifiable(_stages);

  bool isFor(SourceResult source) =>
      identical(source, _source) ||
      (source.resource == _source.resource &&
          source.torrentFileIndex == _source.torrentFileIndex);

  /// Records one stage. [took] is the stage's own duration when it was
  /// measured; every stage also carries the time since the attempt began.
  void stage(
    String name,
    String result, {
    Duration? took,
    Map<String, Object?> detail = const <String, Object?>{},
  }) {
    if (_stages.length >= maxStages) return;
    final entry = <String, Object?>{
      'stage': name,
      'result': result,
      'atMs': elapsedMs,
      if (took != null) 'ms': took.inMilliseconds,
      for (final item in detail.entries)
        if (item.value != null) item.key: _safe(item.value),
    };
    _stages.add(entry);
    debugPrint('[orvix-p2p] ${jsonEncode({'attempt': id, ...entry})}');
  }

  /// The player reported a start after it had reported a startup failure
  /// (MPV keeps trying after its startup timeout): the attempt did play.
  void markRecovered() {
    if (_outcome != FreeP2pPlaybackOutcome.playerFailure) return;
    stage('playerStart', 'recovered');
    _outcome = FreeP2pPlaybackOutcome.playing;
    _endedMs = elapsedMs;
    _endedAt = _clock();
  }

  /// Ends the attempt. Only the first outcome counts, so a later generic
  /// error cannot overwrite the stage that actually failed.
  void finish(FreeP2pPlaybackOutcome outcome, {String? detail}) {
    if (!isOpen || outcome == FreeP2pPlaybackOutcome.inProgress) return;
    _outcome = outcome;
    _outcomeDetail = detail == null ? null : _safeText(detail);
    _endedMs = elapsedMs;
    _endedAt = _clock();
    debugPrint('[orvix-p2p] ${jsonEncode({
          'attempt': id,
          'outcome': outcome.name,
          if (_outcomeDetail != null) 'detail': _outcomeDetail,
          'totalMs': _endedMs,
        })}');
  }

  Map<String, Object?> toDiagnostics() {
    final source = _source;
    final host = source.isMagnet ? null : Uri.tryParse(source.resource)?.host;
    return <String, Object?>{
      'attempt': id,
      'sourceType': source.isMagnet ? 'torrent' : 'directHttp',
      'provider': _safeText(source.provider),
      if (_torrentLabel != null) 'torrent': _torrentLabel,
      if (host != null && host.isNotEmpty) 'host': host,
      if (source.quality != null) 'quality': source.quality,
      if (source.releaseQuality != null) 'release': source.releaseQuality,
      if (source.sizeBytes != null)
        'sizeMb': source.sizeBytes! ~/ (1024 * 1024),
      if (source.isMagnet)
        'fileRouted': source.torrentFileIndex != null ||
            (source.fileNameHint?.trim().isNotEmpty ?? false),
      // Provider figures are the provider's snapshot, never live evidence.
      if (source.seeders != null) 'providerSeeders': source.seeders,
      if (source.peers != null) 'providerPeers': source.peers,
      'selection': selection,
      if (choice != null) 'choice': choice,
      'liveCheck': liveCheck,
      if (liveEvidence != null) 'liveEvidence': liveEvidence,
      'stages': _stages,
      'outcome': _outcome.name,
      if (_outcomeDetail != null) 'detail': _outcomeDetail,
      'totalMs': _endedMs ?? elapsedMs,
    };
  }

  static Object? _safe(Object? value) =>
      value is String ? _safeText(value) : value;

  static String _safeText(String text) {
    final redacted =
        redactTelemetryText(text.replaceAll(RegExp(r'\s+'), ' ')).trim();
    return redacted.length <= maxDetailLength
        ? redacted
        : '${redacted.substring(0, maxDetailLength)}…';
  }
}

/// The last few Free P2P playback attempts on this device, kept in memory
/// only. It feeds the live-check report the user can copy from the source
/// picker; nothing is uploaded.
class FreeP2pPlaybackTrace {
  FreeP2pPlaybackTrace({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static final FreeP2pPlaybackTrace instance = FreeP2pPlaybackTrace();

  static const int maxAttempts = 5;
  static const int maxRuns = 3;
  static const int maxTorrentLabels = 64;

  final DateTime Function() _clock;
  final List<FreeP2pPlaybackAttempt> _attempts = <FreeP2pPlaybackAttempt>[];
  final List<FreeP2pAutoPlayRun> _runs = <FreeP2pAutoPlayRun>[];
  final Map<String, String> _torrentLabels = <String, String>{};
  int _nextId = 1;
  int _nextRunId = 1;
  int _nextTorrent = 1;

  static final RegExp _btih =
      RegExp(r'xt=urn:btih:([a-z0-9]+)', caseSensitive: false);

  /// Opaque label for [source]'s torrent (T1, T2, …), stable while this
  /// trace lives, so a report can show that two rows or attempts share a
  /// torrent without revealing its info hash. Null for direct HTTP.
  String? torrentLabel(SourceResult source) {
    if (!source.isMagnet) return null;
    final hash = _btih.firstMatch(source.resource)?.group(1)?.toLowerCase();
    if (hash == null || hash.isEmpty) return null;
    final known = _torrentLabels[hash];
    if (known != null) return known;
    if (_torrentLabels.length >= maxTorrentLabels) {
      _torrentLabels.remove(_torrentLabels.keys.first);
    }
    return _torrentLabels[hash] = 'T${_nextTorrent++}';
  }

  /// Newest first.
  List<FreeP2pAutoPlayRun> get runs => List.unmodifiable(_runs.reversed);

  /// Starts recording one press of Play in Free P2P mode.
  FreeP2pAutoPlayRun beginRun() {
    final run = FreeP2pAutoPlayRun._(_nextRunId++, _clock);
    _runs.add(run);
    while (_runs.length > maxRuns) {
      _runs.removeAt(0);
    }
    return run;
  }

  /// Newest first.
  List<FreeP2pPlaybackAttempt> get attempts =>
      List.unmodifiable(_attempts.reversed);

  /// Starts recording a playback attempt for [source].
  FreeP2pPlaybackAttempt begin(
    SourceResult source, {
    String selection = 'other',
    String? liveCheck,
    Map<String, Object?>? liveEvidence,
    Map<String, Object?>? choice,
  }) {
    final attempt = FreeP2pPlaybackAttempt._(
      _nextId++,
      source,
      selection: selection,
      liveCheck: liveCheck ?? (source.isMagnet ? 'notChecked' : 'directHttp'),
      liveEvidence: liveEvidence,
      choice: choice,
      torrentLabel: torrentLabel(source),
      clock: _clock,
    );
    _attempts.add(attempt);
    while (_attempts.length > maxAttempts) {
      _attempts.removeAt(0);
    }
    return attempt;
  }

  /// The newest attempt for [source] that has not ended yet.
  FreeP2pPlaybackAttempt? active(SourceResult source) {
    for (final attempt in _attempts.reversed) {
      if (attempt.isFor(source)) return attempt.isOpen ? attempt : null;
    }
    return null;
  }

  /// The newest attempt for [source], ended or not.
  FreeP2pPlaybackAttempt? latest(SourceResult source) {
    for (final attempt in _attempts.reversed) {
      if (attempt.isFor(source)) return attempt;
    }
    return null;
  }

  /// The attempt the picker or Normal Play just began for [source], or a new
  /// one when the source reached playback without that handoff (for example
  /// a pinned-release shortcut). An attempt that already recorded stages
  /// belongs to an earlier playback and is never reused.
  FreeP2pPlaybackAttempt attemptFor(SourceResult source) {
    final handedOff = active(source);
    if (handedOff != null && handedOff.stages.isEmpty) return handedOff;
    return begin(source);
  }

  void clear() {
    _attempts.clear();
    _runs.clear();
    _torrentLabels.clear();
    _nextTorrent = 1;
  }

  /// Report lines for the recent one-click runs and attempts, newest first.
  List<String> reportLines() {
    return <String>[
      if (_runs.isNotEmpty) ...[
        'one-click play (newest first):',
        for (final run in _runs.reversed) jsonEncode(run.toDiagnostics()),
      ],
      if (_attempts.isEmpty)
        'playback: no attempt yet'
      else ...[
        'playback (newest first):',
        for (final attempt in _attempts.reversed)
          jsonEncode(attempt.toDiagnostics()),
      ],
    ];
  }

  /// Standalone copyable report (device line plus recent attempts).
  String report() => <String>[
        'Orvix Free P2P playback report',
        deviceLine(),
        ...reportLines(),
      ].join('\n');

  /// Product surface only: no model, name or identifier of the device.
  static String deviceLine() {
    final surface = PlatformProfile.isAndroidTv
        ? 'androidTv'
        : Platform.isAndroid
            ? 'androidMobile'
            : Platform.operatingSystem;
    return 'device=$surface';
  }
}

/// One press of Play in Free P2P mode: the live check that chose the first
/// source, every automatic attempt and fallback, and how the run ended.
class FreeP2pAutoPlayRun {
  FreeP2pAutoPlayRun._(this.id, this._clock) : _startedAt = _clock();

  final int id;
  final DateTime Function() _clock;
  final DateTime _startedAt;
  final List<Map<String, Object?>> _steps = <Map<String, Object?>>[];
  String _result = 'inProgress';
  String? _detail;
  int? _totalMs;

  static const int maxSteps = 12;

  String get result => _result;

  int get elapsedMs => _clock().difference(_startedAt).inMilliseconds;

  List<Map<String, Object?>> get steps => List.unmodifiable(_steps);

  /// A bounded live check that ran to find candidates.
  void probeRound(
    String purpose, {
    required int classified,
    required int confirmedLive,
    required Duration took,
  }) =>
      _add(<String, Object?>{
        'step': 'liveCheck',
        'purpose': purpose,
        'classified': classified,
        'confirmedLive': confirmedLive,
        'ms': took.inMilliseconds,
      });

  /// An automatic attempt started for [attempt]'s source.
  void attemptStarted(FreeP2pPlaybackAttempt attempt, {required int number}) =>
      _add(<String, Object?>{
        'step': number == 1 ? 'firstAttempt' : 'fallbackAttempt',
        'number': number,
        'attempt': attempt.id,
      });

  /// How an automatic attempt ended, as the fallback decision saw it.
  void attemptEnded(
    FreeP2pPlaybackAttempt? attempt, {
    required int number,
    required String end,
    required Duration took,
  }) =>
      _add(<String, Object?>{
        'step': 'attemptEnded',
        'number': number,
        if (attempt != null) 'attempt': attempt.id,
        'end': end,
        'ms': took.inMilliseconds,
      });

  void _add(Map<String, Object?> step) {
    if (_steps.length >= maxSteps) return;
    final entry = <String, Object?>{...step, 'atMs': elapsedMs};
    _steps.add(entry);
    debugPrint('[orvix-p2p] ${jsonEncode({'run': id, ...entry})}');
  }

  /// Ends the run: started, stoppedByUser, noVerifiedSource, exhausted or
  /// engineFailure. Only the first result counts.
  void finish(String result, {String? detail}) {
    if (_result != 'inProgress') return;
    _result = result;
    _detail = detail;
    _totalMs = elapsedMs;
    debugPrint('[orvix-p2p] ${jsonEncode({
          'run': id,
          'result': result,
          if (detail != null) 'detail': detail,
          'totalMs': _totalMs,
        })}');
  }

  Map<String, Object?> toDiagnostics() => <String, Object?>{
        'run': id,
        'steps': _steps,
        'result': _result,
        if (_detail != null) 'detail': _detail,
        'totalMs': _totalMs ?? elapsedMs,
      };
}
