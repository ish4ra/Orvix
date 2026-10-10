import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  bool get isText => type == 'text';
  bool get isAudio => type == 'audio';

  /// Subtitle formats Media3 renders as images (PGS, DVB, VobSub).
  bool get isBitmapSubtitle {
    final mime = mimeType?.toLowerCase() ?? '';
    return mime.contains('pgs') ||
        mime.contains('dvbsubs') ||
        mime.contains('vobsub');
  }

  static String? _clean(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty || text == 'und' ? null : text;
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
      if (!supported) 'Unsupported',
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
    this.errorCode,
    this.errorMessage,
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
  final String? errorCode;
  final String? errorMessage;

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
    String? errorCode,
    String? errorMessage,
    bool clearError = false,
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
        errorCode: clearError ? null : errorCode ?? this.errorCode,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );
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
              ? text.map((line) => line.toString()).toList(growable: false)
              : const <String>[],
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
        );
      case 'error':
        value = value.copyWith(
          errorCode: event['code']?.toString() ?? 'ERROR_CODE_UNSPECIFIED',
          errorMessage: <String>[
            event['message']?.toString() ?? '',
            event['cause']?.toString() ?? '',
          ].where((part) => part.trim().isNotEmpty).join(' — '),
        );
    }
  }

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

  Future<void> selectAudioTrack(OrvixExoTrack track) => _command(
        'selectTrack',
        <String, Object?>{
          'type': 'audio',
          'group': track.group,
          'track': track.track,
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
