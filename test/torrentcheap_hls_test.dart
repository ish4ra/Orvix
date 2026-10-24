import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/torrentcheap_hls.dart';
import 'package:orvix/services/torrentcheap_models.dart';

// Synthetic playlist shaped like the renditions seen in TorrentCheap's web
// player (480p, 800p, separate audio, thumbnails). Not a captured response.
const _master = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Audio",LANGUAGE="und",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480,CODECS="avc1.64001e,mp4a.40.2",AUDIO="aud"
480p.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1422x800,CODECS="avc1.640020,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
800p.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"
''';

final _uri = Uri.parse(
    'https://s00.torrentcheap.com/files/video-stream/test/master.m3u8');

TorrentCheapPlaybackSource _source({Map<String, String> headers = const {}}) =>
    TorrentCheapPlaybackSource(masterPlaylistUri: _uri, httpHeaders: headers);

Matcher _throwsKind(TorrentCheapErrorKind kind) => throwsA(
      isA<TorrentCheapException>().having((e) => e.kind, 'kind', kind),
    );

void main() {
  group('master playlist parsing', () {
    test('reads renditions, audio and subtitles with resolved URIs', () {
      final master = TorrentCheapHlsMaster.parse(_master, _uri);

      expect(master.variants, hasLength(2));
      expect(master.variantsByQuality.map((v) => v.label), ['800p', '480p']);
      final best = master.variantsByQuality.first;
      expect(best.uri.toString(),
          'https://s00.torrentcheap.com/files/video-stream/test/800p.m3u8');
      expect(best.width, 1422);
      expect(best.codecs, 'avc1.640020,mp4a.40.2');
      expect(best.audioGroup, 'aud');
      expect(best.subtitleGroup, 'subs');

      expect(master.audioTracks.single.isDefault, isTrue);
      expect(master.audioTracks.single.uri.toString(),
          'https://s00.torrentcheap.com/files/video-stream/test/audio.m3u8');
      expect(master.subtitleTracks.single.language, 'en');
      expect(master.subtitleTracks.single.uri!.path,
          '/files/video-stream/test/subs/en.m3u8');
    });

    test('accepts CRLF line endings', () {
      final master =
          TorrentCheapHlsMaster.parse(_master.replaceAll('\n', '\r\n'), _uri);
      expect(master.variants, hasLength(2));
    });

    test('labels a variant without resolution by bitrate', () {
      final master = TorrentCheapHlsMaster.parse(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=640000\nlow.m3u8\n',
        _uri,
      );
      expect(master.variants.single.label, '640 kbps');
    });

    test('rejects a media playlist', () {
      expect(
        () => TorrentCheapHlsMaster.parse(
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI="800p_init.mp4"\n'
          '#EXTINF:6.0,\n800p_00000.m4s\n#EXT-X-ENDLIST\n',
          _uri,
        ),
        _throwsKind(TorrentCheapErrorKind.unsupportedStream),
      );
    });

    test('rejects a body that is not HLS at all', () {
      for (final body in ['', '<html>Sign in</html>', '{"error":"x"}']) {
        expect(
          () => TorrentCheapHlsMaster.parse(body, _uri),
          _throwsKind(TorrentCheapErrorKind.unsupportedStream),
          reason: body,
        );
      }
    });
  });

  group('probe', () {
    test('sends the transport headers and parses the playlist', () async {
      late http.Request seen;
      final probe = TorrentCheapHlsProbe(
        client: MockClient((request) async {
          seen = request;
          return http.Response(_master, 200, headers: {
            'content-type': 'application/vnd.apple.mpegurl',
            'access-control-allow-origin': '*',
          });
        }),
      );

      final master = await probe.inspect(
          _source(headers: const {'Referer': 'https://www.torrentcheap.com/'}));
      expect(seen.method, 'GET');
      expect(seen.url, _uri);
      expect(seen.headers['Referer'], 'https://www.torrentcheap.com/');
      expect(master.variants, hasLength(2));
    });

    test('maps CDN refusals to specific errors', () async {
      final cases = {
        401: TorrentCheapErrorKind.unauthorized,
        403: TorrentCheapErrorKind.unauthorized,
        404: TorrentCheapErrorKind.streamExpired,
        410: TorrentCheapErrorKind.streamExpired,
        429: TorrentCheapErrorKind.rateLimited,
        500: TorrentCheapErrorKind.provider,
      };
      for (final entry in cases.entries) {
        final probe = TorrentCheapHlsProbe(
          client: MockClient((_) async => http.Response('', entry.key)),
        );
        await expectLater(
          probe.inspect(_source()),
          _throwsKind(entry.value),
          reason: 'HTTP ${entry.key}',
        );
      }
    });

    test('rejects an HTML login page served with HTTP 200', () async {
      final probe = TorrentCheapHlsProbe(
        client: MockClient((_) async => http.Response(
              '<html>Sign in</html>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            )),
      );
      await expectLater(
        probe.inspect(_source()),
        _throwsKind(TorrentCheapErrorKind.unsupportedStream),
      );
    });

    test('reports network failures without the stream URL', () async {
      final probe = TorrentCheapHlsProbe(
        client: MockClient((request) async =>
            throw http.ClientException('reset', request.url)),
      );
      try {
        await probe.inspect(_source());
        fail('expected an exception');
      } on TorrentCheapException catch (e) {
        expect(e.kind, TorrentCheapErrorKind.network);
        expect(e.message, isNot(contains('video-stream')));
      }
    });
  });
}
