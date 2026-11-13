import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'release_version.dart';

/// The Orvix product an update is for. Each has its own release asset.
enum UpdateTarget { androidMobile, androidTv, windows, macos, ios }

/// Which public releases an update check may offer.
enum UpdateChannel {
  /// Automatic checks: public stable releases only.
  stable,

  /// Manual checks: public stable releases and public prereleases (betas).
  stableAndPrerelease,
}

/// The device an update check runs for.
class UpdatePlatform {
  const UpdatePlatform(this.target, {this.androidAbis = const []});

  final UpdateTarget target;

  /// Android only: the ABIs the device supports, most preferred first
  /// (`Build.SUPPORTED_ABIS`). Empty when unknown; then only the universal
  /// phone APK is offered.
  final List<String> androidAbis;

  /// iOS cannot install an app update from inside the app.
  bool get installsInApp => target != UpdateTarget.ios;
}

/// One downloadable file of a release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    this.size,
    this.digest,
  });

  final String name;
  final String url;
  final int? size;

  /// `sha256:<hex>` when GitHub published one.
  final String? digest;
}

/// A published (non-draft) GitHub release with a valid version tag.
class PublicRelease {
  const PublicRelease({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    required this.githubPrerelease,
    required this.assets,
    this.assetsUrl,
  });

  final String tag;
  final ReleaseVersion version;
  final String title;
  final String notes;
  final String htmlUrl;

  /// GitHub's own prerelease flag.
  final bool githubPrerelease;
  final List<ReleaseAsset> assets;
  final String? assetsUrl;

  /// A beta: GitHub marks it as a prerelease, or its version has a
  /// prerelease part. Either is enough; a release is stable only when
  /// GitHub says so and its version agrees.
  bool get isPrerelease => githubPrerelease || version.isPrerelease;

  /// Parses one entry of GitHub's release list. Returns null for a draft,
  /// an unpublished or malformed entry, or a tag that is not a version.
  static PublicRelease? fromGitHub(Object? raw) {
    if (raw is! Map) return null;
    // Unauthenticated clients never receive drafts, but never trust that:
    // only an explicit `draft: false` with a publication date is public.
    if (raw['draft'] != false) return null;
    final prerelease = raw['prerelease'];
    if (prerelease is! bool) return null;
    final published = raw['published_at'];
    if (published is! String || published.isEmpty) return null;
    final tag = raw['tag_name'];
    if (tag is! String) return null;
    final version = ReleaseVersion.tryParse(tag);
    if (version == null) return null;
    final name = raw['name'];
    final body = raw['body'];
    final html = raw['html_url'];
    final assetsUrl = raw['assets_url'];
    return PublicRelease(
      tag: tag.trim(),
      version: version,
      title: name is String && name.trim().isNotEmpty ? name.trim() : tag.trim(),
      notes: body is String ? body : '',
      htmlUrl: html is String ? html : '',
      githubPrerelease: prerelease,
      assets: parseAssets(raw['assets']),
      assetsUrl: assetsUrl is String ? assetsUrl : null,
    );
  }

  /// Uploaded, non-empty assets with an HTTPS GitHub download URL.
  static List<ReleaseAsset> parseAssets(Object? raw) {
    if (raw is! List) return const [];
    final assets = <ReleaseAsset>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'];
      final url = item['browser_download_url'];
      if (name is! String || name.isEmpty || url is! String) continue;
      // An asset that is still uploading has state "open".
      final state = item['state'];
      if (state != null && state != 'uploaded') continue;
      final size = item['size'];
      if (size is num && size <= 0) continue;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          !uri.path.contains('/releases/download/') ||
          !uri.path.endsWith('/$name')) {
        continue;
      }
      final digest = item['digest'];
      assets.add(ReleaseAsset(
        name: name,
        url: url,
        size: size is num ? size.toInt() : null,
        digest: digest is String && digest.startsWith('sha256:') ? digest : null,
      ));
    }
    return assets;
  }
}

