import 'package:flutter/foundation.dart';

import 'orvix_exo_player.dart';
import 'telemetry_redaction.dart';

/// What part of the playback chain an ExoPlayer failure belongs to.
enum ExoErrorCategory {
  /// No connection, a timeout or a dropped connection.
  network,

  /// The server answered, but not with the media (HTTP 4xx/5xx, missing
  /// file, expired link).
  source,

  /// The bytes arrived but are not a container Media3 can read.
  format,

  /// The video (or audio) codec cannot be decoded on this device.
  decoder,

  /// The device's audio output could not be opened or written.
  audio,

  /// Protected content.
  drm,

  /// The player was used after it closed, or another internal state error.
  lifecycle,
  unknown,
}

/// A classified ExoPlayer failure, with wording for people and the codes
/// for the diagnostics report.
@immutable
class ExoErrorDiagnosis {
  const ExoErrorDiagnosis({
    required this.category,
    required this.title,
    required this.message,
    required this.suggestMpv,
    required this.transientOnLocalP2p,
  });

  final ExoErrorCategory category;
  final String title;
  final String message;

  /// MPV decodes in software and reads more containers; it is worth trying
  /// for format and decoder failures.
  final bool suggestMpv;

  /// A slow or still-connecting local torrent can cause this error.
  final bool transientOnLocalP2p;
}

class ExoErrorClassifier {
  ExoErrorClassifier._();

  static ExoErrorDiagnosis classify(OrvixExoError error) {
    final code = error.code.toUpperCase();
    final causes = error.causes.map((c) => c.toLowerCase()).toList();
    bool caused(String name) => causes.any((c) => c.contains(name));
    final status = error.httpStatus;

    if (code.startsWith('ERROR_CODE_DRM')) {
      return const ExoErrorDiagnosis(
        category: ExoErrorCategory.drm,
        title: 'Protected video',
        message: 'This video is copy-protected and cannot be played here.',
        suggestMpv: false,
        transientOnLocalP2p: false,
      );
    }
    if (code.startsWith('ERROR_CODE_AUDIO_TRACK')) {
      return const ExoErrorDiagnosis(
        category: ExoErrorCategory.audio,
        title: 'Audio output failed',
        message: 'The device could not open its audio output for this '
            'stream. Choose another audio track or play with MPV.',
        suggestMpv: true,
        transientOnLocalP2p: false,
      );
    }
    if (code.startsWith('ERROR_CODE_DECOD') ||
        code == 'ERROR_CODE_DECODER_INIT_FAILED' ||
        code == 'ERROR_CODE_DECODER_QUERY_FAILED' ||
        code.startsWith('ERROR_CODE_VIDEO_FRAME_PROCESS')) {
      final audio = (error.rendererMime ?? '').startsWith('audio/');
      return ExoErrorDiagnosis(
        category: ExoErrorCategory.decoder,
        title: audio ? 'Audio format not supported' : 'Video format not supported',
        message: audio
            ? 'This device has no decoder for this audio format'
                '${_codec(error)}. MPV can usually play it.'
            : 'This device cannot decode this video'
                '${_codec(error)}. MPV decodes it in software and can '
                'usually play it.',
        suggestMpv: true,
        transientOnLocalP2p: false,
      );
    }
    if (code.startsWith('ERROR_CODE_PARSING')) {
      return const ExoErrorDiagnosis(
        category: ExoErrorCategory.format,
        title: 'File format not supported',
        message: 'ExoPlayer cannot read this file format. MPV reads more '
            'formats and can usually play it.',
        suggestMpv: true,
        transientOnLocalP2p: false,
      );
    }
    if (code == 'ERROR_CODE_IO_BAD_HTTP_STATUS' ||
        code == 'ERROR_CODE_IO_FILE_NOT_FOUND' ||
        code == 'ERROR_CODE_IO_NO_PERMISSION' ||
        code == 'ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE' ||
        code == 'ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE' ||
        code == 'ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED') {
      final message = switch (status) {
        401 || 403 => 'The server refused this link (HTTP $status). It may '
            'have expired; open the source again to get a fresh link.',
        404 || 410 => 'The server no longer has this file (HTTP $status). '
            'Choose another source.',
        416 => 'The server could not send the requested part of the file '
            '(HTTP 416).',
        int s when s >= 500 => 'The server had a problem (HTTP $s). Try '
            'again in a moment or choose another source.',
        _ => 'The server did not send the video. Choose another source.',
      };
      return ExoErrorDiagnosis(
        category: ExoErrorCategory.source,
        title: 'Source unavailable',
        message: message,
        suggestMpv: false,
        transientOnLocalP2p: status != null && status >= 500,
      );
    }
    if (code.startsWith('ERROR_CODE_IO') ||
        code == 'ERROR_CODE_TIMEOUT' ||
        caused('sockettimeout') ||
        caused('unknownhost') ||
        caused('connectexception')) {
      return const ExoErrorDiagnosis(
        category: ExoErrorCategory.network,
        title: 'Connection problem',
        message: 'The video stopped arriving. Check the connection and try '
            'again, or choose another source.',
        suggestMpv: false,
        transientOnLocalP2p: true,
      );
    }
    if (code == 'ERROR_CODE_FAILED_RUNTIME_CHECK' ||
        code == 'ERROR_CODE_INVALID_STATE' ||
        caused('illegalstateexception')) {
      return const ExoErrorDiagnosis(
        category: ExoErrorCategory.lifecycle,
        title: 'Player stopped unexpectedly',
        message: 'The player stopped unexpectedly. Open the video again.',
        suggestMpv: true,
        transientOnLocalP2p: false,
      );
    }
    return const ExoErrorDiagnosis(
      category: ExoErrorCategory.unknown,
      title: 'Could not play this stream',
      message: 'ExoPlayer could not play this stream. You can try MPV or '
          'another source.',
      suggestMpv: true,
      transientOnLocalP2p: true,
    );
  }

