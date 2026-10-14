import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orvix/services/public_release_discovery.dart';
import 'package:orvix/services/release_version.dart';

import 'support/fake_github.dart';

const tv = UpdatePlatform(UpdateTarget.androidTv);
const phoneArm64 = UpdatePlatform(UpdateTarget.androidMobile,
    androidAbis: ['arm64-v8a', 'armeabi-v7a', 'armeabi']);
const windows = UpdatePlatform(UpdateTarget.windows);

Future<DiscoveryResult> discover(
  FakeGitHub github, {
  String installed = '0.7.10-beta.3',
  UpdatePlatform platform = tv,
  UpdateChannel channel = UpdateChannel.stableAndPrerelease,
  bool feed = false,
  Duration timeout = const Duration(seconds: 12),
}) {
  final client = github.client();
  return PublicReleaseDiscovery(client: () => client, requestTimeout: timeout)
      .discover(
    installed: ReleaseVersion.tryParse(installed)!,
    platform: platform,
    channel: channel,
    allowFeedFallback: feed,
  );
}

const manual = UpdateChannel.stableAndPrerelease;
const automatic = UpdateChannel.stable;

void main() {
  group('eligibility', () {
    test('one public stable release is offered on both channels', () async {
      final github = FakeGitHub([
        [release('v0.7.10')]
      ]);
      for (final channel in UpdateChannel.values) {
        final result = await discover(github, channel: channel);
        expect(result.status, DiscoveryStatus.available);
        expect(result.release!.tag, 'v0.7.10');
        expect(result.release!.isPrerelease, isFalse);
        expect(result.asset!.name, 'Orvix-v0.7.10-Android-TV.apk');
      }
    });

    test('one public beta is offered manually, never automatically', () async {
      final github = FakeGitHub([
        [release('v0.7.10-beta.4')]
      ]);
      final manualResult = await discover(github, channel: manual);
      expect(manualResult.status, DiscoveryStatus.available);
      expect(manualResult.release!.isPrerelease, isTrue);
      final auto = await discover(github, channel: automatic);
      expect(auto.status, DiscoveryStatus.upToDate);
      expect(auto.release, isNull);
    });

    test('beta.999 is discovered manually and never automatically', () async {
      final github = FakeGitHub([
        [release('v0.7.10-beta.999'), release('v0.7.10-beta.4')]
      ]);
      final result = await discover(github, channel: manual);
      expect(result.release!.tag, 'v0.7.10-beta.999');
      expect((await discover(github, channel: automatic)).release, isNull);
    });

    test('the highest of several betas wins, not the first listed', () async {
      final github = FakeGitHub([
        [
          release('v0.7.10-beta.9'),
          release('v0.7.10-beta.100'),
          release('v0.7.10-beta.10'),
          release('v0.7.10-beta.99'),
        ]
      ]);
      expect((await discover(github)).release!.tag, 'v0.7.10-beta.100');
    });

    for (final (installed, newer) in <(String, String)>[
      ('0.7.10-beta.9', 'v0.7.10-beta.10'),
      ('0.7.10-beta.99', 'v0.7.10-beta.100'),
      ('0.7.10-beta.100', 'v0.7.10-beta.999'),
      ('0.7.10-beta.999', 'v0.7.10-beta.1000'),
    ]) {
      test('manual check finds $newer over installed $installed', () async {
        final github = FakeGitHub([
          [release(newer), release('v$installed'), release('v0.7.9')]
        ]);
        final result = await discover(github, installed: installed);
        expect(result.status, DiscoveryStatus.available);
        expect(result.release!.tag, newer);
      });
    }

    test('a stable release is chosen when it is semantically newest', () async {
      final github = FakeGitHub([
        [
          release('v0.7.10-beta.1000'),
          release('v0.7.10'),
          release('v0.7.10-beta.999'),
        ]
      ]);
      final result = await discover(github);
      expect(result.release!.tag, 'v0.7.10');
      expect(result.release!.isPrerelease, isFalse);
    });

    test('automatic check picks the newest stable even when a newer beta '
        'exists', () async {
      final github = FakeGitHub([
        [release('v0.7.11-beta.2'), release('v0.7.10'), release('v0.7.9')]
      ]);
      final auto = await discover(github, installed: '0.7.9',
          channel: automatic);
      expect(auto.release!.tag, 'v0.7.10');
      final man = await discover(github, installed: '0.7.9');
      expect(man.release!.tag, 'v0.7.11-beta.2');
    });

    test('older and equal releases are never offered', () async {
      final github = FakeGitHub([
        [release('v0.7.10-beta.3'), release('v0.7.10-beta.2'), release('v0.7.9')]
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.upToDate);
      final stable = FakeGitHub([
        [release('v0.7.10')]
      ]);
      expect((await discover(stable, installed: '0.7.10', channel: automatic))
          .status, DiscoveryStatus.upToDate);
      expect((await discover(stable, installed: '0.7.11', channel: automatic))
          .status, DiscoveryStatus.upToDate);
    });

    test('a stable tag GitHub marks as prerelease is a beta', () async {
      final github = FakeGitHub([
        [release('v0.7.11', prerelease: true)]
      ]);
      expect((await discover(github, channel: automatic)).release, isNull);
      final man = await discover(github);
      expect(man.release!.isPrerelease, isTrue);
    });

    test('a beta tag GitHub forgot to mark is still a beta', () async {
      final github = FakeGitHub([
        [release('v0.7.10-beta.4', prerelease: false)]
      ]);
      expect((await discover(github, channel: automatic)).release, isNull);
    });

    test('a release title without "beta" does not make it stable', () async {
      final entry = release('v0.7.10-beta.4')..['name'] = 'Orvix big update';
      final github = FakeGitHub([
        [entry]
      ]);
      expect((await discover(github, channel: automatic)).release, isNull);
    });
  });

  group('drafts', () {
    test('drafts mixed with public releases are never offered', () async {
      final github = FakeGitHub([
        [
          release('v0.7.10-beta.5', draft: true),
          release('v0.7.11', draft: true),
          release('v0.7.10-beta.4'),
        ]
      ]);
      final result = await discover(github);
      expect(result.release!.tag, 'v0.7.10-beta.4');
      final auto = await discover(github, channel: automatic);
      expect(auto.status, DiscoveryStatus.upToDate);
    });

    test('an entry without an explicit draft flag or publish date is ignored',
        () async {
      final noFlag = release('v0.7.12')..remove('draft');
      final noDate = release('v0.7.13')..['published_at'] = null;
      final github = FakeGitHub([
        [noFlag, noDate]
      ]);
      expect((await discover(github)).status, DiscoveryStatus.upToDate);
    });
  });

  group('ordering and pagination', () {
    test('the newest version is found even when published earlier', () async {
      final github = FakeGitHub([
        [
          release('v0.7.10-beta.5'),
          release('v0.7.10-beta.4'),
          release('v0.7.11'),
          release('v0.7.10-beta.6'),
        ]
      ]);
      expect((await discover(github)).release!.tag, 'v0.7.11');
    });

    test('a newer release on page 2 behind 100 older betas is found',
        () async {
      final page1 = [
        for (var i = 100; i >= 1; i--) release('v0.7.9-beta.$i'),
      ];
      final github = FakeGitHub([
        page1,
        [release('v0.7.10'), release('v0.7.8')],
      ]);
      final result = await discover(github, installed: '0.7.9',
          channel: automatic);
      expect(result.status, DiscoveryStatus.available);
      expect(result.release!.tag, 'v0.7.10');
      expect(github.apiPageRequests, 2);
      expect(result.pagesFetched, 2);
      expect(result.releasesInspected, 102);
    });

    test('pagination stops at the last page (Link header)', () async {
      final github = FakeGitHub([
        [for (var i = 0; i < 100; i++) release('v0.6.$i')],
        [release('v0.5.0')],
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.upToDate);
      expect(github.apiPageRequests, 2);
    });

    test('without Link headers a short page ends the list', () async {
      final github = FakeGitHub([
        [release('v0.7.9')]
      ])..sendLinkHeaders = false;
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.upToDate);
      expect(github.apiPageRequests, 1);
    });

    test('without Link headers a full page asks for the next one', () async {
      final github = FakeGitHub([
        [for (var i = 0; i < 100; i++) release('v0.6.$i')],
        [release('v0.7.11')],
      ])..sendLinkHeaders = false;
      expect((await discover(github)).release!.tag, 'v0.7.11');
      expect(github.apiPageRequests, 2);
    });

    test('the page bound is respected and an exhausted bound is not '
        '"up to date"', () async {
      final github = FakeGitHub([
        for (var p = 0; p < 7; p++)
          [for (var i = 0; i < 100; i++) release('v0.$p.$i')],
      ]);
      final result = await discover(github);
      expect(github.apiPageRequests, PublicReleaseDiscovery.maxPages);
      expect(result.status, DiscoveryStatus.incomplete);
      expect(result.failed, isTrue);
    });

    test('a failed second page is reported, not called "up to date"',
        () async {
      final github = FakeGitHub([
        [for (var i = 0; i < 100; i++) release('v0.6.$i')],
        http.Response('boom', 502),
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.serverError);
      expect(result.httpStatus, 502);
    });

    test('an update already found on page 1 survives a failed page 2',
        () async {
      final github = FakeGitHub([
        [
          release('v0.7.11'),
          for (var i = 0; i < 99; i++) release('v0.6.$i'),
        ],
        rateLimited(),
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.available);
      expect(result.release!.tag, 'v0.7.11');
    });

    test('an empty list means up to date', () async {
      final result = await discover(FakeGitHub([const []]));
      expect(result.status, DiscoveryStatus.upToDate);
      expect(result.failed, isFalse);
    });
  });

  group('assets', () {
    test('a newer release without this platform falls back to the newest one '
        'that has it', () async {
      final github = FakeGitHub([
        [
          release('v0.7.10-beta.6', assets: androidAssets('0.7.10-beta.6')),
          release('v0.7.10-beta.5'),
        ]
      ]);
      final result = await discover(github, platform: windows);
      expect(result.status, DiscoveryStatus.available);
      expect(result.release!.tag, 'v0.7.10-beta.5');
      expect(result.newestWithoutAsset!.tag, 'v0.7.10-beta.6');
      // Android-only releases cost no extra asset lookups.
      expect(github.requests.where((u) => u.path.endsWith('/assets')), isEmpty);
    });

    test('no compatible asset anywhere is explained, not "up to date"',
        () async {
      final github = FakeGitHub([
        [release('v0.7.10-beta.6', assets: androidAssets('0.7.10-beta.6'))]
      ]);
      final result = await discover(github, platform: windows);
      expect(result.status, DiscoveryStatus.noCompatibleAsset);
      expect(result.newestWithoutAsset!.tag, 'v0.7.10-beta.6');
      expect(result.failed, isFalse);
    });

    test('an empty inline asset list is completed from the asset endpoint',
        () async {
      final github = FakeGitHub([
        [release('v0.7.11', assets: const [])]
      ])..assetsEndpoint = [
          for (final name in allPlatformAssets('0.7.11')) asset('v0.7.11', name),
        ];
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.available);
      expect(result.asset!.name, 'Orvix-v0.7.11-Android-TV.apk');
    });

    test('asset endpoint lookups are bounded', () async {
      final github = FakeGitHub([
        [
          for (var i = 1; i <= 6; i++)
            release('v0.7.10-beta.${10 + i}', assets: const []),
        ]
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.noCompatibleAsset);
      expect(github.requests.where((u) => u.path.endsWith('/assets')).length,
          PublicReleaseDiscovery.maxAssetLookups);
    });

    test('uploading, empty or foreign-hosted assets are ignored', () async {
      final entry = release('v0.7.11', assets: const []);
      entry['assets'] = [
        asset('v0.7.11', 'Orvix-v0.7.11-Android-TV.apk', state: 'open'),
      ];
      final empty = release('v0.7.12', assets: const []);
      empty['assets'] = [
        asset('v0.7.12', 'Orvix-v0.7.12-Android-TV.apk', size: 0),
      ];
      final foreign = release('v0.7.13', assets: const []);
      foreign['assets'] = [
        {
          ...asset('v0.7.13', 'Orvix-v0.7.13-Android-TV.apk'),
          'browser_download_url':
              'https://example.com/Orvix-v0.7.13-Android-TV.apk',
        },
      ];
      final github = FakeGitHub([
        [entry, empty, foreign]
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.noCompatibleAsset);
    });

    test('malformed entries are skipped without hiding valid ones', () async {
      final github = FakeGitHub([
        [
          'not a release',
          42,
          {'tag_name': 'v9.9.9'},
          release('stream-server-orvix-v0.1.8.3'),
          release('v0.7.12')..['prerelease'] = 'yes',
          release('v0.7.11')..['assets'] = 'broken',
          release('v0.7.10'),
        ]
      ]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.available);
      expect(result.release!.tag, 'v0.7.10');
      expect(result.newestWithoutAsset!.tag, 'v0.7.11');
    });
  });

  group('failures', () {
    test('a rate limit is reported with its reset time', () async {
      final github = FakeGitHub([rateLimited(resetEpochSeconds: 1792000000)]);
      final result = await discover(github);
      expect(result.status, DiscoveryStatus.rateLimited);
      expect(result.rateLimitResetAt,
          DateTime.fromMillisecondsSinceEpoch(1792000000 * 1000, isUtc: true));
      expect(result.failed, isTrue);
    });

    test('HTTP 429 is a rate limit too', () async {
      final github = FakeGitHub([http.Response('slow down', 429)]);
      expect((await discover(github)).status, DiscoveryStatus.rateLimited);
    });

    test('a timeout is reported as a timeout', () async {
      final github = FakeGitHub([const []])..hang = true;
      final result = await discover(github,
          timeout: const Duration(milliseconds: 50));
      expect(result.status, DiscoveryStatus.timeout);
    });

    test('a connection error is reported as a network failure', () async {
      final github = FakeGitHub([const []])..offline = true;
      expect((await discover(github)).status, DiscoveryStatus.network);
    });

    test('a server error is reported with its status', () async {
      final result = await discover(FakeGitHub([http.Response('x', 503)]));
      expect(result.status, DiscoveryStatus.serverError);
      expect(result.httpStatus, 503);
    });

    test('an unauthorized answer is reported as refused', () async {
      for (final code in [401, 403]) {
        final result =
            await discover(FakeGitHub([http.Response('{"message":"no"}', code)]));
        expect(result.status, DiscoveryStatus.refused, reason: '$code');
      }
    });

    test('invalid JSON and a non-list body are invalid responses', () async {
      for (final body in ['<html>', '{"message":"x"}']) {
        final result = await discover(FakeGitHub([http.Response(body, 200)]));
        expect(result.status, DiscoveryStatus.invalidResponse, reason: body);
      }
    });
  });

  group('release feed fallback (manual checks only)', () {
    test('a rate-limited manual check finds a newer release through the feed '
        'after confirming its installer exists', () async {
      final github = FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.10-beta.5', 'v0.7.10-beta.4', 'v0.7.9'])
        ..files['$repoDownload/v0.7.10-beta.5/Orvix-v0.7.10-beta.5-Android-TV.apk'] =
            List.filled(2048, 1);
      final result = await discover(github, feed: true);
      expect(result.status, DiscoveryStatus.available);
      expect(result.viaReleaseFeed, isTrue);
      expect(result.release!.tag, 'v0.7.10-beta.5');
      expect(result.release!.isPrerelease, isTrue);
      expect(result.asset!.size, 2048);
      expect(result.asset!.digest, isNull);
    });

    test('the feed never fabricates a missing installer', () async {
      final github = FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.10-beta.5']);
      final result = await discover(github, feed: true);
      expect(result.status, DiscoveryStatus.noCompatibleAsset);
      expect(result.release, isNull);
    });

    test('a feed without newer releases leaves the rate limit reported',
        () async {
      final github = FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.10-beta.3', 'v0.7.9']);
      final result = await discover(github, feed: true);
      expect(result.status, DiscoveryStatus.rateLimited);
      expect(result.failed, isTrue);
    });

    test('automatic checks never use the feed', () async {
      final github = FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.11'])
        ..files['$repoDownload/v0.7.11/Orvix-v0.7.11-Android-TV.apk'] = [1, 2];
      final result = await discover(github, channel: automatic, feed: false);
      expect(result.status, DiscoveryStatus.rateLimited);
      expect(github.feedRequests, 0);
    });

    test('the phone feed probe prefers the device ABI, then universal',
        () async {
      final github = FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.11'])
        ..files['$repoDownload/v0.7.11/Orvix-v0.7.11-Android-Mobile.apk'] =
            [1, 2, 3];
      final result = await discover(github, platform: phoneArm64, feed: true);
      expect(result.asset!.name, 'Orvix-v0.7.11-Android-Mobile.apk');
    });
  });

  group('platform asset selection', () {
    PublicRelease full(String tag, [List<String>? names]) =>
        PublicRelease.fromGitHub(release(tag, assets: names))!;

    test('Android TV gets the TV APK, never a phone APK', () {
      expect(selectAsset(full('v0.7.11'), tv)!.name,
          'Orvix-v0.7.11-Android-TV.apk');
      final phoneOnly = full('v0.7.11', [
        'Orvix-v0.7.11-Android-Mobile.apk',
        'Orvix-v0.7.11-Android-Mobile-arm64-v8a.apk',
      ]);
      expect(selectAsset(phoneOnly, tv), isNull);
    });

    test('phones get their ABI APK', () {
      final r = full('v0.7.11');
      expect(selectAsset(r, phoneArm64)!.name,
          'Orvix-v0.7.11-Android-Mobile-arm64-v8a.apk');
      expect(
          selectAsset(
                  r,
                  const UpdatePlatform(UpdateTarget.androidMobile,
                      androidAbis: ['armeabi-v7a', 'armeabi']))!
              .name,
          'Orvix-v0.7.11-Android-Mobile-armeabi-v7a.apk');
      expect(
          selectAsset(
                  r,
                  const UpdatePlatform(UpdateTarget.androidMobile,
                      androidAbis: ['x86_64', 'x86', 'arm64-v8a']))!
              .name,
          'Orvix-v0.7.11-Android-Mobile-x86_64.apk');
    });

    test('phones fall back to the universal APK, never another ABI', () {
      final noSplits = full('v0.7.11', [
        'Orvix-v0.7.11-Android-Mobile.apk',
        'Orvix-v0.7.11-Android-TV.apk',
      ]);
      expect(selectAsset(noSplits, phoneArm64)!.name,
          'Orvix-v0.7.11-Android-Mobile.apk');
      for (final abis in [
        const <String>[],
        const ['riscv64'],
        const ['x86'],
      ]) {
        expect(
            selectAsset(full('v0.7.11'),
                    UpdatePlatform(UpdateTarget.androidMobile, androidAbis: abis))!
                .name,
            'Orvix-v0.7.11-Android-Mobile.apk',
            reason: '$abis');
      }
      final wrongAbiOnly = full('v0.7.11', [
        'Orvix-v0.7.11-Android-Mobile-x86_64.apk',
      ]);
      expect(selectAsset(wrongAbiOnly, phoneArm64), isNull);
    });

    test('Windows gets the installer, not the portable ZIP', () {
      expect(selectAsset(full('v0.7.11'), windows)!.name,
          'Orvix-Setup-v0.7.11-Windows-x64.exe');
      expect(
          selectAsset(full('v0.7.11', ['Orvix-v0.7.11-Windows-x64.zip']),
              windows),
          isNull);
    });

    test('macOS gets its ZIP and iOS its IPA', () {
      expect(
          selectAsset(full('v0.7.11'), const UpdatePlatform(UpdateTarget.macos))!
              .name,
          'Orvix-v0.7.11-macOS.zip');
      expect(
          selectAsset(full('v0.7.11'), const UpdatePlatform(UpdateTarget.ios))!
              .name,
          'Orvix-v0.7.11-iOS-15.5-Plus.ipa');
    });

    test('incorrectly named assets are never offered', () {
      final wrong = full('v0.7.11', [
        'Orvix-v0.7.10-Android-TV.apk', // another version
        'orvix-v0.7.11-android-tv.apk', // wrong case
        'Orvix-v0.7.11-Android-TV.apk.sha256',
        'Orvix-v0.7.11-Android-TV-debug.apk',
        'Orvix-Setup-v0.7.10-Windows-x64.exe',
        'Orvix-v0.7.11-macOS.dmg',
      ]);
      for (final platform in [
        tv,
        phoneArm64,
        windows,
        const UpdatePlatform(UpdateTarget.macos),
        const UpdatePlatform(UpdateTarget.ios),
      ]) {
        expect(selectAsset(wrong, platform), isNull, reason: '$platform');
      }
    });

    test('a mixed-platform release gives each product its own file', () {
      final r = full('v0.7.11');
      final names = {
        for (final p in [
          tv,
          phoneArm64,
          windows,
          const UpdatePlatform(UpdateTarget.macos),
          const UpdatePlatform(UpdateTarget.ios),
        ])
          selectAsset(r, p)!.name,
      };
      expect(names, hasLength(5));
    });
  });
}