/// The asset names Orvix publishes for [target], most preferred first.
///
/// [version] is the tag without its leading `v`. These are the exact names
/// `prerelease.yml` uploads; anything else (another platform, another
/// version, a renamed file) is never offered.
List<String> expectedAssetNames(
  UpdateTarget target,
  String version, {
  List<String> androidAbis = const [],
}) {
  switch (target) {
    case UpdateTarget.androidTv:
      return ['Orvix-v$version-Android-TV.apk'];
    case UpdateTarget.androidMobile:
      // Every phone APK of one release shares package, versionCode and
      // signer (tools/verify_android_apk.py), so any of them can replace the
      // installed one. Prefer the smaller APK for the device's own ABI.
      return [
        for (final abi in androidAbis)
          if (publishedAndroidAbis.contains(abi))
            'Orvix-v$version-Android-Mobile-$abi.apk',
        'Orvix-v$version-Android-Mobile.apk',
      ];
    case UpdateTarget.windows:
      return ['Orvix-Setup-v$version-Windows-x64.exe'];
    case UpdateTarget.macos:
      return ['Orvix-v$version-macOS.zip'];
    case UpdateTarget.ios:
      return [
        'Orvix-v$version-iOS-15.5-Plus.ipa',
        'Orvix-v$version-iOS-12-Legacy.ipa',
        'Orvix-v$version-iOS.ipa',
      ];
  }
}

/// The ABI-specific phone APKs `prerelease.yml` publishes.
const publishedAndroidAbis = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];

/// The best asset of [release] for [platform], or null.
ReleaseAsset? selectAsset(PublicRelease release, UpdatePlatform platform) {
  final version = release.tag.replaceFirst(RegExp('^[vV]'), '');
  for (final name in expectedAssetNames(
    platform.target,
    version,
    androidAbis: platform.androidAbis,
  )) {
    for (final asset in release.assets) {
      if (asset.name == name) return asset;
    }
  }
  return null;
}

/// Whether [release] may be offered on [channel] to [installed].
bool isEligible(
  PublicRelease release,
  ReleaseVersion installed,
  UpdateChannel channel,
) {
  if (!(release.version > installed)) return false;
  return channel == UpdateChannel.stableAndPrerelease || !release.isPrerelease;
}

enum DiscoveryStatus {
  /// A newer eligible release with an installer for this device.
  available,

  /// Every public release was inspected; none is newer and eligible.
  upToDate,

  /// A newer eligible release exists, but none has an installer for this
  /// device.
  noCompatibleAsset,

  /// GitHub's API rate limit was reached.
  rateLimited,

  /// GitHub did not answer in time.
  timeout,

  /// GitHub could not be reached.
  network,

  /// GitHub answered with a server error (5xx).
  serverError,

  /// GitHub refused the request (401, or 403 without a rate limit).
  refused,

  /// Any other unexpected HTTP status.
  httpError,

  /// GitHub's answer could not be read.
  invalidResponse,

  /// The discovery bound was reached before every release was inspected.
  incomplete,
}

/// The outcome of one public release discovery.
class DiscoveryResult {
  const DiscoveryResult(
    this.status, {
    this.release,
    this.asset,
    this.newestWithoutAsset,
    this.httpStatus,
    this.rateLimitResetAt,
    this.releasesInspected = 0,
    this.pagesFetched = 0,
    this.viaReleaseFeed = false,
  });

  final DiscoveryStatus status;
  final PublicRelease? release;
  final ReleaseAsset? asset;

  /// A newer eligible release that has no installer for this device.
  final PublicRelease? newestWithoutAsset;
  final int? httpStatus;
  final DateTime? rateLimitResetAt;
  final int releasesInspected;
  final int pagesFetched;

  /// Found through the public release feed because the API failed. Such a
  /// result has no GitHub checksum and no prerelease flag of its own.
  final bool viaReleaseFeed;

  bool get failed => switch (status) {
        DiscoveryStatus.available ||
        DiscoveryStatus.upToDate ||
        DiscoveryStatus.noCompatibleAsset =>
          false,
        _ => true,
      };
}

