import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';

void main() {
  // The private channel is dormant (see private_update_channel.dart); its
  // contract with the Edge Function is kept intact for a deliberate return.
  final client =
      File('lib/services/private_update_channel.dart').readAsStringSync();
  final discovery =
      File('lib/services/public_release_discovery.dart').readAsStringSync();
  final api = File('supabase/functions/orvix-internal-update/index.ts')
      .readAsStringSync();
  final workflow = File('.github/workflows/prerelease.yml')
      .readAsStringSync();
  final publisher = File('tools/publish_orvix_release.sh').readAsStringSync();

  test('internal access is checked on the server, never by client flag', () {
    expect(api, contains('auth.getUser(bearer[1])'));
    expect(api, contains('.from("orvix_admins")'));
    expect(api, contains('.eq("user_id", identity.user.id)'));
    expect(api, contains('if (!adminRow)'));
    expect(api, contains('error: "forbidden"'));
    expect(api, contains('ORVIX_INTERNAL_GITHUB_TOKEN'));
    expect(client, isNot(contains('ORVIX_INTERNAL_GITHUB_TOKEN')));
    expect(client, contains('Supabase.instance.client.auth.currentSession'));
  });

  test('private metadata offers all supported platform targets', () {
    for (final platform in <String>[
      'windows',
      'android_tv',
      'android_mobile',
      'macos',
      'ios_modern',
    ]) {
      expect(api, contains('$platform:'), reason: platform);
      expect(client, contains("'$platform'"), reason: platform);
    }
    expect(api, contains('ios_legacy:'));
    expect(api, contains('r.draft === true'));
    expect(api, contains('action === "check"'));
    expect(api, contains('action !== "check" && action !== "download"'));
  });

  test('private download requires matching checksum and HTTPS URL', () {
    expect(client, contains("assetDigest: 'sha256:\$digest'"));
    expect(client, contains("update.assetDigest?.replaceFirst('sha256:', '')"));
    expect(client, contains("uri.scheme != 'https'"));
    expect(client, contains('Future<String> signedDownloadUrl(AppUpdateInfo update)'));
    expect(File('lib/services/app_update_service.dart').readAsStringSync(),
        contains('final actual = await sha256.bind(file.openRead()).first'));
    expect(api, contains('Accept: "application/octet-stream"'));
  });

  test('ordinary updates are still available and private drafts stay private', () {
    expect(discovery, contains('_discoverFromFeed('));
    expect(discovery, contains(r"'https://api.github.com/repos/$repository/releases'"));
    expect(discovery, contains("if (raw['draft'] != false) return null;"));
    expect(workflow, contains('distribution:'));
    expect(workflow, contains('default: internal'));
    expect(workflow, contains("inputs.distribution != 'public'"));
    expect(publisher, contains('ORVIX_RELEASE_DRAFT_ONLY'));
    expect(publisher, contains('private draft'));
  });

  test('old releases remain valid rollback references', () {
    expect(AppUpdateService.isVersionNewer('v0.7.9-beta.71', '0.7.9-beta.70'), isTrue);
    expect(AppUpdateService.isVersionNewer('v0.7.9-beta.63', '0.7.9-beta.70'), isFalse);
  });
}
