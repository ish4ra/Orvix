import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/services/release_version.dart';

ReleaseVersion v(String raw) => ReleaseVersion.tryParse(raw)!;

void expectOrdered(List<String> ascending) {
  for (var i = 0; i < ascending.length; i++) {
    for (var j = 0; j < ascending.length; j++) {
      final a = ascending[i];
      final b = ascending[j];
      expect(v(a).compareTo(v(b)).sign, (i - j).sign, reason: '$a vs $b');
      expect(AppUpdateService.isVersionNewer(a, b), i > j, reason: '$a > $b');
    }
  }
}

void main() {
  test('the required beta boundaries order correctly', () {
    for (final (lower, higher) in <(String, String)>[
      ('0.7.10-beta.9', '0.7.10-beta.10'),
      ('0.7.10-beta.99', '0.7.10-beta.100'),
      ('0.7.10-beta.100', '0.7.10-beta.999'),
      ('0.7.10-beta.999', '0.7.10-beta.1000'),
      ('0.7.10-beta.1000', '0.7.10'),
      ('0.7.10', '0.7.11-beta.1'),
      ('0.7.9', '0.7.10-beta.1'),
      ('0.7.10-beta.999', '0.7.11-beta.1'),
    ]) {
      expect(v(lower) < v(higher), isTrue, reason: '$lower < $higher');
      expect(AppUpdateService.isVersionNewer('v$higher', lower), isTrue);
      expect(AppUpdateService.isVersionNewer('v$lower', higher), isFalse);
    }
  });

  test('a long chain of real and future versions sorts by precedence', () {
    expectOrdered([
      '0.7.9-beta.1',
      '0.7.9-beta.2',
      '0.7.9-beta.10',
      '0.7.9-beta.70',
      '0.7.9-beta.71',
      '0.7.9',
      '0.7.10-alpha.1',
      '0.7.10-beta.1',
      '0.7.10-beta.3',
      '0.7.10-beta.9',
      '0.7.10-beta.10',
      '0.7.10-beta.99',
      '0.7.10-beta.100',
      '0.7.10-beta.999',
      '0.7.10-beta.1000',
      '0.7.10-beta.123456789012345678901234567890',
      '0.7.10-rc.1',
      '0.7.10',
      '0.7.11-beta.1',
      '0.7.11',
      '0.8.0',
      '1.0.0',
    ]);
  });

  test('multi-digit major, minor and patch compare numerically', () {
    expectOrdered(['1.9.9', '1.10.0', '2.0.0', '9.0.0', '10.0.0', '10.0.10',
      '10.10.0', '100.0.0']);
    expect(v('0.7.10') > v('0.7.9'), isTrue, reason: 'not lexicographic');
  });

  test('multi-part prerelease identifiers follow SemVer precedence', () {
    // The ordering example from semver.org section 11.
    expectOrdered([
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ]);
    expectOrdered(['0.7.10-beta.3', '0.7.10-beta.3.1', '0.7.10-beta.3.2',
      '0.7.10-beta.4']);
  });

  test('build metadata never affects precedence', () {
    expect(v('0.7.10-beta.3+4226').samePrecedence(v('0.7.10-beta.3')), isTrue);
    expect(v('0.7.10-beta.3+4226').samePrecedence(v('0.7.10-beta.3+9999')),
        isTrue);
    expect(AppUpdateService.isVersionNewer('0.7.10-beta.3+9999',
        '0.7.10-beta.3+4226'), isFalse);
    expect(v('0.7.10-beta.3+4226').build, '4226');
    expect(v('0.7.10-beta.3+4226').toString(), '0.7.10-beta.3');
  });

  test('a leading v is optional', () {
    expect(v('v0.7.10').samePrecedence(v('0.7.10')), isTrue);
    expect(v('V0.7.10').samePrecedence(v('0.7.10')), isTrue);
    expect(v('v0.7.10-beta.3').toString(), '0.7.10-beta.3');
  });

  test('equal and older versions are never newer', () {
    expect(AppUpdateService.isVersionNewer('v0.7.10-beta.3', '0.7.10-beta.3'),
        isFalse);
    expect(AppUpdateService.isVersionNewer('v0.7.10', '0.7.10'), isFalse);
    expect(AppUpdateService.isVersionNewer('v0.7.9', '0.7.10-beta.1'),
        isFalse);
    expect(AppUpdateService.isVersionNewer('v0.7.9-beta.71', '0.7.9'),
        isFalse);
  });

  test('invalid versions are rejected and never count as newer', () {
    for (final raw in [
      '',
      'v',
      'latest',
      '0.7',
      '0.7.10.1',
      'stream-server-orvix-v0.1.8.1',
      '0.7.10-',
      '0.7.10-beta..1',
      '0.7.10-beta.1+',
      '0.7.10 beta 1',
      'v0.7.10-beta.3garbage!',
    ]) {
      expect(ReleaseVersion.tryParse(raw), isNull, reason: raw);
      expect(AppUpdateService.isVersionNewer(raw, '0.0.1'), isFalse,
          reason: raw);
      expect(AppUpdateService.isVersionNewer('99.0.0', raw), isFalse,
          reason: raw);
    }
  });

  test('old tags with leading zeros still parse and compare by value', () {
    expectOrdered(['0.7.4-alpha.01', '0.7.4-alpha.02', '0.7.4-alpha.10']);
  });

  test('stable versus prerelease', () {
    expect(v('0.7.10').isPrerelease, isFalse);
    expect(v('0.7.10-beta.1').isPrerelease, isTrue);
    expect(v('0.7.10+4226').isPrerelease, isFalse);
  });
}