/// Finds the newest eligible public Orvix release on GitHub.
///
/// GitHub's release list is not ordered by version: drafts come first and
/// the rest roughly follows creation time, which differs from version order
/// whenever a release is created early and published later. So every page
/// is read, up to [maxPages] pages of [perPage] releases (500 releases, more
/// than twice what Orvix has published), before deciding. Orvix had about
/// 190 public releases in October 2026, so a check costs two requests of the
/// 60 per hour GitHub allows an unauthenticated network.
class PublicReleaseDiscovery {
  PublicReleaseDiscovery({
    required http.Client Function() client,
    this.repository = 'ish4ra/Orvix',
    this.requestTimeout = const Duration(seconds: 12),
  }) : _client = client;

  final http.Client Function() _client;
  final String repository;
  final Duration requestTimeout;

  static const perPage = 100;
  static const maxPages = 5;

  /// Releases whose list entry has no assets get one look at their asset
  /// endpoint; this caps how many such lookups one check may make.
  static const maxAssetLookups = 2;

  /// At most this many feed candidates are probed for an installer.
  static const maxFeedProbes = 3;

  static const _apiHeaders = <String, String>{
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Orvix-Updater',
    'X-GitHub-Api-Version': '2022-11-28',
    'Cache-Control': 'no-cache, no-store, max-age=0',
    'Pragma': 'no-cache',
  };

