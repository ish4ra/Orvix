import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const repoDownload = 'https://github.com/ish4ra/Orvix/releases/download';

/// Every asset name `prerelease.yml` publishes for a full release.
List<String> allPlatformAssets(String version) => [
      'Orvix-Setup-v$version-Windows-x64.exe',
      'Orvix-v$version-Windows-x64.zip',
      'Orvix-v$version-Android-Mobile.apk',
      'Orvix-v$version-Android-Mobile-arm64-v8a.apk',
      'Orvix-v$version-Android-Mobile-armeabi-v7a.apk',
      'Orvix-v$version-Android-Mobile-x86_64.apk',
      'Orvix-v$version-Android-TV.apk',
      'Orvix-v$version-macOS.zip',
      'Orvix-v$version-iOS-15.5-Plus.ipa',
      'Orvix-v$version-iOS-12-Legacy.ipa',
    ];

/// The Android-only release set.
List<String> androidAssets(String version) => [
      'Orvix-v$version-Android-Mobile.apk',
      'Orvix-v$version-Android-Mobile-arm64-v8a.apk',
      'Orvix-v$version-Android-Mobile-armeabi-v7a.apk',
      'Orvix-v$version-Android-Mobile-x86_64.apk',
      'Orvix-v$version-Android-TV.apk',
    ];

const digestHex =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> asset(String tag, String name, {String? state, int size = 4096}) => {
      'name': name,
      'browser_download_url': '$repoDownload/$tag/$name',
      'size': size,
      'digest': 'sha256:$digestHex',
      'state': state ?? 'uploaded',
    };

/// A GitHub release list entry. [prerelease] defaults to whether the tag
/// has a prerelease part, as `prerelease.yml` publishes it.
Map<String, Object?> release(
  String tag, {
  bool? prerelease,
  bool draft = false,
  List<String>? assets,
  String? notes,
}) {
  final version = tag.replaceFirst('v', '');
  return {
    'tag_name': tag,
    'name': 'Orvix $tag',
    'body': notes ?? 'Notes for $tag',
    'html_url': 'https://github.com/ish4ra/Orvix/releases/tag/$tag',
    'assets_url': 'https://api.github.com/repos/ish4ra/Orvix/releases/1/assets',
    'draft': draft,
    'prerelease': prerelease ?? version.contains('-'),
    'published_at': draft ? null : '2026-10-11T08:03:06Z',
    'assets': [
      for (final name in assets ?? allPlatformAssets(version)) asset(tag, name),
    ],
  };
}

/// A scripted GitHub: release list pages, the release feed and asset files.
class FakeGitHub {
  FakeGitHub(this.pages);

  /// Release list pages, page 1 first. A page can be a `List` (served with
  /// a correct `Link` header) or an [http.Response] (served as is).
  final List<Object> pages;

  /// The release feed body, or null for HTTP 404.
  String? feed;

  /// Assets endpoint answer (for empty inline asset lists).
  List<Map<String, Object?>>? assetsEndpoint;

  /// Download URL -> body bytes. Missing URLs answer 404.
  final Map<String, List<int>> files = {};

  /// Never answer the release list (timeout).
  bool hang = false;

  /// Throw a connection error for the release list.
  bool offline = false;

  bool sendLinkHeaders = true;

  final List<Uri> requests = [];

  int get apiPageRequests => requests
      .where((uri) => uri.host == 'api.github.com' && uri.path.endsWith('/releases'))
      .length;

  int get feedRequests =>
      requests.where((uri) => uri.path.endsWith('releases.atom')).length;

  http.Client client() => MockClient((request) async {
        final uri = request.url;
        requests.add(uri);
        if (uri.host == 'api.github.com' && uri.path.endsWith('/releases')) {
          if (hang) await Completer<void>().future;
          if (offline) throw http.ClientException('offline', uri);
          final page = int.parse(uri.queryParameters['page'] ?? '1');
          if (page > pages.length) return _json(const [], page, last: true);
          final content = pages[page - 1];
          if (content is http.Response) return content;
          return _json(content as List, page, last: page == pages.length);
        }
        if (uri.host == 'api.github.com' && uri.path.endsWith('/assets')) {
          return http.Response(jsonEncode(assetsEndpoint ?? const []), 200);
        }
        if (uri.path.endsWith('releases.atom')) {
          final body = feed;
          return body == null ? http.Response('', 404) : http.Response(body, 200);
        }
        if (uri.host == 'github.com' && uri.path.contains('/releases/download/')) {
          final bytes = files[uri.toString()];
          if (bytes == null) return http.Response('Not Found', 404);
          if (request.headers['Range'] == 'bytes=0-0') {
            return http.Response.bytes(bytes.take(1).toList(), 206, headers: {
              'content-range': 'bytes 0-0/${bytes.length}',
            });
          }
          return http.Response.bytes(bytes, 200);
        }
        return http.Response('unexpected ${request.url}', 599);
      });

  http.Response _json(List body, int page, {required bool last}) {
    final headers = <String, String>{'content-type': 'application/json'};
    if (sendLinkHeaders) {
      final base = 'https://api.github.com/repositories/1/releases?per_page=100';
      headers['link'] = last
          ? '<$base&page=${page - 1}>; rel="prev", <$base&page=1>; rel="first"'
          : '<$base&page=${page + 1}>; rel="next", <$base&page=${pages.length}>; rel="last"';
    }
    return http.Response(jsonEncode(body), 200, headers: headers);
  }
}

/// GitHub's unauthenticated rate-limit answer.
http.Response rateLimited({int? resetEpochSeconds}) => http.Response(
      jsonEncode({
        'message': 'API rate limit exceeded for 203.0.113.5.',
        'documentation_url': 'https://docs.github.com/rest/rate-limit',
      }),
      403,
      headers: {
        'x-ratelimit-limit': '60',
        'x-ratelimit-remaining': '0',
        'x-ratelimit-reset': '${resetEpochSeconds ?? 1791999999}',
      },
    );

String atomFeed(List<String> tags) => '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
${[
      for (final tag in tags)
        '  <entry><link rel="alternate" type="text/html" '
            'href="https://github.com/ish4ra/Orvix/releases/tag/$tag"/>'
            '<title>$tag</title></entry>',
    ].join('\n')}
</feed>''';
