import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:path_provider/path_provider.dart';

class ExtractedEmbeddedSubtitle {
  const ExtractedEmbeddedSubtitle({
    required this.content,
    required this.identity,
    required this.label,
    required this.streamIndex,
    required this.codec,
  });

  final String content;
  final String identity;
  final String label;
  final int streamIndex;
  final String codec;
}

class EmbeddedSubtitleExtractorService {
  EmbeddedSubtitleExtractorService._();

  static const _imageSubtitleCodecs = <String>{
    'hdmv_pgs_subtitle',
    'pgssub',
    'dvd_subtitle',
    'dvb_subtitle',
    'dvb_teletext',
    'xsub',
  };

  static const _networkTimeoutMicros = '30000000';

  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isWindows || Platform.isMacOS;

  static Future<ExtractedEmbeddedSubtitle?> extractEnglishText({
    required String videoUrl,
    String? preferredTrackLabel,
  }) async {
    if (!isSupportedPlatform) return null;

    final uri = Uri.tryParse(videoUrl);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }

    final tracks = await _probeSubtitleTracks(videoUrl);
    if (tracks.isEmpty) return null;

    final candidates = tracks
        .where((track) => !_imageSubtitleCodecs.contains(track.codec))
        .map(
          (track) => (
            track: track,
            score: _englishScore(
              track,
              preferredTrackLabel: preferredTrackLabel,
            ),
          ),
        )
        .where((entry) => entry.score > 0)
        .toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));

    for (final candidate in candidates) {
      final extracted = await _extractTrack(
        videoUrl,
        candidate.track,
      );
      if (extracted != null) return extracted;
    }
    return null;
  }

  static Future<List<_SubtitleTrackInfo>> _probeSubtitleTracks(
    String videoUrl,
  ) async {
    try {
      final session = await FFprobeKit.executeWithArguments(<String>[
        '-v',
        'error',
        '-rw_timeout',
        _networkTimeoutMicros,
        '-probesize',
        '12000000',
        '-analyzeduration',
        '12000000',
        '-select_streams',
        's',
        '-show_entries',
        'stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired',
        '-of',
        'json',
        videoUrl,
      ]).timeout(const Duration(seconds: 40));

      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code)) return const [];

      final output = (await session.getOutput())?.trim() ?? '';
      if (output.isEmpty) return const [];
      final decoded = jsonDecode(output);
      final streams = decoded is Map ? decoded['streams'] : null;
      if (streams is! List) return const [];

      final result = <_SubtitleTrackInfo>[];
      for (final raw in streams) {
        if (raw is! Map) continue;
        final index = raw['index'] is num
            ? (raw['index'] as num).toInt()
            : int.tryParse(raw['index']?.toString() ?? '');
        if (index == null || index < 0) continue;

        final tags = raw['tags'] is Map
            ? Map<String, dynamic>.from(raw['tags'] as Map)
            : const <String, dynamic>{};
        final disposition = raw['disposition'] is Map
            ? Map<String, dynamic>.from(raw['disposition'] as Map)
            : const <String, dynamic>{};

        result.add(
          _SubtitleTrackInfo(
            index: index,
            codec: (raw['codec_name']?.toString() ?? '').trim().toLowerCase(),
            language: (tags['language']?.toString() ?? '').trim().toLowerCase(),
            title: (tags['title']?.toString() ?? '').trim(),
            forced: _truthy(disposition['forced']),
            hearingImpaired: _truthy(disposition['hearing_impaired']),
          ),
        );
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static Future<ExtractedEmbeddedSubtitle?> _extractTrack(
    String videoUrl,
    _SubtitleTrackInfo track,
  ) async {
    File? output;
    try {
      final temp = await getTemporaryDirectory();
      final digest = sha256
          .convert(utf8.encode('$videoUrl|\${track.index}|\${track.codec}'))
          .toString();
      final dir = Directory(
        '\${temp.path}\${Platform.pathSeparator}orvix-embedded-subtitles',
      );
      await dir.create(recursive: true);
      output = File(
        '\${dir.path}\${Platform.pathSeparator}embedded_$digest.srt',
      );
      if (await output.exists()) await output.delete();

      final session = await FFmpegKit.executeWithArguments(<String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-rw_timeout',
        _networkTimeoutMicros,
        '-i',
        videoUrl,
        '-map',
        '0:\${track.index}',
        '-vn',
        '-an',
        '-dn',
        '-c:s',
        'srt',
        output.path,
      ]).timeout(const Duration(minutes: 4));

      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code) ||
          !await output.exists() ||
          await output.length() < 64) {
        return null;
      }

      final content = (await output.readAsString()).trim();
      if (!content.contains('-->')) return null;

      final urlDigest = sha256.convert(utf8.encode(videoUrl)).toString();
      final labelParts = <String>[
        if (track.language.isNotEmpty) track.language,
        if (track.title.isNotEmpty) track.title,
        if (track.codec.isNotEmpty) track.codec,
      ];
      return ExtractedEmbeddedSubtitle(
        content: content,
        identity: 'ffmpegkit-embedded://$urlDigest/\${track.index}',
        label: labelParts.isEmpty
            ? 'English embedded'
            : labelParts.join(' • '),
        streamIndex: track.index,
        codec: track.codec,
      );
    } catch (_) {
      return null;
    } finally {
      if (output != null) {
        try {
          if (await output.exists()) await output.delete();
        } catch (_) {}
      }
    }
  }

  static int _englishScore(
    _SubtitleTrackInfo track, {
    String? preferredTrackLabel,
  }) {
    final language = track.language;
    final title = track.title.toLowerCase();
    final codec = track.codec.toLowerCase();
    final combined = '$language $title $codec';
    var score = 0;

    if (language == 'eng' || language == 'en' || language == 'english') {
      score += 180;
    }
    if (title.contains('english')) score += 150;
    if (RegExp(r'(^|[^a-z])eng([^a-z]|$)').hasMatch(combined)) score += 120;
    if (RegExp(r'(^|[^a-z])en([^a-z]|$)').hasMatch(combined)) score += 80;

    final preferred = preferredTrackLabel?.trim().toLowerCase() ?? '';
    if (preferred.isNotEmpty) {
      if (combined.contains(preferred) ||
          (title.isNotEmpty && preferred.contains(title))) {
        score += 220;
      } else {
        final preferredTokens = RegExp(r'[a-z0-9]+')
            .allMatches(preferred)
            .map((m) => m.group(0) ?? '')
            .where((value) => value.length >= 2);
        for (final token in preferredTokens) {
          if (combined.contains(token)) score += 16;
        }
      }
    }

    if (track.forced || title.contains('forced')) score -= 120;
    if (title.contains('commentary')) score -= 220;
    if (title.contains('foreign') ||
        title.contains('signs') ||
        title.contains('songs')) {
      score -= 100;
    }
    if (track.hearingImpaired ||
        title.contains('sdh') ||
        title.contains('hearing')) {
      score -= 15;
    }
    return score;
  }

  static bool _truthy(Object? value) =>
      value == true ||
      value == 1 ||
      value?.toString().toLowerCase() == 'true';

  // Pure regression-test hook. Native FFmpegKit is never invoked by unit tests.
  static int scoreTrackForTesting({
    required int index,
    required String codec,
    String language = '',
    String title = '',
    bool forced = false,
    bool hearingImpaired = false,
    String? preferredTrackLabel,
  }) =>
      _englishScore(
        _SubtitleTrackInfo(
          index: index,
          codec: codec.toLowerCase(),
          language: language.toLowerCase(),
          title: title,
          forced: forced,
          hearingImpaired: hearingImpaired,
        ),
        preferredTrackLabel: preferredTrackLabel,
      );
}

class _SubtitleTrackInfo {
  const _SubtitleTrackInfo({
    required this.index,
    required this.codec,
    required this.language,
    required this.title,
    required this.forced,
    required this.hearingImpaired,
  });

  final int index;
  final String codec;
  final String language;
  final String title;
  final bool forced;
  final bool hearingImpaired;
}
