// HLS master-playlist inspection for the experimental TorrentCheap adapter.
//
// Kept TorrentCheap-specific on purpose: no other provider routes through it,
// and the player itself is untouched (mpv already handles HLS master
// playlists and adaptive switching). This only answers "is this a playable
// master playlist, which renditions does it offer, and did the CDN refuse us?"
// before Orvix hands the URL to the player.

import 'dart:async';

import 'package:http/http.dart' as http;

import 'torrentcheap_models.dart';

class TorrentCheapHlsVariant {
  const TorrentCheapHlsVariant({
    required this.uri,
    required this.bandwidth,
    this.width,
    this.height,
    this.codecs,
    this.audioGroup,
    this.subtitleGroup,
  });

  final Uri uri;
  final int bandwidth;
  final int? width;
  final int? height;
  final String? codecs;
  final String? audioGroup;
  final String? subtitleGroup;

  /// "800p"-style label when the height is known, else the bitrate.
  String get label {
    if (height != null) return '${height}p';
    return '${(bandwidth / 1000).round()} kbps';
  }
}

class TorrentCheapHlsMedia {
  const TorrentCheapHlsMedia({
    required this.type,
    required this.groupId,
    required this.name,
    this.uri,
    this.language,
    this.isDefault = false,
  });

  /// AUDIO, SUBTITLES or CLOSED-CAPTIONS.
  final String type;
  final String groupId;
  final String name;
  final Uri? uri;
  final String? language;
  final bool isDefault;
}

class TorrentCheapHlsMaster {
  const TorrentCheapHlsMaster({
    required this.variants,
    required this.media,
  });

  final List<TorrentCheapHlsVariant> variants;
  final List<TorrentCheapHlsMedia> media;

  /// Highest-bandwidth variant first.
  List<TorrentCheapHlsVariant> get variantsByQuality {
    final sorted = List<TorrentCheapHlsVariant>.of(variants);
    sorted.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return sorted;
  }

  List<TorrentCheapHlsMedia> get audioTracks =>
      media.where((m) => m.type == 'AUDIO').toList(growable: false);

  List<TorrentCheapHlsMedia> get subtitleTracks =>
      media.where((m) => m.type == 'SUBTITLES').toList(growable: false);

  /// Parses an HLS master playlist and resolves relative URIs against
  /// [playlistUri]. Throws [TorrentCheapException] with
  /// [TorrentCheapErrorKind.unsupportedStream] for anything that is not a
  /// master playlist with at least one variant.
  static TorrentCheapHlsMaster parse(String body, Uri playlistUri) {
    final lines = body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty || lines.first != '#EXTM3U') {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.unsupportedStream,
        'TorrentCheap did not return an HLS playlist.',
      );
    }

    final variants = <TorrentCheapHlsVariant>[];
    final media = <TorrentCheapHlsMedia>[];
    Map<String, String>? pendingVariant;

    for (final line in lines.skip(1)) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingVariant = _attributes(line.substring('#EXT-X-STREAM-INF:'.length));
        continue;
      }
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = _attributes(line.substring('#EXT-X-MEDIA:'.length));
        final type = attrs['TYPE'];
        final group = attrs['GROUP-ID'];
        if (type == null || group == null) continue;
        final rawUri = attrs['URI'];
        media.add(TorrentCheapHlsMedia(
          type: type,
          groupId: group,
          name: attrs['NAME'] ?? attrs['LANGUAGE'] ?? group,
          uri: rawUri == null ? null : playlistUri.resolve(rawUri),
          language: attrs['LANGUAGE'],
          isDefault: attrs['DEFAULT'] == 'YES',
        ));
        continue;
      }
      if (line.startsWith('#')) continue;

      // A URI line. Only meaningful directly after EXT-X-STREAM-INF.
      final attrs = pendingVariant;
      pendingVariant = null;
      if (attrs == null) continue;
      final resolution = attrs['RESOLUTION']?.toLowerCase().split('x');
      variants.add(TorrentCheapHlsVariant(
        uri: playlistUri.resolve(line),
        bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0,
        width: resolution != null && resolution.length == 2
            ? int.tryParse(resolution[0])
            : null,
        height: resolution != null && resolution.length == 2
            ? int.tryParse(resolution[1])
            : null,
        codecs: attrs['CODECS'],
        audioGroup: attrs['AUDIO'],
        subtitleGroup: attrs['SUBTITLES'],
      ));
    }

    if (variants.isEmpty) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.unsupportedStream,
        'TorrentCheap returned a media playlist, not a master playlist.',
      );
    }
    return TorrentCheapHlsMaster(
      variants: List.unmodifiable(variants),
      media: List.unmodifiable(media),
    );
  }

  static Map<String, String> _attributes(String raw) {
    final result = <String, String>{};
    final pattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
    for (final match in pattern.allMatches(raw)) {
      var value = match.group(2)!;
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      result[match.group(1)!] = value;
    }
    return result;
  }
}

/// Fetches and validates a master playlist with the headers the transport
/// supplied. It never follows the playlist into segments, so it costs one
/// small request and no streaming bandwidth.
class TorrentCheapHlsProbe {
  TorrentCheapHlsProbe({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const _playlistContentTypes = <String>{
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl',
  };

  Future<TorrentCheapHlsMaster> inspect(
    TorrentCheapPlaybackSource source, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final http.Response response;
    try {
      response = await _client
          .get(source.masterPlaylistUri, headers: source.httpHeaders)
          .timeout(timeout);
    } on TimeoutException {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.timeout,
        'TorrentCheap stream did not respond in time.',
      );
    } on http.ClientException {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.network,
        'Could not reach the TorrentCheap stream server.',
      );
    }

    switch (response.statusCode) {
      case 200:
        break;
      case 401:
      case 403:
        throw const TorrentCheapException(
          TorrentCheapErrorKind.unauthorized,
          'TorrentCheap refused this stream for an outside player.',
        );
      case 404:
      case 410:
        throw const TorrentCheapException(
          TorrentCheapErrorKind.streamExpired,
          'This TorrentCheap stream link has expired or was removed.',
        );
      case 429:
        throw const TorrentCheapException(
          TorrentCheapErrorKind.rateLimited,
          'TorrentCheap is rate limiting stream requests. Try again shortly.',
        );
      default:
        throw TorrentCheapException(
          TorrentCheapErrorKind.provider,
          'TorrentCheap stream request failed (HTTP ${response.statusCode}).',
        );
    }

    final contentType =
        (response.headers['content-type'] ?? '').split(';').first.trim();
    if (contentType.isNotEmpty &&
        !_playlistContentTypes.contains(contentType.toLowerCase())) {
      throw const TorrentCheapException(
        TorrentCheapErrorKind.unsupportedStream,
        'TorrentCheap returned something other than an HLS playlist.',
      );
    }

    // package:http does not expose the post-redirect URL, so relative
    // rendition URIs resolve against the URL we asked for. mpv resolves them
    // itself during playback; this is only used for inspection.
    return TorrentCheapHlsMaster.parse(response.body, source.masterPlaylistUri);
  }

  void dispose() => _client.close();
}