  Uri _pageUri(int page) =>
      Uri.parse('https://api.github.com/repos/$repository/releases').replace(
        queryParameters: <String, String>{
          'per_page': '$perPage',
          'page': '$page',
          // Keep an intermediary/CDN from replaying a list cached just
          // before a release was published.
          '_orvix_check': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );

  Future<DiscoveryResult> discover({
    required ReleaseVersion installed,
    required UpdatePlatform platform,
    required UpdateChannel channel,
    bool allowFeedFallback = false,
  }) async {
    final releases = <PublicRelease>[];
    var pages = 0;
    var complete = false;
    _HttpFailure? failure;

    for (var page = 1; page <= maxPages; page++) {
      final fetched = await _getJson(_pageUri(page));
      if (fetched.failure != null) {
        failure = fetched.failure;
        break;
      }
      final body = fetched.json;
      if (body is! List) {
        failure = const _HttpFailure(DiscoveryStatus.invalidResponse);
        break;
      }
      pages++;
      for (final raw in body) {
        final release = PublicRelease.fromGitHub(raw);
        if (release != null) releases.add(release);
      }
      final next = fetched.hasNextPage ?? body.length >= perPage;
      if (!next || body.isEmpty) {
        complete = true;
        break;
      }
    }

    if (pages == 0) {
      final apiFailure = failure!;
      if (allowFeedFallback && apiFailure.feedMayHelp) {
        final viaFeed = await _discoverFromFeed(
          installed: installed,
          platform: platform,
          channel: channel,
        );
        if (viaFeed != null) return viaFeed;
      }
      return apiFailure.toResult();
    }

    final candidates = releases
        .where((release) => isEligible(release, installed, channel))
        .toList()
      ..sort((a, b) => b.version.compareTo(a.version));

    PublicRelease? newestWithoutAsset;
    var lookups = 0;
    for (final candidate in candidates) {
      var release = candidate;
      if (release.assets.isEmpty &&
          release.assetsUrl != null &&
          lookups < maxAssetLookups) {
        // The list entry can briefly miss assets right after publication.
        lookups++;
        release = await _withFetchedAssets(release);
      }
      final asset = selectAsset(release, platform);
      if (asset != null) {
        return DiscoveryResult(
          DiscoveryStatus.available,
          release: release,
          asset: asset,
          newestWithoutAsset: newestWithoutAsset,
          releasesInspected: releases.length,
          pagesFetched: pages,
        );
      }
      newestWithoutAsset ??= release;
    }

    // A failed later page or an exhausted bound means a newer release may
    // be unseen: never call that "up to date".
    if (failure != null) {
      return failure.toResult(
        releasesInspected: releases.length,
        pagesFetched: pages,
        newestWithoutAsset: newestWithoutAsset,
      );
    }
    if (!complete) {
      return DiscoveryResult(
        DiscoveryStatus.incomplete,
        newestWithoutAsset: newestWithoutAsset,
        releasesInspected: releases.length,
        pagesFetched: pages,
      );
    }
    return DiscoveryResult(
      newestWithoutAsset == null
          ? DiscoveryStatus.upToDate
          : DiscoveryStatus.noCompatibleAsset,
      newestWithoutAsset: newestWithoutAsset,
      releasesInspected: releases.length,
      pagesFetched: pages,
    );
  }

  Future<PublicRelease> _withFetchedAssets(PublicRelease release) async {
    final url = Uri.tryParse(release.assetsUrl ?? '');
    if (url == null || url.scheme != 'https' || url.host != 'api.github.com') {
      return release;
    }
    final fetched = await _getJson(url.replace(queryParameters: {
      ...url.queryParameters,
      'per_page': '100',
    }));
    if (fetched.failure != null) return release;
    return PublicRelease(
      tag: release.tag,
      version: release.version,
      title: release.title,
      notes: release.notes,
      htmlUrl: release.htmlUrl,
      githubPrerelease: release.githubPrerelease,
      assets: PublicRelease.parseAssets(fetched.json),
      assetsUrl: release.assetsUrl,
    );
  }

  Future<_JsonPage> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response =
          await _client().get(uri, headers: _apiHeaders).timeout(requestTimeout);
    } on TimeoutException {
      return const _JsonPage.failed(_HttpFailure(DiscoveryStatus.timeout));
    } catch (_) {
      // SocketException, HandshakeException, ClientException and the like.
      return const _JsonPage.failed(_HttpFailure(DiscoveryStatus.network));
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      return _JsonPage.failed(_HttpFailure.fromResponse(response));
    }
    try {
      return _JsonPage(
        jsonDecode(response.body),
        hasNextPage: _hasNextLink(response.headers['link']),
      );
    } on FormatException {
      return const _JsonPage.failed(
          _HttpFailure(DiscoveryStatus.invalidResponse));
    }
  }

  /// True/false from GitHub's `Link` header, or null when it is absent.
  static bool? _hasNextLink(String? link) {
    if (link == null || link.trim().isEmpty) return null;
    return RegExp(r'rel="?next"?').hasMatch(link);
  }

  /// Manual checks only, when the API failed (usually the rate limit): the
  /// public release feed lists recent tags without using the API quota.
  ///
  /// A feed entry is offered only after its installer is confirmed to exist
  /// at the URL GitHub serves it from. The feed shows only recent releases
  /// and has no prerelease flag, so finding nothing here never means "up to
  /// date": null is returned and the caller reports the API failure.
  Future<DiscoveryResult?> _discoverFromFeed({
    required ReleaseVersion installed,
    required UpdatePlatform platform,
    required UpdateChannel channel,
  }) async {
    if (channel != UpdateChannel.stableAndPrerelease) return null;
    final String body;
    try {
      final response = await _client().get(
        Uri.parse('https://github.com/$repository/releases.atom'),
        headers: const {
          'User-Agent': 'Orvix-Updater',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
      ).timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      body = response.body;
    } catch (_) {
      return null;
    }

    final tagPattern = RegExp(
      '/${RegExp.escape(repository)}/releases/tag/([^"<>\\s?#]+)',
      caseSensitive: false,
    );
    final seen = <String>{};
    final candidates = <PublicRelease>[];
    for (final match in tagPattern.allMatches(body)) {
      final tag = Uri.decodeComponent(match.group(1)!);
      final version = ReleaseVersion.tryParse(tag);
      if (version == null || !(version > installed) || !seen.add(tag)) {
        continue;
      }
      candidates.add(PublicRelease(
        tag: tag,
        version: version,
        title: 'Orvix ${version.toString()}',
        notes: '',
        htmlUrl: 'https://github.com/$repository/releases/tag/$tag',
        // The feed carries no prerelease flag; the version decides.
        githubPrerelease: version.isPrerelease,
        assets: const [],
      ));
    }
    candidates.sort((a, b) => b.version.compareTo(a.version));

    PublicRelease? newestWithoutAsset;
    var confirmedMissing = false;
    for (final candidate in candidates.take(maxFeedProbes)) {
      final version = candidate.tag.replaceFirst(RegExp('^[vV]'), '');
      final names = expectedAssetNames(
        platform.target,
        version,
        androidAbis: platform.androidAbis.take(1).toList(),
      );
      var allMissing = true;
      for (final name in names) {
        final url = 'https://github.com/$repository/releases/download/'
            '${candidate.tag}/$name';
        final probe = await _probeAsset(url);
        if (probe.size != null) {
          final asset = ReleaseAsset(name: name, url: url, size: probe.size);
          final release = PublicRelease(
            tag: candidate.tag,
            version: candidate.version,
            title: candidate.title,
            notes: candidate.notes,
            htmlUrl: candidate.htmlUrl,
            githubPrerelease: candidate.githubPrerelease,
            assets: [asset],
          );
          return DiscoveryResult(
            DiscoveryStatus.available,
            release: release,
            asset: asset,
            newestWithoutAsset: newestWithoutAsset,
            viaReleaseFeed: true,
          );
        }
        if (!probe.missing) allMissing = false;
      }
      if (allMissing) {
        confirmedMissing = true;
        newestWithoutAsset ??= candidate;
      }
    }
    if (confirmedMissing && newestWithoutAsset != null) {
      return DiscoveryResult(
        DiscoveryStatus.noCompatibleAsset,
        newestWithoutAsset: newestWithoutAsset,
        viaReleaseFeed: true,
      );
    }
    return null;
  }

  /// Confirms that [url] serves a file, reading only its first byte.
  Future<({int? size, bool missing})> _probeAsset(String url) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = 'Orvix-Updater'
      ..headers['Range'] = 'bytes=0-0';
    try {
      final response = await _client().send(request).timeout(requestTimeout);
      unawaited(response.stream.drain<void>().catchError((_) {}));
      if (response.statusCode == 404) return (size: null, missing: true);
      if (response.statusCode == 206) {
        final range = response.headers['content-range'] ?? '';
        final total = int.tryParse(range.split('/').last.trim());
        if (total != null && total > 0) return (size: total, missing: false);
      }
      if (response.statusCode == 200) {
        final length = response.contentLength;
        if (length != null && length > 0) return (size: length, missing: false);
      }
    } catch (_) {}
    return (size: null, missing: false);
  }
}

