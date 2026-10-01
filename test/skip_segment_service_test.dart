import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:orvix/services/skip_segment_service.dart';

void main() {
  tearDown(IntroDbService.clearCache);

  test('IntroDB episode response becomes manual skip segments', () async {
    late Uri requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response(
        '{"imdb_id":"tt0903747","season":1,"episode":1,'
        '"intro":{"start_sec":2.0,"end_sec":58.0},'
        '"recap":{"start_ms":60000,"end_ms":90000}}',
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    final segments = await IntroDbService(client: client).segments(
      imdbId: 'cinemeta:tt0903747:1:1',
      season: 1,
      episode: 1,
    );

    expect(requested.host, 'api.introdb.app');
    expect(requested.path, '/segments');
    expect(requested.queryParameters, {
      'imdb_id': 'tt0903747',
      'season': '1',
      'episode': '1',
    });
    expect(segments, hasLength(2));
    expect(segments.first.type, SkipSegmentType.intro);
    expect(segments.first.start, const Duration(seconds: 2));
    expect(segments.first.end, const Duration(seconds: 58));
    expect(segments.first.contains(const Duration(seconds: 23)), isTrue);
    expect(segments.first.contains(const Duration(seconds: 58)), isFalse);
  });

  test('clock-style IntroDB timestamps are accepted', () async {
    final client = MockClient((_) async => http.Response(
          '{"intro":{"start_sec":"00:00:12.5","end_sec":"00:01:03"}}',
          200,
        ));

    final segments = await IntroDbService(client: client).segments(
      imdbId: 'tt0903747',
      season: 1,
      episode: 2,
    );

    expect(segments.single.start, const Duration(milliseconds: 12500));
    expect(segments.single.end, const Duration(seconds: 63));
  });
}
