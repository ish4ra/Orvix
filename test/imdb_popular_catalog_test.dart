import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/catalog_service.dart';

void main() {
  test('popular movies use the live IMDb most-popular chart', () async {
    final client = MockClient((request) async {
      if (request.url.toString() == 'https://caching.graphql.imdb.com/') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final query = payload['query'].toString();
        expect(query, contains('MOST_POPULAR_MOVIES'));
        expect(query, isNot(contains('TOP_RATED_MOVIES')));
        return http.Response(
          jsonEncode({
            'data': {
              'chartTitles': {
                'edges': [
                  {
                    'node': {
                      'id': 'tt1234567',
                      'titleText': {'text': 'Popular Test'},
                      'primaryImage': {
                        'url': 'https://example.invalid/popular.jpg',
                      },
                      'releaseYear': {'year': 2026},
                      'ratingsSummary': {
                        'aggregateRating': 7.8,
                        'voteCount': 1000,
                      },
                      'runtime': {'seconds': 7200},
                    },
                  },
                ],
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

    final results = await catalog.popularMovies(limit: 10);
    expect(results, hasLength(1));
    expect(results.first.title, 'Popular Test');
    expect(results.first.year, '2026');
    expect(results.first.rating, 7.8);
  });
}
