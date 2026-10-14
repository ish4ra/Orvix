import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/services/private_update_channel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> _row(String version, {String digest = _digest}) => {
      'version': version,
      'asset_name': 'Orvix-v$version-Android-TV.apk',
      'size_bytes': 1024,
      'sha256': digest,
      'notes': 'Private notes',
    };

PrivateUpdateChannel _channel({
  required InternalUpdateInvoker invoker,
  bool signedIn = true,
  String platform = 'android_tv',
}) =>
    PrivateUpdateChannel(
      invoker: invoker,
      hasAccountSession: () => signedIn,
      platform: platform,
    );

/// Every Dart file of the app except the dormant channel itself.
Iterable<(String, String)> _appSources() sync* {
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll('\\', '/');
    if (path.endsWith('lib/services/private_update_channel.dart')) continue;
    yield (path, entity.readAsStringSync());
  }
}

void main() {
  group('private update discovery is disabled', () {
    test('no app code constructs or calls the private channel', () {
      for (final (path, source) in _appSources()) {
        expect(source,
            isNot(matches(RegExp(r'''(import|export)\s+['"][^'"]*private_update_channel\.dart'''))),
            reason: path);
        expect(source, isNot(contains('PrivateUpdateChannel')), reason: path);
        expect(source, isNot(contains('orvix-internal-update')), reason: path);
      }
    });

    test('the updater and its UI do not depend on an Orvix account', () {
      for (final file in [
        'lib/services/app_update_service.dart',
        'lib/services/public_release_discovery.dart',
        'lib/widgets/orvix_update_gate.dart',
        'lib/widgets/update_check_section.dart',
      ]) {
        final source = File(file).readAsStringSync();
        expect(source, isNot(contains('supabase')), reason: file);
        expect(source, isNot(contains('Supabase')), reason: file);
      }
    });

    test('a full manual check makes only public GitHub requests', () async {
      final hosts = <String>{};
      final service = AppUpdateService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response('[]', 200);
        }),
        installedVersionLoader: () async => '0.7.10-beta.3',
        platformLoader: () async =>
            const UpdatePlatform(UpdateTarget.androidTv),
      );
      final report = await service.checkForUpdateReport();
      expect(report.status, UpdateCheckStatus.upToDate);
      await service.checkAutomatic();
      expect(hosts, {'api.github.com'});
    });
  });

  // The dormant channel keeps its behaviour so it can be re-enabled
  // deliberately. None of this runs in the app today.
  group('dormant private channel', () {
    test('signed-out users never call the private endpoint', () async {
      var calls = 0;
      final check = await _channel(
        signedIn: false,
        invoker: (_) async {
          calls++;
          return null;
        },
      ).check('0.7.9');
      expect(check.status, PrivateUpdateStatus.signedOut);
      expect(calls, 0);
    });

    test('a normal account (403) is not entitled', () async {
      final check = await _channel(
        invoker: (_) async => throw const FunctionException(
          status: 403,
          details: {'error': 'forbidden'},
        ),
      ).check('0.7.9');
      expect(check.status, PrivateUpdateStatus.notEntitled);
      expect(check.authorized, isFalse);
    });

    test('expired sessions and failed refreshes are reported', () async {
      expect(
        (await _channel(
          invoker: (_) async => throw const FunctionException(status: 401),
        ).check('0.7.9'))
            .status,
        PrivateUpdateStatus.sessionExpired,
      );
      expect(
        (await _channel(
          invoker: (_) async => throw const AuthException('refresh failed'),
        ).check('0.7.9'))
            .status,
        PrivateUpdateStatus.sessionExpired,
      );
    });

    test('an authorized owner is offered the newest verified draft', () async {
      Map<String, Object?>? sent;
      final check = await _channel(
        invoker: (body) async {
          sent = body;
          return {
            'releases': [
              _row('0.7.10-beta.1'),
              _row('0.7.10-beta.3'),
              _row('0.7.10-beta.2', digest: 'not-a-digest'),
            ],
            'drafts_visible': 3,
            'skipped': const [],
          };
        },
      ).check('0.7.9');
      expect(sent, {'action': 'check', 'platform': 'android_tv'});
      expect(check.status, PrivateUpdateStatus.available);
      expect(check.update?.version, '0.7.10-beta.3');
      expect(check.update?.internalVersion, '0.7.10-beta.3');
      expect(check.update?.assetDigest, 'sha256:$_digest');
      expect(check.update?.prerelease, isTrue);
    });

    test('older drafts are not offered', () async {
      final check = await _channel(
        invoker: (_) async => {
          'releases': [_row('0.7.9-beta.71'), _row('0.7.10-beta.1')],
          'drafts_visible': 2,
        },
      ).check('0.7.10-beta.1');
      expect(check.status, PrivateUpdateStatus.noNewerBuild);
      expect(check.update, isNull);
    });

    test('GitHub failures, configuration and HTTP errors are distinguished',
        () async {
      final github = await _channel(
        invoker: (_) async => throw const FunctionException(
          status: 502,
          details: '{"error":"github_unavailable","github_status":403}',
        ),
      ).check('0.7.9');
      expect(github.status, PrivateUpdateStatus.githubUnavailable);
      expect(github.githubStatus, 403);

      final unconfigured = await _channel(
        invoker: (_) async => throw const FunctionException(
          status: 503,
          details: {'error': 'internal_updates_unconfigured'},
        ),
      ).check('0.7.9');
      expect(unconfigured.status, PrivateUpdateStatus.serverUnconfigured);

      final missing = await _channel(
        invoker: (_) async => throw const FunctionException(status: 404),
      ).check('0.7.9');
      expect(missing.failure, 'not_deployed');

      final garbage =
          await _channel(invoker: (_) async => 'not json').check('0.7.9');
      expect(garbage.failure, 'bad_response');
    });

    test('a hanging endpoint times out', () async {
      final timeout = PrivateUpdateChannel.checkTimeout;
      PrivateUpdateChannel.checkTimeout = const Duration(milliseconds: 50);
      addTearDown(() => PrivateUpdateChannel.checkTimeout = timeout);
      final check = await _channel(
        invoker: (_) => Completer<Object?>().future,
      ).check('0.7.9');
      expect(check.failure, 'timeout');
    });

    test('an admin answer without diagnostics marks an old deployment',
        () async {
      final legacy = await _channel(
        invoker: (_) async => {'releases': const []},
      ).check('0.7.9');
      expect(legacy.legacyServer, isTrue);
    });
  });

  test('the server checks admin rights before revealing configuration', () {
    final api = File('supabase/functions/orvix-internal-update/index.ts')
        .readAsStringSync();
    final forbidden = api.indexOf('if (!adminRow)');
    final unconfigured = api.indexOf('"internal_updates_unconfigured"');
    expect(forbidden, greaterThan(0));
    expect(unconfigured, greaterThan(forbidden));
    expect(api, contains('drafts_visible: releases.length'));
    expect(api, contains('error: "github_unavailable"'));
    // Only GitHub's status code is passed on, never its body or headers.
    expect(api, isNot(contains('await response.text()')));
  });
}
