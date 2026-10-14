import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/widgets/update_check_section.dart';
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

/// Public GitHub answers with an empty release list: reachable, nothing new.
http.Client _publicUpToDate() =>
    MockClient((request) async => http.Response('[]', 200));

http.Client _publicDown() =>
    MockClient((request) async => http.Response('unavailable', 503));

AppUpdateService _service({
  required InternalUpdateInvoker invoker,
  bool signedIn = true,
  String platform = 'android_tv',
  http.Client? client,
  String installed = '0.7.9',
}) =>
    AppUpdateService(
      client: client ?? _publicUpToDate(),
      installedVersionLoader: () async => installed,
      internalInvoker: invoker,
      hasAccountSession: () => signedIn,
      internalPlatform: platform,
    );

void main() {
  group('private update channel', () {
    test('signed-out users never call the private endpoint', () async {
      var calls = 0;
      final service = _service(
        signedIn: false,
        invoker: (_) async {
          calls++;
          return null;
        },
      );
      final report = await service.checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.signedOut);
      expect(calls, 0);
      expect(report.update, isNull);
    });

    test('a normal account (403) learns nothing about private builds',
        () async {
      final service = _service(
        invoker: (_) async => throw const FunctionException(
          status: 403,
          details: {'error': 'forbidden'},
        ),
      );
      final report = await service.checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.notEntitled);
      expect(report.private.authorized, isFalse);
      final summary = describeUpdateCheck(report);
      expect(summary.headline, 'Orvix is up to date');
      final text = [summary.headline, ...summary.details].join(' ');
      expect(text.toLowerCase(), isNot(contains('private')));
      expect(text.toLowerCase(), isNot(contains('draft')));
    });

    test('an expired session is reported, not hidden', () async {
      final service = _service(
        invoker: (_) async => throw const FunctionException(status: 401),
      );
      final report = await service.checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.sessionExpired);
      expect(
        describeUpdateCheck(report).details.join(' '),
        contains('session expired'),
      );
    });

    test('a failed session refresh counts as an expired session', () async {
      final service = _service(
        invoker: (_) async => throw const AuthException('refresh failed'),
      );
      final report = await service.checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.sessionExpired);
    });

    test('an authorized owner is offered a newer private draft', () async {
      Map<String, Object?>? sent;
      final service = _service(
        invoker: (body) async {
          sent = body;
          return {
            'releases': [_row('0.7.10-beta.1'), _row('0.7.9-beta.71')],
            'drafts_visible': 2,
            'skipped': const [],
          };
        },
      );
      final report = await service.checkForUpdateReport();
      expect(sent, {'action': 'check', 'platform': 'android_tv'});
      expect(report.private.status, PrivateUpdateStatus.available);
      expect(report.private.authorized, isTrue);
      expect(report.update?.version, '0.7.10-beta.1');
      expect(report.update?.internalVersion, '0.7.10-beta.1');
      expect(report.update?.assetDigest, 'sha256:$_digest');
      expect(report.isPrivateUpdate, isTrue);
      final summary = describeUpdateCheck(report);
      expect(summary.headline, 'Orvix 0.7.10-beta.1 is available');
      expect(summary.canInstall, isTrue);
      expect(summary.privateBuild, isTrue);
    });

    test('older drafts are not offered', () async {
      final service = _service(
        installed: '0.7.10-beta.1',
        invoker: (_) async => {
          'releases': [_row('0.7.9-beta.71'), _row('0.7.10-beta.1')],
          'drafts_visible': 2,
          'skipped': const [],
        },
      );
      final report = await service.checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.noNewerBuild);
      expect(report.update, isNull);
      expect(describeUpdateCheck(report).details.join(' '),
          contains('no newer test build'));
    });

    test('a draft without a valid sha256 is never offered', () async {
      final service = _service(
        invoker: (_) async => {
          'releases': [_row('0.7.10-beta.1', digest: 'not-a-digest')],
          'drafts_visible': 1,
        },
      );
      final report = await service.checkForUpdateReport();
      expect(report.update, isNull);
      expect(report.private.status, PrivateUpdateStatus.noNewerBuild);
    });

    test('no visible drafts points at the server token', () async {
      final service = _service(
        invoker: (_) async =>
            {'releases': const [], 'drafts_visible': 0, 'skipped': const []},
      );
      final summary =
          describeUpdateCheck(await service.checkForUpdateReport());
      expect(summary.details.join(' '), contains('sees no draft releases'));
    });

    test('drafts without this platform installer are explained', () async {
      // v0.7.10-beta.1 is an Android-only draft: Windows has nothing to get.
      final service = _service(
        platform: 'windows',
        invoker: (_) async => {
          'releases': const [],
          'drafts_visible': 3,
          'skipped': const [
            {'version': '0.7.10-beta.1', 'reason': 'no_platform_asset'},
          ],
        },
      );
      final summary =
          describeUpdateCheck(await service.checkForUpdateReport());
      expect(summary.details.join(' '),
          contains('1 draft without an installer for it'));
    });

    test('GitHub failures and missing configuration are distinguished',
        () async {
      final github = await _service(
        invoker: (_) async => throw const FunctionException(
          status: 502,
          details: {'error': 'github_unavailable', 'github_status': 401},
        ),
      ).checkForUpdateReport();
      expect(github.private.status, PrivateUpdateStatus.githubUnavailable);
      expect(github.private.githubStatus, 401);
      expect(describeUpdateCheck(github).details.join(' '),
          contains('HTTP 401'));

      // A body that arrives as text (non-JSON content type) is decoded too.
      final textBody = await _service(
        invoker: (_) async => throw const FunctionException(
          status: 502,
          details: '{"error":"github_unavailable","github_status":403}',
        ),
      ).checkForUpdateReport();
      expect(textBody.private.status, PrivateUpdateStatus.githubUnavailable);
      expect(textBody.private.githubStatus, 403);

      final unconfigured = await _service(
        invoker: (_) async => throw const FunctionException(
          status: 503,
          details: {'error': 'internal_updates_unconfigured'},
        ),
      ).checkForUpdateReport();
      expect(
        unconfigured.private.status,
        PrivateUpdateStatus.serverUnconfigured,
      );
    });

    test('an unreachable private endpoint never blocks the public check',
        () async {
      final timeout = AppUpdateService.privateCheckTimeout;
      AppUpdateService.privateCheckTimeout = const Duration(milliseconds: 50);
      addTearDown(() => AppUpdateService.privateCheckTimeout = timeout);
      final report = await _service(
        invoker: (_) => Completer<Object?>().future,
      ).checkForUpdateReport();
      expect(report.private.status, PrivateUpdateStatus.unavailable);
      expect(report.private.failure, 'timeout');
      expect(report.publicStatus, PublicUpdateStatus.upToDate);
      final text = describeUpdateCheck(report).details.join(' ');
      expect(text, contains('did not answer in time'));
      expect(text.toLowerCase(), isNot(contains('private')),
          reason: 'The account may not be an admin');
      expect(text.toLowerCase(), isNot(contains('draft')));
    });

    test('the private check waits long enough for a cold Edge Function', () {
      expect(AppUpdateService.privateCheckTimeout,
          greaterThanOrEqualTo(const Duration(seconds: 15)));
    });

    test('a missing function and other HTTP failures are named', () async {
      final missing = await _service(
        invoker: (_) async => throw const FunctionException(status: 404),
      ).checkForUpdateReport();
      expect(missing.private.failure, 'not_deployed');
      expect(describeUpdateCheck(missing).details.join(' '),
          contains('has no update function deployed'));

      final crashed = await _service(
        invoker: (_) async => throw const FunctionException(
            status: 500, details: {'error': 'boom'}),
      ).checkForUpdateReport();
      expect(crashed.private.failure, 'http_500');
      expect(describeUpdateCheck(crashed).details.join(' '),
          contains('failed (HTTP 500)'));

      final garbage = await _service(
        invoker: (_) async => 'not json',
      ).checkForUpdateReport();
      expect(garbage.private.failure, 'bad_response');
    });

    test('an admin answer without diagnostics points at an old deployment',
        () async {
      final legacy = await _service(
        invoker: (_) async => {'releases': const []},
      ).checkForUpdateReport();
      expect(legacy.private.status, PrivateUpdateStatus.noNewerBuild);
      expect(legacy.private.legacyServer, isTrue);
      expect(describeUpdateCheck(legacy).details.join(' '),
          contains('older orvix-internal-update'));

      final noDrafts = await _service(
        invoker: (_) async => {'releases': const [], 'drafts_visible': 0},
      ).checkForUpdateReport();
      expect(noDrafts.private.legacyServer, isFalse);
      expect(describeUpdateCheck(noDrafts).details.join(' '),
          contains('the server sees no draft releases'));
    });

    test('v0.7.9 public with a beta.3 draft visible: the draft is offered',
        () async {
      final report = await _service(
        installed: '0.7.9',
        invoker: (_) async => {
          'releases': [_row('0.7.10-beta.2'), _row('0.7.10-beta.3')],
          'drafts_visible': 2,
          'skipped': const [],
        },
      ).checkForUpdateReport();
      expect(report.update?.version, '0.7.10-beta.3');
      expect(report.isPrivateUpdate, isTrue);

      final fromBeta2 = await _service(
        installed: '0.7.10-beta.2',
        invoker: (_) async => {
          'releases': [_row('0.7.10-beta.2'), _row('0.7.10-beta.3')],
          'drafts_visible': 2,
        },
      ).checkForUpdateReport();
      expect(fromBeta2.update?.version, '0.7.10-beta.3');
    });

    test('each product asks for its own platform', () async {
      for (final platform in ['android_mobile', 'android_tv', 'windows']) {
        Object? asked;
        await _service(
          platform: platform,
          invoker: (body) async {
            asked = body['platform'];
            return {'releases': const []};
          },
        ).checkForUpdateReport();
        expect(asked, platform);
      }
    });
  });

  test('an unreachable GitHub is reported as a failed check', () async {
    final report = await _service(
      client: _publicDown(),
      signedIn: false,
      invoker: (_) async => null,
    ).checkForUpdateReport();
    expect(report.publicStatus, PublicUpdateStatus.unreachable);
    final summary = describeUpdateCheck(report);
    expect(summary.headline, 'Could not check for updates');
    expect(summary.canInstall, isFalse);
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
