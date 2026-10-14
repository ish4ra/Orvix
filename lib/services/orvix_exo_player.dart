import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'subtitle_text_cleanup.dart';

/// Media3 playback states, as reported by the native player.
enum OrvixExoState { idle, buffering, ready, ended }

/// One audio or subtitle track of the current stream.
@immutable
class OrvixExoTrack {
  const OrvixExoTrack({
    required this.type,
    required this.group,
    required this.track,
    this.language,
    this.label,
    this.mimeType,
    this.codecs,
    this.channels,
    this.selected = false,
    this.supported = true,
    this.forced = false,
    this.isDefault = false,
    this.support,
    this.width,
    this.height,
    this.frameRate,
    this.sampleRate,
  });

  factory OrvixExoTrack.fromMap(Map<Object?, Object?> map) => OrvixExoTrack(
        type: map['type']?.toString() ?? '',
        group: (map['group'] as num?)?.toInt() ?? -1,
        track: (map['track'] as num?)?.toInt() ?? -1,
        language: _clean(map['language']),
        label: _clean(map['label']),
        mimeType: _clean(map['mimeType']),
        codecs: _clean(map['codecs']),
        channels: (map['channels'] as num?)?.toInt(),
        selected: map['selected'] == true,
        supported: map['supported'] != false,
        forced: map['forced'] == true,
        isDefault: map['isDefault'] == true,
        support: _clean(map['support']),
        width: _positiveInt(map['width']),
        height: _positiveInt(map['height']),
        frameRate: _positiveDouble(map['frameRate']),
        sampleRate: _positiveInt(map['sampleRate']),
      );

  /// 'audio' or 'text'.
  final String type;
  final int group;
  final int track;
  final String? language;
  final String? label;
  final String? mimeType;
  final String? codecs;
  final int? channels;
  final bool selected;
  final bool supported;
  final bool forced;
  final bool isDefault;

  /// Media3's verdict for this device: handled, exceedsCapabilities,
  /// unsupportedSubtype, unsupportedType or unsupportedDrm.
  final String? support;
  final int? width;
  final int? height;
  final double? frameRate;
  final int? sampleRate;

  bool get isText => type == 'text';
  bool get isAudio => type == 'audio';
  bool get isVideo => type == 'video';

  /// Media3's MIME type for subtitles it parsed while reading the file. The
  /// format the file really carries is then in [codecs].
  static const parsedCuesMime = 'application/x-media3-cues';

  /// The subtitle format as stored in the file (SRT, ASS, PGS…). Media3 1.4+
  /// parses embedded subtitles during extraction and reports them as
  /// [parsedCuesMime], with the original MIME type in [codecs].
  String? get formatMime {
    final mime = mimeType?.toLowerCase();
    if (mime == parsedCuesMime) return codecs?.toLowerCase();
    return mime;
  }

  /// ASS/SSA: drawn as plain text, without its own fonts and positions.
  bool get isAssSubtitle => formatMime == 'text/x-ssa';

  /// Subtitle formats Media3 renders as images (PGS, DVB, VobSub).
  bool get isBitmapSubtitle {
    final mime = formatMime ?? '';
    return mime.contains('pgs') ||
        mime.contains('dvbsubs') ||
        mime.contains('vobsub');
  }

  static String? _clean(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty || text == 'und' ? null : text;
  }

  static int? _positiveInt(Object? value) {
    final number = (value as num?)?.toInt();
    return number == null || number <= 0 ? null : number;
  }

  static double? _positiveDouble(Object? value) {
    final number = (value as num?)?.toDouble();
    return number == null || number <= 0 || number.isNaN ? null : number;
  }

