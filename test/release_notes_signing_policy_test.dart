import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// SignPath Foundation expects the code signing policy and privacy policy to be
// reachable from the download page. Until a signed release exists, every
// published release must also say plainly that its Windows files are unsigned.
void main() {
  final prerelease = File('.github/workflows/prerelease.yml').readAsStringSync();
  final policy = File('CODE_SIGNING_POLICY.md').readAsStringSync();

  String releaseJob() {
    final start = prerelease.indexOf('\n  release:\n');
    expect(start, isNot(-1), reason: 'release job is missing');
    return prerelease.substring(start);
  }

  test('release notes link the code signing and privacy policies', () {
    final release = releaseJob();
    expect(
      release,
      contains(r'[Code signing policy](https://github.com/$GITHUB_REPOSITORY/blob/v$V/CODE_SIGNING_POLICY.md)'),
    );
    expect(
      release,
      contains(r'[Privacy policy](https://github.com/$GITHUB_REPOSITORY/blob/v$V/PRIVACY.md)'),
    );
    expect(File('CODE_SIGNING_POLICY.md').existsSync(), isTrue);
    expect(File('PRIVACY.md').existsSync(), isTrue);
  });

  test('unsigned Windows releases are described as unsigned', () {
    expect(releaseJob(), contains('**not code signed**'));
    expect(policy, contains('**Orvix Windows releases are currently unsigned.**'));
    expect(
      policy,
      contains('Free code signing provided by [SignPath.io](https://signpath.io), '
          'certificate by [SignPath Foundation](https://signpath.org)'),
    );
  });
}
