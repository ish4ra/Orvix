import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/screens/supporters_screen.dart';
import 'package:orvix/services/supporters_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Fake rows in the shape list_public_supporters returns
// (supabase/migrations/20261008130000_public_supporters_contract.sql).
const _publicRows = [
  {
    'display_name': 'Fake Sponsor',
    'avatar_url': null,
    'profile_url': 'https://github.example.test/fake-sponsor',
    'provider': 'github',
    'support_type': 'Sponsor',
    'tier': 'Fake tier',
    'supporter_since': '2026-01-01T00:00:00+00:00',
  },
  {
    'display_name': 'Fake Kofi Fan',
    'avatar_url': null,
    'profile_url': null,
    'provider': 'kofi',
    'support_type': 'Supporter',
    'tier': null,
    'supporter_since': '2026-01-02T00:00:00+00:00',
  },
];

class _FakeSupporters implements SupportersRepository {
  @override
  Future<List<OrvixContributor>> fetchContributors() async => const [];

  @override
  Future<List<OrvixSupporter>> fetchPublicSupporters() async =>
      _publicRows.map(OrvixSupporter.fromJson).toList();
}

void main() {
  group('supporter models', () {
    test('maps private or missing display names safely', () {
      final supporter = OrvixSupporter.fromJson({
        'display_name': '  ',
        'provider': 'kofi',
        'support_type': 'Member',
        'tier': 'Bronze',
        'supporter_since': '2026-09-30T00:00:00Z',
      });
      expect(supporter.name, 'Anonymous supporter');
      expect(supporter.providerLabel, 'Ko-fi');
      expect(supporter.supportType, 'Member');
      expect(supporter.tier, 'Bronze');
      expect(supporter.since.toUtc(), DateTime.utc(2026, 9, 30));
    });

    test('maps GitHub contributors', () {
      final contributor = OrvixContributor.fromJson({
        'login': 'contributor',
        'contributions': 7,
        'avatar_url': 'https://example.com/avatar.png',
      });
      expect(contributor.login, 'contributor');
      expect(contributor.contributions, 7);
      expect(contributor.avatarUrl, 'https://example.com/avatar.png');
    });
  });

  group('public supporters contract', () {
    test('reads list_public_supporters, never the supporters table', () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://backend.example.test',
        'fake-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(_publicRows), 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
      );
      addTearDown(client.dispose);

      final supporters =
          await SupabaseSupportersRepository(client: client).fetchPublicSupporters();

      expect(requests, hasLength(1));
      final url = requests.single.url;
      expect(url.path, '/rest/v1/rpc/list_public_supporters');
      expect(url.toString(), isNot(contains('provider_user_id')));
      expect(supporters.map((s) => s.name), ['Fake Sponsor', 'Fake Kofi Fan']);
      expect(supporters.first.providerLabel, 'GitHub Sponsors');
      expect(supporters.first.profileUrl, 'https://github.example.test/fake-sponsor');
    });

    test('the client no longer depends on provider_user_id', () {
      // Hidden and provider test rows are excluded on the server; a public
      // client must not receive them just to filter them locally.
      final source = File('lib/services/supporters_service.dart').readAsStringSync();
      expect(source, isNot(contains('provider_user_id')));
      expect(source, isNot(contains(".from('supporters')")));
    });
  });

  testWidgets('public supporters still render on the Supporters screen', (tester) async {
    SupportersService.repository = _FakeSupporters();
    // The Supporters list already raises Flutter's debug-only ListTile ink
    // notice on develop (see shell_destination_state_test.dart); tolerate
    // that notice and nothing else.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('ListTile background color')) {
        previous?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = previous);
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SupportersScreen())));
    await tester.pumpAndSettle();

    expect(find.text('Fake Sponsor'), findsOneWidget);
    expect(find.text('GitHub Sponsors • Sponsor • Fake tier'), findsOneWidget);
    expect(find.text('Fake Kofi Fan'), findsOneWidget);
    expect(find.text('Ko-fi • Supporter'), findsOneWidget);
  });
}