  /// Short codec name for menus: "AC-3", "E-AC-3", "AAC", "DTS", "HEVC"…
  String? get codecName {
    final mime = formatMime ?? '';
    const names = <String, String>{
      'audio/eac3-joc': 'Dolby Atmos (E-AC-3)',
      'audio/eac3': 'E-AC-3',
      'audio/ac3': 'AC-3',
      'audio/true-hd': 'TrueHD',
      'audio/vnd.dts.hd': 'DTS-HD',
      'audio/vnd.dts': 'DTS',
      'audio/mp4a-latm': 'AAC',
      'audio/opus': 'Opus',
      'audio/vorbis': 'Vorbis',
      'audio/flac': 'FLAC',
      'audio/mpeg': 'MP3',
      'audio/raw': 'PCM',
      'video/hevc': 'HEVC',
      'video/avc': 'H.264',
      'video/av01': 'AV1',
      'video/x-vnd.on2.vp9': 'VP9',
      'video/dolby-vision': 'Dolby Vision',
      'video/mpeg2': 'MPEG-2',
      'application/x-subrip': 'SRT',
      'text/vtt': 'WebVTT',
      'text/x-ssa': 'ASS/SSA',
      'application/pgs': 'PGS',
      'application/vobsub': 'VobSub',
      'application/dvbsubs': 'DVB',
      'application/ttml+xml': 'TTML',
      'application/x-mp4-vtt': 'WebVTT',
      'application/cea-608': 'CEA-608',
      'application/cea-708': 'CEA-708',
      'text/x-unknown': 'Text',
    };
    return names[mime];
  }

  static const _languageNames = <String, String>{
    'en': 'English',
    'eng': 'English',
    'si': 'Sinhala',
    'sin': 'Sinhala',
    'ta': 'Tamil',
    'tam': 'Tamil',
    'hi': 'Hindi',
    'hin': 'Hindi',
    'es': 'Spanish',
    'spa': 'Spanish',
    'fr': 'French',
    'fre': 'French',
    'fra': 'French',
    'de': 'German',
    'ger': 'German',
    'deu': 'German',
    'it': 'Italian',
    'ita': 'Italian',
    'pt': 'Portuguese',
    'por': 'Portuguese',
    'ja': 'Japanese',
    'jpn': 'Japanese',
    'ko': 'Korean',
    'kor': 'Korean',
    'zh': 'Chinese',
    'chi': 'Chinese',
    'zho': 'Chinese',
    'ar': 'Arabic',
    'ara': 'Arabic',
    'ru': 'Russian',
    'rus': 'Russian',
  };

  String get languageName {
    final code = language?.toLowerCase().split(RegExp(r'[-_]')).first;
    if (code == null) return 'Unknown';
    return _languageNames[code] ?? code.toUpperCase();
  }

  String get displayName {
    final parts = <String>[
      languageName,
      if (label != null && label!.toLowerCase() != languageName.toLowerCase())
        label!,
      if (forced) 'Forced',
      if (isAudio && channels != null && channels! > 0)
        channels == 6
            ? '5.1'
            : channels == 8
                ? '7.1'
                : channels == 2
                    ? 'Stereo'
                    : '${channels}ch',
      if (!supported) 'Not supported on this device',
    ];
    return parts.join(' • ');
  }
}

/// An image subtitle cue (PGS/DVB/VobSub), placed by fractions of the video.
@immutable
class OrvixExoBitmapCue {
  const OrvixExoBitmapCue({
    required this.png,
    this.left,
    this.top,
    this.width,
    this.height,
  });

  final Uint8List png;
  final double? left;
  final double? top;
  final double? width;
  final double? height;
}

@immutable
class OrvixExoValue {
  const OrvixExoValue({
    this.textureId,
    this.handlesCropAndRotation = true,
    this.state = OrvixExoState.idle,
    this.playing = false,
    this.playWhenReady = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.speed = 1.0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.rotation = 0,
    this.tracks = const <OrvixExoTrack>[],
    this.cueText = const <String>[],
    this.bitmapCues = const <OrvixExoBitmapCue>[],
    this.cueEvents = 0,
    this.errorCode,
    this.errorMessage,
    this.error,
    this.cuesAtTop = false,
    this.loading = false,
    this.bytesLoaded = 0,
    this.connections = 0,
    this.httpStatus,
    this.contentType,
    this.acceptsRanges,
    this.firstByte,
    this.firstFrame,
    this.droppedFrames = 0,
    this.loadErrors = 0,
    this.videoDecoder,
    this.audioDecoder,
  });

  final int? textureId;
  final bool handlesCropAndRotation;
  final OrvixExoState state;
  final bool playing;
  final bool playWhenReady;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double speed;
  final int videoWidth;
  final int videoHeight;
  final int rotation;
  final List<OrvixExoTrack> tracks;
  final List<String> cueText;
  final List<OrvixExoBitmapCue> bitmapCues;

  /// How many non-empty subtitle cue updates Media3 delivered. Playback info
  /// uses it to tell "no track", "track selected but silent" and "rendering"
  /// apart on a real device.
  final int cueEvents;
  final String? errorCode;
  final String? errorMessage;

