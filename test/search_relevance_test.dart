import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:orvix/models/media_item.dart';
import 'package:orvix/services/catalog_service.dart';

void main() {
  test('famous exact-title TV result outranks obscure same-name movies', () async {
    final client = MockClient((request) async {
      final url = request.url.toString();

      if (url.contains('/catalog/movie/top/search=Prison%20Break.json')) {
        return http.Response(
          jsonEncode({
            'metas': [
              {
                'id': 'tt0000001',
                'name': 'Prison Break',
                'year': '1938',
                'poster': 'https://example.invalid/1938.jpg',
              },
              {
                'id': 'tt0000002',
                'name': 'Prison Break',
                'year': '2015',
                'poster': 'https://example.invalid/2015.jpg',
              },
            ],
          }),
          200,
        );
      }

      if (url.contains('/catalog/series/top/search=Prison%20Break.json')) {
        return http.Response(
          jsonEncode({
            'metas': [
              {
                'id': 'tt0455275',
                'name': 'Prison Break',
                'year': '2005-2017',
                'poster': 'https://example.invalid/series.jpg',
              },
            ],
          }),
          200,
        );
      }

      if (url == 'https://caching.graphql.imdb.com/') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], contains('tt0455275'));
        return http.Response(
          jsonEncode({
            'data': {
              't0': {
                'ratingsSummary': {
                  'aggregateRating': 5.5,
                  'voteCount': 700,
                },
                'primaryImage': {'url': 'https://example.invalid/1938-imdb.jpg'},
              },
              't1': {
                'ratingsSummary': {
                  'aggregateRating': 4.2,
                  'voteCount': 120,
                },
                'primaryImage': {'url': 'https://example.invalid/2015-imdb.jpg'},
              },
              't2': {
                'ratingsSummary': {
                  'aggregateRating': 8.3,
                  'voteCount': 650000,
                },
                'primaryImage': {'url': 'https://example.invalid/2005-imdb.jpg'},
              },
            },
          }),
          200,
        );
      }

      return http.Response('not found', 404);
    });

    final catalog = CatalogService(client: client);
    addTearDown(catalog.dispose);

    final results = await catalog.search('Prison Break', limit: 10);

    expect(results, isNotEmpty);
    expect(results.first.id, 'tt0455275');
    expect(results.first.kind, MediaKind.series);
    expect(results.first.year, '2005-2017');
    expect(results.first.poster, 'https://example.invalid/2005-imdb.jpg');
  });
}
