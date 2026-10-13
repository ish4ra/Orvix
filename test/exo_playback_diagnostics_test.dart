import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/exo_playback_diagnostics.dart';
import 'package:orvix/services/exo_player_preferences_service.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';
import 'package:orvix/widgets/exo_subtitle_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ExoPlayer diagnostics, error classification, picture geometry and the
// saved subtitle style. No native player involved.

OrvixExoError _error(
  String code, {
  int? http,
  List<String> causes = const [],
  String? mime,
  String? codecs,
}) =>
    OrvixExoError(
      code: code,
      httpStatus: http,
      causes: causes,
      rendererMime: mime,
      rendererCodecs: codecs,
    );

void main() {
  group('error classification', () {
    ExoErrorDiagnosis classify(OrvixExoError error) =>
        ExoErrorClassifier.classify(error);

    test('decoder failures name the codec and suggest MPV', () {
      final video = classify(_error(
        'ERROR_CODE_DECODER_INIT_FAILED',
        mime: 'video/avc',
        codecs: 'avc1.6E0028', // H.264 High 10 (common in anime)
      ));
      expect(video.category, ExoErrorCategory.decoder);
      expect(video.title, 'Video format not supported');
      expect(video.message, contains('H.264, avc1.6E0028'));
      expect(video.suggestMpv, isTrue);
      expect(video.transientOnLocalP2p, isFalse);

      final audio = classify(_error(
        'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED',
        mime: 'audio/true-hd',
      ));
      expect(audio.title, 'Audio format not supported');
      expect(audio.message, contains('TrueHD'));
    });

    test('unreadable containers are format errors', () {
      for (final code in [
        'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED',
        'ERROR_CODE_PARSING_CONTAINER_MALFORMED',
        'ERROR_CODE_PARSING_MANIFEST_MALFORMED',
      ]) {
        final result = classify(_error(code));
        expect(result.category, ExoErrorCategory.format, reason: code);
        expect(result.suggestMpv, isTrue);
      }
    });

    test('HTTP failures are source problems with a status-specific message',
        () {
      expect(
        classify(_error('ERROR_CODE_IO_BAD_HTTP_STATUS', http: 403)).message,
        contains('expired'),
      );
      expect(
        classify(_error('ERROR_CODE_IO_BAD_HTTP_STATUS', http: 404)).message,
        contains('no longer has this file'),
      );
      final server = classify(_error('ERROR_CODE_IO_BAD_HTTP_STATUS', http: 503));
      expect(server.category, ExoErrorCategory.source);
      expect(server.transientOnLocalP2p, isTrue);
      expect(classify(_error('ERROR_CODE_IO_FILE_NOT_FOUND')).category,
          ExoErrorCategory.source);
      expect(
        classify(_error('ERROR_CODE_IO_BAD_HTTP_STATUS', http: 403)).suggestMpv,
        isFalse,
        reason: 'MPV would get the same refusal',
      );
    });

    test('network trouble is transient on a local torrent', () {
      for (final code in [
        'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT',
        'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        'ERROR_CODE_IO_UNSPECIFIED',
        'ERROR_CODE_TIMEOUT',
      ]) {
        final result = classify(_error(code));
        expect(result.category, ExoErrorCategory.network, reason: code);
        expect(result.transientOnLocalP2p, isTrue, reason: code);
      }
      expect(
        classify(_error('ERROR_CODE_UNSPECIFIED',
                causes: ['HttpDataSourceException', 'SocketTimeoutException']))
            .category,
        ExoErrorCategory.network,
      );
    });

    test('audio output, DRM and lifecycle failures are told apart', () {
      expect(classify(_error('ERROR_CODE_AUDIO_TRACK_INIT_FAILED')).category,
          ExoErrorCategory.audio);
      expect(classify(_error('ERROR_CODE_DRM_UNSPECIFIED')).category,
          ExoErrorCategory.drm);
      expect(classify(_error('ERROR_CODE_FAILED_RUNTIME_CHECK')).category,
          ExoErrorCategory.lifecycle);
      expect(classify(_error('ERROR_CODE_REMOTE_ERROR')).category,
          ExoErrorCategory.unknown);
    });

    test('messages are plain language, not Media3 jargon', () {
      for (final code in [
        'ERROR_CODE_DECODER_INIT_FAILED',
        'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED',
        'ERROR_CODE_IO_BAD_HTTP_STATUS',
        'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT',
        'ERROR_CODE_UNSPECIFIED',
      ]) {
        final result = classify(_error(code));
        expect(result.message, isNot(contains('ERROR_CODE')));
        expect(result.message, isNot(contains('Exception')));
      }
    });

    test('native error events are parsed without inventing data', () {
      final error = OrvixExoError.fromEvent({
        'code': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
        'codeNumber': 2004,
        'causes': ['InvalidResponseCodeException'],
        'httpStatus': 404,
        'errorType': 'source',
        'lastHttpStatus': -1,
        'bytesLoaded': 0,
        'atMs': 1500,
      });
      expect(error.codeNumber, 2004);
      expect(error.httpStatus, 404);
      expect(error.causes, ['InvalidResponseCodeException']);
      expect(error.lastHttpStatus, isNull);
      expect(error.at, const Duration(milliseconds: 1500));

      final legacy = OrvixExoError.fromEvent({
        'code': 'ERROR_CODE_IO_UNSPECIFIED',
        'cause': 'HttpDataSourceException > SocketTimeoutException',
      });
      expect(legacy.causes,
          ['HttpDataSourceException', 'SocketTimeoutException']);
    });
  });

  group('startup stage', () {
    test('follows bytes, decoder and first frame', () {
      const opening = OrvixExoValue();
      expect(opening.startupStage, ExoStartupStage.opening);
      const connecting =
          OrvixExoValue(textureId: 1, state: OrvixExoState.buffering);
      expect(connecting.startupStage, ExoStartupStage.connecting);
      expect(connecting.copyWith(bytesLoaded: 10).startupStage,
          ExoStartupStage.receiving);
      expect(
        connecting
            .copyWith(bytesLoaded: 10, videoDecoder: 'c2.android.hevc.decoder')
            .startupStage,
        ExoStartupStage.decoding,
      );
      expect(
        connecting
            .copyWith(
              state: OrvixExoState.ready,
              playing: true,
              bytesLoaded: 10,
            )
            .startupStage,
        ExoStartupStage.playing,
      );
    });
  });

  group('media kind (no URL in diagnostics)', () {
    test('describes the transport and container only', () {
      expect(
        exoMediaKind('http://127.0.0.1:11470/${'a' * 40}/0'),
        'Free P2P (local torrent engine)',
      );
      expect(
        exoMediaKind('http://127.0.0.1:40213/media/s1/Movie.2024.mkv'),
        'cloud/debrid via local bridge, Matroska',
      );
      expect(exoMediaKind('https://cdn.example.com/x/master.m3u8?sig=1'),
          'HTTPS stream, HLS');
      expect(exoMediaKind('https://dl.example.com/d/ABC/file.mp4'),
          'HTTPS stream, MP4');
      expect(exoMediaKind('https://dl.example.com/d/ABC'),
          'HTTPS stream, unknown container');
      for (final url in [
        'https://dl.example.com/d/ABC/file.mp4?token=secret',
        'http://127.0.0.1:11470/${'b' * 40}/2',
      ]) {
        final kind = exoMediaKind(url);
        expect(kind, isNot(contains('example.com')));
        expect(kind, isNot(contains('secret')));
        expect(kind, isNot(contains('b' * 40)));
      }
    });

    test('the log redacts URLs, tokens and info hashes', () {
      final log = ExoDiagnosticsLog(
        platform: 'Android TV',
        mediaKind: 'Free P2P (local torrent engine)',
      );
      log.add('loadError', {
        'error': 'Failed for https://real-debrid.example/d/AbC123456789/x.mkv'
            '?token=abc',
        'hash': 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
        'magnet': 'magnet:?xt=urn:btih:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
      });
      final report = log.report(const OrvixExoValue());
      expect(report, contains('platform: Android TV'));
      expect(report, isNot(contains('AbC123456789')));
      expect(report, isNot(contains('token=abc')));
      expect(report, isNot(contains('a1b2c3d4e5f6a1b2c3d4')));
    });

    test('the log keeps a bounded number of lines', () {
      final log = ExoDiagnosticsLog(platform: 'p', mediaKind: 'm');
      for (var i = 0; i < 500; i++) {
        log.add('state', {'i': i});
      }
      expect(log.lines, hasLength(ExoDiagnosticsLog.maxLines));
      expect(log.lines.last, contains('i=499'));
    });
  });

  group('picture geometry (Fit / Fill / Zoom)', () {
    const screen = Size(1920, 1080);

    test('Fit keeps the whole picture and its shape', () {
      final cinema = exoVideoRect(screen, 2.39, ExoAspectMode.fit);
      expect(cinema.width, 1920);
      expect(cinema.height, closeTo(1920 / 2.39, .5));
      expect(cinema.top, greaterThan(0), reason: 'letterbox, no stretch');

      final tv43 = exoVideoRect(screen, 4 / 3, ExoAspectMode.fit);
      expect(tv43.height, 1080);
      expect(tv43.width, closeTo(1440, .5));
      expect(tv43.left, closeTo(240, .5), reason: 'pillarbox');

      final exact = exoVideoRect(screen, 16 / 9, ExoAspectMode.fit);
      expect(exact, const Rect.fromLTWH(0, 0, 1920, 1080),
          reason: 'no double black bars for a matching picture');
    });

    test('Fill covers the screen by cropping, keeping the shape', () {
      final cinema = exoVideoRect(screen, 2.39, ExoAspectMode.fill);
      expect(cinema.height, 1080);
      expect(cinema.width / cinema.height, closeTo(2.39, .001));
      expect(cinema.left, lessThan(0));

      final tv43 = exoVideoRect(screen, 4 / 3, ExoAspectMode.fill);
      expect(tv43.width, 1920);
      expect(tv43.width / tv43.height, closeTo(4 / 3, .001));
    });

    test('Zoom enlarges the fitted picture by the zoom level', () {
      final fit = exoVideoRect(screen, 2.0, ExoAspectMode.fit);
      final zoom = exoVideoRect(screen, 2.0, ExoAspectMode.zoom, zoom: 1.25);
      expect(zoom.width, closeTo(fit.width * 1.25, .5));
      expect(zoom.height, closeTo(fit.height * 1.25, .5));
      expect(zoom.center, fit.center);
    });

    test('unusual and portrait pictures keep their shape', () {
      for (final aspect in [9 / 16, 1.0, 1.85, 2.76, 32 / 9]) {
        for (final mode in ExoAspectMode.values) {
          final rect = exoVideoRect(screen, aspect, mode, zoom: 1.1);
          expect(rect.width / rect.height, closeTo(aspect, .001),
              reason: '$aspect $mode');
        }
      }
      expect(exoVideoRect(Size.zero, 1.5, ExoAspectMode.fit), Rect.zero);
    });

    test('an anamorphic stream uses its display aspect, not its pixels', () {
      // 720x576 PAL DVD with a 16:11 pixel aspect ratio: the native player
      // reports width 720*16/11 = 1047 so the picture is ~16:9, not 5:4.
      const value = OrvixExoValue(videoWidth: 1047, videoHeight: 576);
      expect(value.aspectRatio, closeTo(1.818, .01));
    });
  });

  group('saved subtitle style', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips every field and shares size/background with MPV',
        () async {
      const style = ExoSubtitleStyle(
        fontSize: 40,
        typeface: SubtitleTypeface.serif,
        weight: SubtitleWeight.bold,
        textColor: 0xFFFFE14D,
        textOpacity: .8,
        edge: SubtitleEdgeStyle.raised,
        edgeColor: 0xFF5AA9FF,
        outlineWidth: 3,
        shadowStrength: .9,
        background: true,
        backgroundColor: 0xFF000000,
        backgroundOpacity: .4,
        windowColor: 0xFF5CE1E6,
        windowOpacity: .3,
        bottomOffset: 96,
        alignment: SubtitleAlignment.left,
        lineHeight: 1.5,
      );
      await ExoPlayerPreferencesService.setSubtitleStyle(style);
      expect(await ExoPlayerPreferencesService.subtitleStyle(), style);
      expect(await SubtitlePreferencesService.fontSize(), 40);
      expect(await SubtitlePreferencesService.backgroundOpacity(), .4);
      expect(await SubtitlePreferencesService.bottomOffset(), 96);
    });

    test('values are clamped and a damaged value falls back to defaults',
        () async {
      final clamped = const ExoSubtitleStyle().copyWith(
        fontSize: 500,
        textOpacity: 0,
        outlineWidth: 40,
        lineHeight: 9,
        bottomOffset: -5,
      );
      expect(clamped.fontSize, ExoSubtitleStyle.maxFontSize);
      expect(clamped.textOpacity, .25, reason: 'text never disappears');
      expect(clamped.outlineWidth, 5);
      expect(clamped.lineHeight, 1.8);
      expect(clamped.bottomOffset, ExoSubtitleStyle.minBottomOffset);

      SharedPreferences.setMockInitialValues({
        ExoPlayerPreferencesService.styleKey: '{not json',
      });
      expect(await ExoPlayerPreferencesService.subtitleStyle(),
          const ExoSubtitleStyle());
    });

    test('reset restores the defaults', () async {
      await ExoPlayerPreferencesService.setSubtitleStyle(
        const ExoSubtitleStyle(textColor: 0xFFFF5A5A, fontSize: 50),
      );
      final reset = await ExoPlayerPreferencesService.resetSubtitleStyle();
      expect(reset, const ExoSubtitleStyle());
    });

    test('every typeface falls back to the bundled Sinhala font', () {
      expect(ExoSubtitleText.fallbackFonts, contains('OrvixSubtitle'));
      expect(SubtitleTypeface.standard.fontFamily, isNull,
          reason: 'Default keeps the app font');
      for (final typeface in SubtitleTypeface.values) {
        expect(typeface.label, isNotEmpty);
      }
    });
  });

  group('player preferences', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults and validation', () async {
      expect(await ExoPlayerPreferencesService.aspectMode(), ExoAspectMode.fit);
      expect(await ExoPlayerPreferencesService.seekStepSeconds(), 10);
      expect(await ExoPlayerPreferencesService.zoom(), 1.15);
      expect(await ExoPlayerPreferencesService.subtitlesEnabled(), isTrue);
      await ExoPlayerPreferencesService.setSeekStepSeconds(7);
      expect(await ExoPlayerPreferencesService.seekStepSeconds(), 10,
          reason: 'only the offered steps are stored');
      await ExoPlayerPreferencesService.setZoom(9);
      expect(await ExoPlayerPreferencesService.zoom(), 2.0);
      await ExoPlayerPreferencesService.setSubtitleLanguage(' SI ');
      expect(await ExoPlayerPreferencesService.subtitleLanguage(), 'si');
      await ExoPlayerPreferencesService.setAudioLanguage(null);
      expect(await ExoPlayerPreferencesService.audioLanguage(), isNull);
    });
  });
}