  /// Structured details of the last fatal Media3 error.
  final OrvixExoError? error;

  /// The current text cues are placed in the upper part of the picture.
  final bool cuesAtTop;

  // Privacy-safe startup and playback diagnostics from the native player.
  final bool loading;
  final int bytesLoaded;
  final int connections;
  final int? httpStatus;
  final String? contentType;
  final bool? acceptsRanges;

  /// Time from player creation to the first network byte / first frame.
  final Duration? firstByte;
  final Duration? firstFrame;
  final int droppedFrames;
  final int loadErrors;
  final String? videoDecoder;
  final String? audioDecoder;

  bool get hasError => errorCode != null;
  bool get hasVideoSize => videoWidth > 0 && videoHeight > 0;
  double get aspectRatio =>
      hasVideoSize ? videoWidth / videoHeight : 16 / 9;
  bool get buffering => state == OrvixExoState.buffering;

  /// Real playback has begun: the player is playing past the start.
  bool get started =>
      state == OrvixExoState.ready && (playing || position > Duration.zero);

  List<OrvixExoTrack> get audioTracks =>
      tracks.where((track) => track.isAudio).toList(growable: false);
  List<OrvixExoTrack> get textTracks =>
      tracks.where((track) => track.isText).toList(growable: false);
  List<OrvixExoTrack> get videoTracks =>
      tracks.where((track) => track.isVideo).toList(growable: false);

  OrvixExoValue copyWith({
    int? textureId,
    bool? handlesCropAndRotation,
    OrvixExoState? state,
    bool? playing,
    bool? playWhenReady,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    double? speed,
    int? videoWidth,
    int? videoHeight,
    int? rotation,
    List<OrvixExoTrack>? tracks,
    List<String>? cueText,
    List<OrvixExoBitmapCue>? bitmapCues,
    int? cueEvents,
    String? errorCode,
    String? errorMessage,
    OrvixExoError? error,
    bool clearError = false,
    bool? cuesAtTop,
    bool? loading,
    int? bytesLoaded,
    int? connections,
    int? httpStatus,
    String? contentType,
    bool? acceptsRanges,
    Duration? firstByte,
    Duration? firstFrame,
    int? droppedFrames,
    int? loadErrors,
    String? videoDecoder,
    String? audioDecoder,
  }) =>
      OrvixExoValue(
        textureId: textureId ?? this.textureId,
        handlesCropAndRotation:
            handlesCropAndRotation ?? this.handlesCropAndRotation,
        state: state ?? this.state,
        playing: playing ?? this.playing,
        playWhenReady: playWhenReady ?? this.playWhenReady,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffered: buffered ?? this.buffered,
        speed: speed ?? this.speed,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        rotation: rotation ?? this.rotation,
        tracks: tracks ?? this.tracks,
        cueText: cueText ?? this.cueText,
        bitmapCues: bitmapCues ?? this.bitmapCues,
        cueEvents: cueEvents ?? this.cueEvents,
        errorCode: clearError ? null : errorCode ?? this.errorCode,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
        error: clearError ? null : error ?? this.error,
        cuesAtTop: cuesAtTop ?? this.cuesAtTop,
        loading: loading ?? this.loading,
        bytesLoaded: bytesLoaded ?? this.bytesLoaded,
        connections: connections ?? this.connections,
        httpStatus: httpStatus ?? this.httpStatus,
        contentType: contentType ?? this.contentType,
        acceptsRanges: acceptsRanges ?? this.acceptsRanges,
        firstByte: firstByte ?? this.firstByte,
        firstFrame: firstFrame ?? this.firstFrame,
        droppedFrames: droppedFrames ?? this.droppedFrames,
        loadErrors: loadErrors ?? this.loadErrors,
        videoDecoder: videoDecoder ?? this.videoDecoder,
        audioDecoder: audioDecoder ?? this.audioDecoder,
      );
}

/// A fatal Media3 error with the details the native player could observe.
/// Contains no URL, header or token: only codes, numbers, MIME types and
/// exception class names.
@immutable
class OrvixExoError {
  const OrvixExoError({
    required this.code,
    this.codeNumber,
    this.message = '',
    this.causes = const <String>[],
    this.httpStatus,
    this.errorType,
    this.rendererMime,
    this.rendererCodecs,
    this.rendererSupport,
    this.bytesLoaded,
    this.lastHttpStatus,
    this.at,
  });