  static String _codec(OrvixExoError error) {
    final mime = error.rendererMime;
    if (mime == null || mime.isEmpty) return '';
    final name = OrvixExoTrack(type: '', group: 0, track: 0, mimeType: mime)
            .codecName ??
        mime;
    final codecs = error.rendererCodecs;
    return codecs == null || codecs.isEmpty ? ' ($name)' : ' ($name, $codecs)';
  }
}

/// Where a stream is on its way to the first frame.
enum ExoStartupStage {
  /// The native player is being created.
  opening,

  /// Waiting for the server (or local torrent engine) to send data.
  connecting,

  /// Data is arriving; Media3 is reading the container and buffering.
  receiving,

  /// A decoder is ready; waiting for the first frame.
  decoding,

  /// Video is playing.
  playing,
}

extension ExoStartupStageOf on OrvixExoValue {
  ExoStartupStage get startupStage {
    if (textureId == null) return ExoStartupStage.opening;
    if (started) return ExoStartupStage.playing;
    if (videoDecoder != null || firstFrame != null) {
      return ExoStartupStage.decoding;
    }
    if (bytesLoaded > 0) return ExoStartupStage.receiving;
    return ExoStartupStage.connecting;
  }
}

/// How the stream reaches the player, without revealing the URL.
String exoMediaKind(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'unknown';
  final local = uri.host == '127.0.0.1' || uri.host == 'localhost';
  final path = uri.path.toLowerCase();
  final ext = RegExp(r'\.([a-z0-9]{2,5})$').firstMatch(path)?.group(1);
  final container = switch (ext) {
    'm3u8' => 'HLS',
    'mpd' => 'DASH',
    'mkv' || 'webm' => 'Matroska',
    'mp4' || 'm4v' || 'mov' => 'MP4',
    'ts' || 'm2ts' => 'MPEG-TS',
    'avi' => 'AVI',
    null => 'unknown container',
    _ => ext.toUpperCase(),
  };
  if (uri.scheme == 'file' || uri.scheme == 'content') {
    return 'local file, $container';
  }
  if (local && uri.port == 11470) return 'Free P2P (local torrent engine)';
  if (local && uri.pathSegments.firstOrNull == 'media') {
    return 'cloud/debrid via local bridge, $container';
  }
  if (local) return 'local stream, $container';
  return '${uri.scheme.toUpperCase()} stream, $container';
}