class _JsonPage {
  const _JsonPage(this.json, {this.hasNextPage}) : failure = null;
  const _JsonPage.failed(this.failure)
      : json = null,
        hasNextPage = null;

  final Object? json;
  final bool? hasNextPage;
  final _HttpFailure? failure;
}

class _HttpFailure {
  const _HttpFailure(this.status, {this.httpStatus, this.resetAt});

  factory _HttpFailure.fromResponse(http.Response response) {
    final code = response.statusCode;
    final remaining = response.headers['x-ratelimit-remaining'];
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    final resetAt = reset == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
    final rateLimited = code == 429 ||
        (code == 403 &&
            (remaining == '0' ||
                response.headers.containsKey('retry-after') ||
                response.body.toLowerCase().contains('rate limit')));
    if (rateLimited) {
      return _HttpFailure(DiscoveryStatus.rateLimited,
          httpStatus: code, resetAt: resetAt);
    }
    if (code == 401 || code == 403) {
      return _HttpFailure(DiscoveryStatus.refused, httpStatus: code);
    }
    if (code >= 500) {
      return _HttpFailure(DiscoveryStatus.serverError, httpStatus: code);
    }
    return _HttpFailure(DiscoveryStatus.httpError, httpStatus: code);
  }

  final DiscoveryStatus status;
  final int? httpStatus;
  final DateTime? resetAt;

  /// The release feed does not use the API, so it can still answer when the
  /// API refuses or fails. A dead connection or timeout would fail it too.
  bool get feedMayHelp =>
      status != DiscoveryStatus.network && status != DiscoveryStatus.timeout;

  DiscoveryResult toResult({
    int releasesInspected = 0,
    int pagesFetched = 0,
    PublicRelease? newestWithoutAsset,
  }) =>
      DiscoveryResult(
        status,
        httpStatus: httpStatus,
        rateLimitResetAt: resetAt,
        releasesInspected: releasesInspected,
        pagesFetched: pagesFetched,
        newestWithoutAsset: newestWithoutAsset,
      );
}