  factory OrvixExoError.fromEvent(Map<Object?, Object?> event) {
    final causes = event['causes'];
    final at = (event['atMs'] as num?)?.toInt();
    final bytes = (event['bytesLoaded'] as num?)?.toInt();
    final lastHttp = (event['lastHttpStatus'] as num?)?.toInt();
    return OrvixExoError(
      code: event['code']?.toString() ?? 'ERROR_CODE_UNSPECIFIED',
      codeNumber: (event['codeNumber'] as num?)?.toInt(),
      message: event['message']?.toString() ?? '',
      causes: causes is List
          ? causes.map((c) => c.toString()).toList(growable: false)
          : (event['cause']?.toString() ?? '')
              .split('>')
              .map((c) => c.trim())
              .where((c) => c.isNotEmpty)
              .toList(growable: false),
      httpStatus: (event['httpStatus'] as num?)?.toInt(),
      errorType: event['errorType']?.toString(),
      rendererMime: event['rendererMime']?.toString(),
      rendererCodecs: event['rendererCodecs']?.toString(),
      rendererSupport: event['rendererSupport']?.toString(),
      bytesLoaded: bytes,
      lastHttpStatus: lastHttp == null || lastHttp < 0 ? null : lastHttp,
      at: at == null ? null : Duration(milliseconds: at),
    );
  }

  final String code;
  final int? codeNumber;
  final String message;
  final List<String> causes;
  final int? httpStatus;

  /// source, renderer, unexpected or remote.
  final String? errorType;
  final String? rendererMime;
  final String? rendererCodecs;
  final String? rendererSupport;
  final int? bytesLoaded;
  final int? lastHttpStatus;
  final Duration? at;
}

/// Transport to the native player. Production uses the "orvix/exo_player"
/// method channel; tests install a fake.
abstract class OrvixExoBackend {
  /// Creates a native player and returns its id, texture id and whether the
  /// texture already applies rotation.
  Future<({int id, int textureId, bool handlesCropAndRotation})> create(
    Map<String, Object?> arguments,
  );

  Future<void> command(int id, String method, [Map<String, Object?>? args]);

  /// Native events for player [id].
  void listen(int id, void Function(Map<Object?, Object?> event) onEvent);
  void unlisten(int id);
}

class MethodChannelOrvixExoBackend implements OrvixExoBackend {
  MethodChannelOrvixExoBackend() {
    _channel.setMethodCallHandler(_handle);
  }

  static const _channel = MethodChannel('orvix/exo_player');
  final _listeners = <int, void Function(Map<Object?, Object?>)>{};

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'event') return;
    final event = call.arguments;
    if (event is! Map) return;
    final id = (event['id'] as num?)?.toInt();
    if (id == null) return;
    _listeners[id]?.call(event);
  }

  @override
  Future<({int id, int textureId, bool handlesCropAndRotation})> create(
    Map<String, Object?> arguments,
  ) async {
    final result =
        await _channel.invokeMapMethod<String, Object?>('create', arguments);
    return (
      id: (result?['id'] as num).toInt(),
      textureId: (result?['textureId'] as num).toInt(),
      handlesCropAndRotation: result?['handlesCropAndRotation'] != false,
    );
  }

  @override
  Future<void> command(
    int id,
    String method, [
    Map<String, Object?>? args,
  ]) =>
      _channel.invokeMethod<void>(method, <String, Object?>{
        'id': id,
        ...?args,
      });

  @override
  void listen(int id, void Function(Map<Object?, Object?> event) onEvent) {
    _listeners[id] = onEvent;
  }

  @override
  void unlisten(int id) => _listeners.remove(id);
}

/// One native ExoPlayer instance.
class OrvixExoController extends ValueNotifier<OrvixExoValue> {
  OrvixExoController({
    required this.url,
    this.headers = const <String, String>{},
    this.patientStartup = false,
    this.preferredTextLanguage,
    this.preferredAudioLanguage,
    this.textDisabled = false,
    this.startPosition = Duration.zero,
    OrvixExoBackend? backend,
  })  : _backend = backend ?? defaultBackend,
        super(const OrvixExoValue());

  static OrvixExoBackend? _defaultBackend;

  /// The shared method-channel backend. Tests replace it.
  static OrvixExoBackend get defaultBackend =>
      _defaultBackend ??= MethodChannelOrvixExoBackend();
  @visibleForTesting
  static set defaultBackend(OrvixExoBackend backend) =>
      _defaultBackend = backend;