/// Privacy-safe record of one ExoPlayer session: what Media3 did and when,
/// so a real device can tell a slow torrent from a decoder failure. Kept in
/// memory only; the user copies it from the player's Playback info panel.
class ExoDiagnosticsLog {
  ExoDiagnosticsLog({
    required this.platform,
    required this.mediaKind,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start());

  final String platform;
  final String mediaKind;
  final Stopwatch _clock;
  final List<String> _lines = <String>[];
  static const int maxLines = 120;

  List<String> get lines => List.unmodifiable(_lines);

  void add(String kind, [Map<Object?, Object?> detail = const {}]) {
    final safe = <String>[
      for (final entry in detail.entries)
        if (entry.key != 'id' && entry.key != 'event' && entry.key != 'kind')
          '${entry.key}=${_safe(entry.value)}',
    ];
    final at = (_clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    final line = '+${at}s $kind${safe.isEmpty ? '' : ' ${safe.join(' ')}'}';
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeAt(0);
    debugPrint('[orvix-exo] $line');
  }

  static String _safe(Object? value) {
    if (value == null) return '-';
    if (value is List) return value.map(_safe).join('>');
    final text = redactTelemetryText(value.toString());
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  /// A copyable report: platform, engine, media kind, the current player
  /// state and the event timeline. Never URLs, hashes or credentials.
  String report(OrvixExoValue value, {String? classified}) {
    final video = value.videoTracks.where((t) => t.selected).firstOrNull;
    final audio = value.audioTracks.where((t) => t.selected).firstOrNull;
    final buffer = StringBuffer()
      ..writeln('Orvix ExoPlayer report')
      ..writeln('platform: $platform')
      ..writeln('engine: ExoPlayer (Media3)')
      ..writeln('media: $mediaKind')
      ..writeln('stage: ${value.startupStage.name}')
      ..writeln('state: ${value.state.name} playing=${value.playing} '
          'loading=${value.loading}')
      ..writeln('network: bytes=${value.bytesLoaded} '
          'connections=${value.connections} '
          'http=${value.httpStatus ?? '-'} '
          'type=${_safe(value.contentType)} '
          'ranges=${value.acceptsRanges ?? '-'} '
          'firstByteMs=${value.firstByte?.inMilliseconds ?? '-'} '
          'loadErrors=${value.loadErrors}')
      ..writeln('video: ${value.videoWidth}x${value.videoHeight} '
          'codec=${_safe(video?.mimeType)} ${_safe(video?.codecs)} '
          'support=${_safe(video?.support)} '
          'decoder=${_safe(value.videoDecoder)} '
          'firstFrameMs=${value.firstFrame?.inMilliseconds ?? '-'} '
          'dropped=${value.droppedFrames}')
      ..writeln('audio: codec=${_safe(audio?.mimeType)} '
          'channels=${audio?.channels ?? '-'} '
          'support=${_safe(audio?.support)} '
          'decoder=${_safe(value.audioDecoder)}')
      ..writeln('tracks: video=${value.videoTracks.length} '
          'audio=${value.audioTracks.length} '
          'text=${value.textTracks.length}')
      ..writeln('subtitles: ${exoSubtitleTrackSummary(value)} '
          'cueEvents=${value.cueEvents}');
    final error = value.error;
    if (error != null) {
      buffer.writeln('error: ${error.code} (${error.codeNumber ?? '-'}) '
          'type=${_safe(error.errorType)} http=${error.httpStatus ?? '-'} '
          'causes=${_safe(error.causes)} '
          'renderer=${_safe(error.rendererMime)} ${_safe(error.rendererCodecs)} '
          'support=${_safe(error.rendererSupport)}');
    }
    if (classified != null) buffer.writeln('classified: $classified');
    buffer.writeln('timeline:');
    for (final line in _lines) {
      buffer.writeln('  $line');
    }
    return buffer.toString();
  }
}


/// Every subtitle track in the stream with its real format and whether the
/// device can show it, e.g. "2: English SRT ✓ selected, Italian PGS (image)".
/// Language and format only: nothing identifying the stream.
String exoSubtitleTrackSummary(OrvixExoValue value) {
  final tracks = value.textTracks;
  if (tracks.isEmpty) return 'None in this video';
  final parts = [
    for (final track in tracks)
      [
        track.languageName,
        track.codecName ?? track.formatMime ?? 'unknown format',
        if (track.isBitmapSubtitle) '(image)',
        if (!track.supported) '(not supported: ${track.support ?? '-'})',
        if (track.selected) '✓ selected',
      ].join(' '),
  ];
  return '${tracks.length}: ${parts.join(', ')}';
}

/// Whether Media3 delivered cues for the selected embedded track.
String exoSubtitleCueSummary(OrvixExoValue value, OrvixExoTrack selected) {
  if (value.cueEvents > 0) {
    return '${value.cueEvents} received'
        '${selected.isBitmapSubtitle ? ' (image subtitles)' : ''}';
  }
  return 'None received yet. Lines appear when the film reaches dialogue.';
}
