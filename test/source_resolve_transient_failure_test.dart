import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _show = MediaItem(
  id: 'tt0903747',
  kind: MediaKind.series,
  title: 'Breaking Bad',
  year: '2008',
);

const _episode = EpisodeItem(
  id: 'tt0903747:1:2',
  season: 1,
  episode: 2,
  title: "Cat's in the Bag...",
);

String _streams(List<Map<String, Object?>> streams) =>
    jsonEncode(<String, Object?>{'streams': streams});

final _episodeStream = <String, Object?>{
  'name': 'Torrentio\n1080p',
  'title': 'Breaking.Bad.S01E02.1080p.BluRay.x264-GROUP\n'
      'Seeders: 42 Size: 1.4 GB',
  'infoHash': 'a' * 40,
  'fileIdx': 1,
};

enum _Provider { fail, timeout, empty, sources }

/// Every configured provider answers the same way, decided per request.
class _Providers {
  _Provider mode = _Provider.fail;
  int requests = 0;

  late final client = MockClient((request) async {
    requests++;
    switch (mode) {
      case _Provider.fail:
        return http.Response('rate limited', 429);
      case _Provider.timeout:
        throw TimeoutException('provider did not answer');
      case _Provider.empty:
        return http.Response(_streams(const []), 200);
      case _Provider.sources:
        return http.Response(_streams([_episodeStream]), 200);
    }
  });
}

Future<List<SourceResult>> _resolve(
  SourceProviderService service, {
  bool forceRefresh = false,
}) =>
    service.resolve(
      _show,
      episode: _episode,
      includeLowQuality: true,
      forceRefresh: forceRefresh,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('transient provider failure is not a sticky "No sources found"', () {
    for (final failure in [_Provider.fail, _Provider.timeout]) {
      test('${failure.name} -> retry -> sources available', () async {
        final providers = _Providers()..mode = failure;
        final service = SourceProviderService(client: providers.client);

        final first = await _resolve(service);
        expect(first, isEmpty);
        expect(
          service.lastResolveHadProviderFailures(_show, episode: _episode),
          isTrue,
        );

        // Provider recovers. A normal (non-forced) request must ask again
        // instead of replaying the failed empty answer from the cache.
        providers.mode = _Provider.sources;
        final requestsBefore = providers.requests;
        final retry = await _resolve(service);
        expect(providers.requests, greaterThan(requestsBefore));
        expect(retry, isNotEmpty);
        expect(retry.first.resource, contains('a' * 40));
        expect(
          service.lastResolveHadProviderFailures(_show, episode: _episode),
          isFalse,
        );
      });
    }

    test('"Try Again" (forceRefresh) always asks the providers again',
        () async {
      final providers = _Providers()..mode = _Provider.empty;
      final service = SourceProviderService(client: providers.client);

      expect(await _resolve(service), isEmpty);
      providers.mode = _Provider.sources;
      final requestsBefore = providers.requests;
      final retry = await _resolve(service, forceRefresh: true);
      expect(providers.requests, greaterThan(requestsBefore));
      expect(retry, isNotEmpty);
    });
  });

  test('a genuine empty answer is still "No sources found" and is cached',
      () async {
    final providers = _Providers()..mode = _Provider.empty;
    final service = SourceProviderService(client: providers.client);

    expect(await _resolve(service), isEmpty);
    expect(
      service.lastResolveHadProviderFailures(_show, episode: _episode),
      isFalse,
    );

    // Every provider answered, so the empty result is real and reused for the
    // normal cache window instead of hammering the providers.
    final requestsBefore = providers.requests;
    expect(await _resolve(service), isEmpty);
    expect(providers.requests, requestsBefore);
  });

  test('a successful source list is still served from cache', () async {
    final providers = _Providers()..mode = _Provider.sources;
    final service = SourceProviderService(client: providers.client);

    final first = await _resolve(service);
    expect(first, isNotEmpty);

    // Provider goes down; the cached positive answer keeps working.
    providers.mode = _Provider.fail;
    final requestsBefore = providers.requests;
    final second = await _resolve(service);
    expect(providers.requests, requestsBefore);
    expect(second.map((r) => r.resource), first.map((r) => r.resource));
  });
}