  final String url;
  final Map<String, String> headers;
  final bool patientStartup;
  final String? preferredTextLanguage;
  final String? preferredAudioLanguage;

  /// Start with embedded subtitles off (the user turned them off before).
  final bool textDisabled;
  final Duration startPosition;
  final OrvixExoBackend _backend;

  int? _id;
  bool _disposed = false;
  Duration _subtitleOffset = Duration.zero;

  Duration get subtitleOffset => _subtitleOffset;
  bool get isCreated => _id != null;

  Future<void> open() async {
    final created = await _backend.create(<String, Object?>{
      'url': url,
      'headers': headers,
      'patientStartup': patientStartup,
      'preferredTextLanguage': preferredTextLanguage,
      'preferredAudioLanguage': preferredAudioLanguage,
      'textDisabled': textDisabled,
      'startMs': startPosition.inMilliseconds,
    });
    if (_disposed) {
      await _backend.command(created.id, 'dispose');
      return;
    }
    _id = created.id;
    _backend.listen(created.id, _onEvent);
    value = value.copyWith(
      textureId: created.textureId,
      handlesCropAndRotation: created.handlesCropAndRotation,
      state: OrvixExoState.buffering,
      playWhenReady: true,
    );
    if (_subtitleOffset != Duration.zero) {
      await setSubtitleOffset(_subtitleOffset);
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    switch (event['event']) {
      case 'state':
        final stateIndex = (event['state'] as num?)?.toInt() ?? 1;
        final duration = (event['durationMs'] as num?)?.toInt() ?? -1;
        value = value.copyWith(
          state: switch (stateIndex) {
            2 => OrvixExoState.buffering,
            3 => OrvixExoState.ready,
            4 => OrvixExoState.ended,
            _ => OrvixExoState.idle,
          },
          playing: event['playing'] == true,
          playWhenReady: event['playWhenReady'] == true,
          position: Duration(
            milliseconds: (event['positionMs'] as num?)?.toInt() ?? 0,
          ),
          duration: duration > 0 ? Duration(milliseconds: duration) : null,
          buffered: Duration(
            milliseconds: (event['bufferedMs'] as num?)?.toInt() ?? 0,
          ),
          speed: (event['speed'] as num?)?.toDouble(),
          loading: event['loading'] == true,
          bytesLoaded: (event['bytesLoaded'] as num?)?.toInt(),
          connections: (event['connections'] as num?)?.toInt(),
          httpStatus: _positive(event['httpStatus']),
          contentType: event['contentType']?.toString(),
          acceptsRanges: event['acceptsRanges'] as bool?,
          firstByte: _millis(event['firstByteMs']),
          firstFrame: _millis(event['firstFrameMs']),
          droppedFrames: (event['droppedFrames'] as num?)?.toInt(),
          loadErrors: (event['loadErrors'] as num?)?.toInt(),
        );
      case 'video':
        value = value.copyWith(
          videoWidth: (event['width'] as num?)?.toInt(),
          videoHeight: (event['height'] as num?)?.toInt(),
          rotation: (event['rotation'] as num?)?.toInt(),
        );
      case 'tracks':
        final raw = event['tracks'];
        value = value.copyWith(
          tracks: raw is List
              ? raw
                  .whereType<Map<Object?, Object?>>()
                  .map(OrvixExoTrack.fromMap)
                  .toList(growable: false)
              : const <OrvixExoTrack>[],
        );
      case 'cues':
        final text = event['text'];
        final bitmaps = event['bitmaps'];
        value = value.copyWith(
          cueText: text is List
              ? [
                  for (final line in text)
                    if (SubtitleTextCleanup.clean(line.toString())
                        case final clean when clean.isNotEmpty)
                      clean,
                ]
              : const <String>[],
          cueEvents: value.cueEvents + (text is List && text.isNotEmpty ||
                  bitmaps is List && bitmaps.isNotEmpty
              ? 1
              : 0),
          bitmapCues: bitmaps is List
              ? [
                  for (final raw in bitmaps.whereType<Map<Object?, Object?>>())
                    if (raw['png'] is Uint8List)
                      OrvixExoBitmapCue(
                        png: raw['png']! as Uint8List,
                        left: (raw['left'] as num?)?.toDouble(),
                        top: (raw['top'] as num?)?.toDouble(),
                        width: (raw['width'] as num?)?.toDouble(),
                        height: (raw['height'] as num?)?.toDouble(),
                      ),
                ]
              : const <OrvixExoBitmapCue>[],
          cuesAtTop: event['top'] == true,
        );
      case 'diag':
        final kind = event['kind']?.toString();
        if (kind == 'videoDecoder') {
          value = value.copyWith(videoDecoder: event['name']?.toString());
        } else if (kind == 'audioDecoder') {
          value = value.copyWith(audioDecoder: event['name']?.toString());
        } else if (kind == 'firstFrame') {
          value = value.copyWith(firstFrame: _millis(event['atMs']));
        }
        onDiagnostic?.call(event);
      case 'error':
        value = value.copyWith(
          error: OrvixExoError.fromEvent(event),
          errorCode: event['code']?.toString() ?? 'ERROR_CODE_UNSPECIFIED',
          errorMessage: <String>[
            event['message']?.toString() ?? '',
            event['cause']?.toString() ?? '',
          ].where((part) => part.trim().isNotEmpty).join(' — '),
        );
    }
  }

  static int? _positive(Object? raw) {
    final value = (raw as num?)?.toInt();
    return value == null || value <= 0 ? null : value;
  }

  static Duration? _millis(Object? raw) {
    final value = (raw as num?)?.toInt();
    return value == null || value < 0 ? null : Duration(milliseconds: value);
  }

  /// Native diagnostic milestones (decoder, formats, load errors, surface).
  void Function(Map<Object?, Object?> event)? onDiagnostic;

  Future<void> _command(String method, [Map<String, Object?>? args]) async {
    final id = _id;
    if (id == null || _disposed) return;
    try {
      await _backend.command(id, method, args);
    } on PlatformException catch (error) {
      debugPrint('[orvix-exo] $method failed: ${error.code}');
    } on MissingPluginException {
      debugPrint('[orvix-exo] $method unavailable');
    }
  }

  Future<void> play() async {
    if (_disposed) return;
    value = value.copyWith(playWhenReady: true);
    await _command('play');
  }

  Future<void> pause() async {
    if (_disposed) return;
    value = value.copyWith(playWhenReady: false, playing: false);
    await _command('pause');
  }

  Future<void> seekTo(Duration position) async {
    if (_disposed) return;
    final target = position < Duration.zero ? Duration.zero : position;
    value = value.copyWith(position: target);
    await _command('seekTo', <String, Object?>{
      'positionMs': target.inMilliseconds,
    });
  }

  Future<void> setSpeed(double speed) async {
    if (_disposed) return;
    value = value.copyWith(speed: speed);
    await _command('setSpeed', <String, Object?>{'speed': speed});
  }

  /// Selects an audio track, or returns to the automatic choice when
  /// [track] is null.
  Future<void> selectAudioTrack(OrvixExoTrack? track) => _command(
        'selectTrack',
        <String, Object?>{
          'type': 'audio',
          'group': track?.group ?? -1,
          'track': track?.track ?? -1,
        },
      );

  /// Selects an embedded subtitle track, or turns embedded subtitles off
  /// when [track] is null.
  Future<void> selectTextTrack(OrvixExoTrack? track) async {
    if (_disposed) return;
    if (track == null) {
      value = value.copyWith(
        cueText: const <String>[],
        bitmapCues: const <OrvixExoBitmapCue>[],
      );
    }
    await _command('selectTrack', <String, Object?>{
      'type': 'text',
      'group': track?.group ?? -1,
      'track': track?.track ?? -1,
    });
  }

  /// Positive values show subtitles later, negative values earlier.
  Future<void> setSubtitleOffset(Duration offset) async {
    _subtitleOffset = offset;
    await _command('setSubtitleOffset', <String, Object?>{
      'offsetMs': offset.inMilliseconds,
    });
  }

  /// Releases the native player and waits until it is gone, so another
  /// player engine never starts while this one still holds the decoder.
  Future<void> close() async {
    if (_disposed) return;
    final id = _id;
    _id = null;
    if (id != null) {
      _backend.unlisten(id);
      try {
        await _backend.command(id, 'dispose');
      } catch (_) {}
    }
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _id;
    _id = null;
    if (id != null) {
      _backend.unlisten(id);
      unawaited(
        _backend.command(id, 'dispose').catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  bool get isDisposed => _disposed;
}
