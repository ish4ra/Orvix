import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'local_torrent_service.dart';
import 'platform_profile.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.releaseUrl,
    required this.assetName,
    required this.assetUrl,
    this.assetDigest,
    this.assetSize,
    this.internalObjectPath,
  });

  final String tag;
  final String version;
  final String title;
  final String notes;
  final String releaseUrl;
  final String assetName;
  final String assetUrl;
  final String? assetDigest;
  final int? assetSize;
  // Non-null only for server-authorized internal update assets.
  final String? internalObjectPath;
}

enum AppUpdateInstallResult {
  installerOpened,
  permissionRequired,
  openedReleasePage,
  unsupported,
}

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    Future<String> Function()? installedVersionLoader,
  })  : _client = client ?? http.Client(),
        _installedVersionLoader =
            installedVersionLoader ?? installedVersion;

  static const _releasesBaseUrl =
      'https://api.github.com/repos/ish4ra/Orvix/releases';
  static const _releaseAssetFetchAttempts = 5;
  static const MethodChannel _androidUpdateChannel =
      MethodChannel('orvix/app_update');

  http.Client _client;
  final Future<String> Function() _installedVersionLoader;
  String? _installedVersionCache;

  static Future<String>? _installedVersionFuture;

  static Future<String> installedVersion() {
    return _installedVersionFuture ??= _loadInstalledVersion();
  }

  static Future<String> _loadInstalledVersion() async {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    if (version.isEmpty) {
      throw StateError('Installed Orvix version is unavailable.');
    }
    return version;
  }

  Future<String> _currentVersion() async {
    final cached = _installedVersionCache;
    if (cached != null && cached.isNotEmpty) return cached;

    final version = (await _installedVersionLoader()).trim();
    if (version.isEmpty) {
      throw StateError('Installed Orvix version is unavailable.');
    }
    _installedVersionCache = version;
    return version;
  }

  void _resetClient() {
    _client.close();
    _client = http.Client();
  }

  Future<({bool success, String detail, String version})?>
      consumeLastWindowsUpdateStatus() async {
    if (!Platform.isWindows) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final statusFile = File(
        '${support.path}${Platform.pathSeparator}update-handoff'
        '${Platform.pathSeparator}last-update-status.txt',
      );
      if (!await statusFile.exists()) return null;
      final raw = (await statusFile.readAsString()).trim();
      await statusFile.delete();
      final parts = raw.split('|');
      if (parts.length < 3) return null;
      final version = parts.sublist(2).join('|');
      final currentVersion = await _currentVersion();
      // A manual/newer install may leave an old helper status file behind.
      // Never surface a stale failure for an older target version.
      if (isVersionNewer(currentVersion, version)) return null;
      return (
        success: parts[0] == 'success',
        detail: parts[1],
        version: version,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    String currentVersion;
    try {
      currentVersion = await _currentVersion();
    } catch (_) {
      return null;
    }

    // Admin eligibility is verified by the Edge Function on every request.
    // Ordinary users and offline clients retain the existing public channel.
    final internal = await _checkInternalForUpdate(currentVersion);
    if (internal != null) return internal;

    try {
      final releasesUri = Uri.parse(_releasesBaseUrl).replace(
        queryParameters: <String, String>{
          'per_page': '30',
          // Prevent an intermediary/CDN from replaying a just-before-release
          // collection response during rapid release publication.
          '_orvix_check': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final response = await _client
          .get(
            releasesUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Orvix-Updater',
              'X-GitHub-Api-Version': '2022-11-28',
              'Cache-Control': 'no-cache, no-store, max-age=0',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          AppUpdateInfo? best;
          for (final raw in decoded) {
            if (raw is! Map<String, dynamic>) continue;
            if (raw['draft'] == true) continue;
            final tag = raw['tag_name']?.toString().trim() ?? '';
            if (tag.isEmpty || !isVersionNewer(tag, currentVersion)) continue;

            var asset = _selectAsset(raw['assets']);
            // GitHub can briefly publish a new release in the collection
            // response with an empty inline assets array even though the
            // dedicated /releases/{id}/assets endpoint already has the files.
            if (asset == null) {
              final assetsUrl = raw['assets_url']?.toString().trim() ?? '';
              if (assetsUrl.isNotEmpty) {
                final assets = await _fetchReleaseAssets(
                  assetsUrl,
                  attempts: _releaseAssetFetchAttempts,
                );
                asset = _selectAsset(assets);
              }
            }
            if (asset == null) continue;

            final candidate = AppUpdateInfo(
              tag: tag,
              version: tag.replaceFirst(RegExp(r'^v'), ''),
              title: raw['name']?.toString().trim().isNotEmpty == true
                  ? raw['name'].toString().trim()
                  : tag,
              notes: raw['body']?.toString() ?? '',
              releaseUrl: raw['html_url']?.toString() ?? '',
              assetName: asset['name']?.toString() ?? '',
              assetUrl: asset['browser_download_url']?.toString() ?? '',
              assetDigest: asset['digest']?.toString(),
              assetSize: _asInt(asset['size']),
            );
            if (candidate.assetUrl.isEmpty) continue;
            if (best == null ||
                isVersionNewer(candidate.version, best.version)) {
              best = candidate;
            }
          }
          if (best != null) return best;
        }
      }
    } catch (_) {
      // Fall through to the non-API release feed below. GitHub's unauthenticated
      // REST API is rate-limited per public IP, which can be hit during rapid
      // beta testing or on shared/CGNAT connections.
      _resetClient();
    }

    return _checkReleaseFeedFallback(currentVersion);
  }

  Future<AppUpdateInfo?> _checkReleaseFeedFallback(
    String currentVersion,
  ) async {
    const sources = <String>[
      'https://github.com/ish4ra/Orvix/releases.atom',
      'https://github.com/ish4ra/Orvix/releases',
    ];
    final tagPattern = RegExp(
      r'/ish4ra/Orvix/releases/tag/(v?\d+\.\d+\.\d+(?:-[A-Za-z]+(?:[.-]?\d+)?)?)',
      caseSensitive: false,
    );

    for (final source in sources) {
      try {
        final response = await _client
            .get(
              Uri.parse(source),
              headers: const {
                'User-Agent': 'Orvix-Updater',
                'Cache-Control': 'no-cache',
                'Pragma': 'no-cache',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }

        String? bestTag;
        for (final match in tagPattern.allMatches(response.body)) {
          final tag = match.group(1)?.trim();
          if (tag == null ||
              tag.isEmpty ||
              !isVersionNewer(tag, currentVersion)) {
            continue;
          }
          if (bestTag == null || isVersionNewer(tag, bestTag)) {
            bestTag = tag;
          }
        }
        if (bestTag == null) continue;

        final version = bestTag.replaceFirst(RegExp(r'^v'), '');
        final assetName = _expectedAssetName(version);
        if (assetName == null) return null;

        final releaseUrl =
            'https://github.com/ish4ra/Orvix/releases/tag/$bestTag';
        final assetUrl =
            'https://github.com/ish4ra/Orvix/releases/download/'
            '$bestTag/$assetName';

        return AppUpdateInfo(
          tag: bestTag,
          version: version,
          title: 'Orvix v$version',
          notes:
              'Update details are available on the Orvix GitHub release page.',
          releaseUrl: releaseUrl,
          assetName: assetName,
          assetUrl: assetUrl,
        );
      } catch (_) {
        _resetClient();
      }
    }
    return null;
  }

  String? _internalPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) {
      return PlatformProfile.isAndroidTv ? 'android_tv' : 'android_mobile';
    }
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios_modern';
    return null;
  }

  Future<AppUpdateInfo?> _checkInternalForUpdate(String installed) async {
    final platform = _internalPlatform();
    if (platform == null) return null;
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) return null;
      final response = await client.functions.invoke(
        'orvix-internal-update',
        body: {'action': 'check', 'platform': platform},
      ).timeout(const Duration(seconds: 8));
      final data = response.data;
      if (data is! Map || data['releases'] is! List) return null;
      AppUpdateInfo? best;
      for (final item in data['releases'] as List) {
        if (item is! Map) continue;
        final version = item['version']?.toString() ?? '';
        final path = item['object_path']?.toString() ?? '';
        final name = item['asset_name']?.toString() ?? '';
        final digest = item['sha256']?.toString() ?? '';
        final size = item['size_bytes'];
        // The check endpoint deliberately doesn't expose object paths.
        // Download lookup uses version+platform, validated server-side.
        if (version.isEmpty || name.isEmpty ||
            !RegExp(r'^[0-9a-f]{64}
    if (Platform.isWindows) {
      return 'Orvix-Setup-v$version-Windows-x64.exe';
    }
    if (Platform.isAndroid) {
      return PlatformProfile.isAndroidTv
          ? 'Orvix-v$version-Android-TV.apk'
          : 'Orvix-v$version-Android-Mobile.apk';
    }
    if (Platform.isMacOS) {
      return 'Orvix-v$version-macOS.zip';
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchReleaseAssets(
    String assetsUrl, {
    int attempts = 1,
  }) async {
    final totalAttempts = attempts.clamp(1, 8);
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      try {
        final base = Uri.parse(assetsUrl);
        final uri = base.replace(
          queryParameters: <String, String>{
            ...base.queryParameters,
            'per_page': '100',
            '_orvix_asset_check':
                DateTime.now().millisecondsSinceEpoch.toString(),
          },
        );
        final response = await _client
            .get(
              uri,
              headers: const {
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'Orvix-Updater',
                'X-GitHub-Api-Version': '2022-11-28',
                'Cache-Control': 'no-cache, no-store, max-age=0',
                'Pragma': 'no-cache',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(response.body);
          if (decoded is List) {
            final assets =
                decoded.whereType<Map<String, dynamic>>().toList();
            if (_selectAsset(assets) != null || attempt + 1 >= totalAttempts) {
              return assets;
            }
          }
        }
      } catch (_) {
        if (attempt + 1 >= totalAttempts) return const [];
      }

      // A GitHub release is created before gh finishes uploading every asset.
      // Retry the dedicated asset endpoint while that publication window is
      // still open instead of permanently missing this version.
      if (attempt + 1 < totalAttempts) {
        final seconds = attempt < 2 ? 2 : 4;
        await Future<void>.delayed(Duration(seconds: seconds));
      }
    }
    return const [];
  }

  Map<String, dynamic>? _selectAsset(Object? rawAssets) {
    if (rawAssets is! List) return null;
    final assets = rawAssets.whereType<Map<String, dynamic>>().toList();

    bool matches(Map<String, dynamic> asset, bool Function(String name) test) {
      final name = asset['name']?.toString() ?? '';
      return test(name);
    }

    if (Platform.isWindows) {
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) =>
                      name.contains('Windows-x64') &&
                      name.toLowerCase().endsWith('.exe'),
                ),
            orElse: () => null,
          );
    }

    if (Platform.isAndroid) {
      if (PlatformProfile.isAndroidTv) {
        return assets.cast<Map<String, dynamic>?>().firstWhere(
              (asset) =>
                  asset != null &&
                  matches(
                    asset,
                    (name) => name.endsWith('Android-TV.apk'),
                  ),
              orElse: () => null,
            );
      }
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) => name.endsWith('Android-Mobile.apk'),
                ),
            orElse: () => null,
          );
    }

    if (Platform.isMacOS) {
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) {
                    final lower = name.toLowerCase();
                    return (lower.contains('macos') ||
                            lower.contains('mac-')) &&
                        (lower.endsWith('.dmg') ||
                            lower.endsWith('.pkg') ||
                            lower.endsWith('.zip'));
                  },
                ),
            orElse: () => null,
          );
    }

    return null;
  }

  Future<File> download(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final temp = await getTemporaryDirectory();
    final updateDir = Directory(
      '${temp.path}${Platform.pathSeparator}orvix-updates',
    );
    await updateDir.create(recursive: true);
    final file = File(
      '${updateDir.path}${Platform.pathSeparator}${update.assetName}',
    );
    if (await file.exists()) await file.delete();

    final expectedTotal = update.assetSize ?? 0;
    var received = 0;
    Object? lastError;

    // Android can suspend the activity/network socket when the user leaves
    // Orvix during a large GitHub download. Resume the same APK with HTTP
    // Range requests instead of treating that transient disconnect as a
    // failed update. Each retry starts from the stable GitHub asset URL so a
    // fresh signed release-assets redirect is obtained.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (isCancelled?.call() == true) {
        if (await file.exists()) await file.delete();
        throw const _UpdateDownloadCancelled();
      }

      IOSink? sink;
      try {
        // Signed internal storage URLs are refreshed on each retry, never
        // persisted or distributed through public GitHub release metadata.
        final assetUrl = update.internalObjectPath != null
            ? await _internalSignedDownloadUrl(update)
            : update.assetUrl;
        final request = http.Request('GET', Uri.parse(assetUrl));
        request.headers['User-Agent'] = 'Orvix-Updater';
        if (received > 0) request.headers['Range'] = 'bytes=$received-';

        final response = await _client.send(request).timeout(
              const Duration(seconds: 30),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Update download returned HTTP ${response.statusCode}.',
          );
        }

        // A server may ignore Range and return the whole asset. In that case
        // restart the local file rather than appending a duplicate APK.
        final resumed = received > 0 && response.statusCode == 206;
        if (received > 0 && !resumed) {
          received = 0;
          if (await file.exists()) await file.delete();
        }

        sink = file.openWrite(
          mode: resumed ? FileMode.append : FileMode.write,
        );
        final responseTotal = response.contentLength ?? 0;
        final expected = expectedTotal > 0
            ? expectedTotal
            : received + responseTotal;

        await for (final chunk in response.stream) {
          if (isCancelled?.call() == true) {
            throw const _UpdateDownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          if (expected > 0) {
            onProgress?.call((received / expected).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;

        if (expectedTotal <= 0 || received >= expectedTotal) {
          lastError = null;
          break;
        }
        lastError = StateError(
          'Update download ended early ($received/$expectedTotal bytes).',
        );
      } on _UpdateDownloadCancelled {
        await sink?.close();
        if (await file.exists()) await file.delete();
        rethrow;
      } catch (error) {
        lastError = error;
        await sink?.close();
        // A dropped Android/background socket can leave package:http's
        // persistent client tied to the dead connection. Recreate it before
        // retrying so the next Range request gets a genuinely fresh socket.
        _resetClient();
      }

      if (attempt < 4) {
        await Future<void>.delayed(Duration(seconds: attempt < 2 ? 1 : 2));
      }
    }

    if (lastError != null) throw lastError;
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('Downloaded update file is empty.');
    }
    if (expectedTotal > 0 && await file.length() != expectedTotal) {
      throw StateError('Downloaded update file size did not match GitHub.');
    }

    final digest = update.assetDigest?.trim();
    if (digest != null && digest.toLowerCase().startsWith('sha256:')) {
      final expectedHash = digest.substring('sha256:'.length).toLowerCase();
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString().toLowerCase() != expectedHash) {
        await file.delete().catchError((_) => file);
        throw StateError('Downloaded update checksum did not match GitHub.');
      }
    }

    onProgress?.call(1);
    return file;
  }

  Future<AppUpdateInstallResult> install(
    AppUpdateInfo update,
    File file,
  ) async {
    if (Platform.isWindows) {
      // Keep Windows updates deliberately simple and observable. The old
      // helper -> silent installer -> helper restart chain could fail on a
      // locked file and then reopen the previous build, creating duplicate
      // windows if the user relaunched Orvix at the same time.
      //
      // Instead, hand the verified installer directly to Windows, then close
      // Orvix. The interactive installer owns file replacement and can show a
      // real error/retry UI if Windows has a lock. The installer itself offers
      // to launch the updated Orvix when setup completes.
      await LocalTorrentService.instance.dispose();

      final process = await Process.start(
        file.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      if (process.pid <= 0) {
        throw StateError('Windows installer could not be started.');
      }

      // Match the proven desktop-updater pattern: give Setup enough time to
      // create its UI/process before releasing the running app's file locks.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        // Close through the native window first so WM_DESTROY cleanup runs.
        // Keep exit(0) only as a last-resort fallback if a plugin/window hook
        // refuses to close for some unexpected reason.
        await windowManager.close();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (_) {}
      exit(0);
    }

    if (Platform.isAndroid) {
      try {
        final result = await _androidUpdateChannel.invokeMethod<String>(
          'installApk',
          {'path': file.path},
        );
        if (result == 'permission_required') {
          return AppUpdateInstallResult.permissionRequired;
        }
        return AppUpdateInstallResult.installerOpened;
      } on PlatformException {
        return _openReleasePage(update);
      } on MissingPluginException {
        return _openReleasePage(update);
      }
    }

    if (Platform.isMacOS) {
      await Process.start(
        'open',
        [file.path],
        mode: ProcessStartMode.detached,
      );
      return AppUpdateInstallResult.installerOpened;
    }

    return _openReleasePage(update);
  }

  Future<AppUpdateInstallResult> _openReleasePage(AppUpdateInfo update) async {
    final uri = Uri.tryParse(update.releaseUrl);
    if (uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return AppUpdateInstallResult.openedReleasePage;
    }
    return AppUpdateInstallResult.unsupported;
  }

  static bool isVersionNewer(String candidate, String current) {
    final a = _parseVersion(candidate);
    final b = _parseVersion(current);
    if (a == null || b == null) return false;

    // Orvix beta releases are sequential update builds. A prerelease of the
    // next base version (for example 0.7.8-beta.1) must update an installed
    // 0.7.7 stable build. Within the same base version, normal SemVer ordering
    // still applies: stable > rc > beta > alpha, and beta.2 > beta.1.
    for (var i = 0; i < 3; i++) {
      if (a.$1[i] != b.$1[i]) return a.$1[i] > b.$1[i];
    }

    if (a.$2 != b.$2) return a.$2 > b.$2;
    return a.$3 > b.$3;
  }

  static (List<int>, int, int)? _parseVersion(String raw) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)[.-]?(\d+)?)?',
    ).firstMatch(raw.trim());
    if (match == null) return null;
    final base = <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
    final label = match.group(4)?.toLowerCase();
    final stage = switch (label) {
      null => 4,
      'rc' => 3,
      'beta' => 2,
      'alpha' => 1,
      _ => 0,
    };
    final number = int.tryParse(match.group(5) ?? '') ?? 0;
    return (base, stage, number);
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void dispose() => _client.close();
}

class _UpdateDownloadCancelled implements Exception {
  const _UpdateDownloadCancelled();

  @override
  String toString() => 'Update download cancelled.';
}
).hasMatch(digest) ||
            size is! num || size <= 0 ||
            !isVersionNewer(version, installed)) continue;
        final candidate = AppUpdateInfo(
          tag: 'v$version',
          version: version,
          title: 'Orvix Internal $version',
          notes: item['notes']?.toString() ?? '',
          releaseUrl: '',
          assetName: name,
          assetUrl: '',
          assetDigest: 'sha256:$digest',
          assetSize: size.toInt(),
          internalObjectPath: 'version:$version',
        );
        if (best == null || isVersionNewer(candidate.version, best.version)) {
          best = candidate;
        }
      }
      return best;
    } catch (_) {
      // Never leak internal metadata and never block the ordinary updater.
      return null;
    }
  }

  Future<String> _internalSignedDownloadUrl(AppUpdateInfo update) async {
    final platform = _internalPlatform();
    if (platform == null || Supabase.instance.client.auth.currentSession == null) {
      throw StateError('Sign in to your authorized Orvix account.');
    }
    final response = await Supabase.instance.client.functions.invoke(
      'orvix-internal-update',
      body: {
        'action': 'download',
        'platform': platform,
        'version': update.version,
      },
    ).timeout(const Duration(seconds: 15));
    final data = response.data;
    if (data is! Map || data['url'] is! String) {
      throw StateError('Internal update is not currently available.');
    }
    if (data['sha256']?.toString() !=
        update.assetDigest?.replaceFirst('sha256:', '')) {
      throw StateError('Internal update checksum metadata changed.');
    }
    final uri = Uri.tryParse(data['url'] as String);
    if (uri == null || uri.scheme != 'https') {
      throw StateError('Internal update URL is invalid.');
    }
    return uri.toString();
  }

  String? _expectedAssetName(String version) {
    if (Platform.isWindows) {
      return 'Orvix-Setup-v$version-Windows-x64.exe';
    }
    if (Platform.isAndroid) {
      return PlatformProfile.isAndroidTv
          ? 'Orvix-v$version-Android-TV.apk'
          : 'Orvix-v$version-Android-Mobile.apk';
    }
    if (Platform.isMacOS) {
      return 'Orvix-v$version-macOS.zip';
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchReleaseAssets(
    String assetsUrl, {
    int attempts = 1,
  }) async {
    final totalAttempts = attempts.clamp(1, 8);
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      try {
        final base = Uri.parse(assetsUrl);
        final uri = base.replace(
          queryParameters: <String, String>{
            ...base.queryParameters,
            'per_page': '100',
            '_orvix_asset_check':
                DateTime.now().millisecondsSinceEpoch.toString(),
          },
        );
        final response = await _client
            .get(
              uri,
              headers: const {
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'Orvix-Updater',
                'X-GitHub-Api-Version': '2022-11-28',
                'Cache-Control': 'no-cache, no-store, max-age=0',
                'Pragma': 'no-cache',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(response.body);
          if (decoded is List) {
            final assets =
                decoded.whereType<Map<String, dynamic>>().toList();
            if (_selectAsset(assets) != null || attempt + 1 >= totalAttempts) {
              return assets;
            }
          }
        }
      } catch (_) {
        if (attempt + 1 >= totalAttempts) return const [];
      }

      // A GitHub release is created before gh finishes uploading every asset.
      // Retry the dedicated asset endpoint while that publication window is
      // still open instead of permanently missing this version.
      if (attempt + 1 < totalAttempts) {
        final seconds = attempt < 2 ? 2 : 4;
        await Future<void>.delayed(Duration(seconds: seconds));
      }
    }
    return const [];
  }

  Map<String, dynamic>? _selectAsset(Object? rawAssets) {
    if (rawAssets is! List) return null;
    final assets = rawAssets.whereType<Map<String, dynamic>>().toList();

    bool matches(Map<String, dynamic> asset, bool Function(String name) test) {
      final name = asset['name']?.toString() ?? '';
      return test(name);
    }

    if (Platform.isWindows) {
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) =>
                      name.contains('Windows-x64') &&
                      name.toLowerCase().endsWith('.exe'),
                ),
            orElse: () => null,
          );
    }

    if (Platform.isAndroid) {
      if (PlatformProfile.isAndroidTv) {
        return assets.cast<Map<String, dynamic>?>().firstWhere(
              (asset) =>
                  asset != null &&
                  matches(
                    asset,
                    (name) => name.endsWith('Android-TV.apk'),
                  ),
              orElse: () => null,
            );
      }
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) => name.endsWith('Android-Mobile.apk'),
                ),
            orElse: () => null,
          );
    }

    if (Platform.isMacOS) {
      return assets.cast<Map<String, dynamic>?>().firstWhere(
            (asset) =>
                asset != null &&
                matches(
                  asset,
                  (name) {
                    final lower = name.toLowerCase();
                    return (lower.contains('macos') ||
                            lower.contains('mac-')) &&
                        (lower.endsWith('.dmg') ||
                            lower.endsWith('.pkg') ||
                            lower.endsWith('.zip'));
                  },
                ),
            orElse: () => null,
          );
    }

    return null;
  }

  Future<File> download(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final temp = await getTemporaryDirectory();
    final updateDir = Directory(
      '${temp.path}${Platform.pathSeparator}orvix-updates',
    );
    await updateDir.create(recursive: true);
    final file = File(
      '${updateDir.path}${Platform.pathSeparator}${update.assetName}',
    );
    if (await file.exists()) await file.delete();

    final expectedTotal = update.assetSize ?? 0;
    var received = 0;
    Object? lastError;

    // Android can suspend the activity/network socket when the user leaves
    // Orvix during a large GitHub download. Resume the same APK with HTTP
    // Range requests instead of treating that transient disconnect as a
    // failed update. Each retry starts from the stable GitHub asset URL so a
    // fresh signed release-assets redirect is obtained.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (isCancelled?.call() == true) {
        if (await file.exists()) await file.delete();
        throw const _UpdateDownloadCancelled();
      }

      IOSink? sink;
      try {
        final request = http.Request('GET', Uri.parse(update.assetUrl));
        request.headers['User-Agent'] = 'Orvix-Updater';
        if (received > 0) request.headers['Range'] = 'bytes=$received-';

        final response = await _client.send(request).timeout(
              const Duration(seconds: 30),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Update download returned HTTP ${response.statusCode}.',
          );
        }

        // A server may ignore Range and return the whole asset. In that case
        // restart the local file rather than appending a duplicate APK.
        final resumed = received > 0 && response.statusCode == 206;
        if (received > 0 && !resumed) {
          received = 0;
          if (await file.exists()) await file.delete();
        }

        sink = file.openWrite(
          mode: resumed ? FileMode.append : FileMode.write,
        );
        final responseTotal = response.contentLength ?? 0;
        final expected = expectedTotal > 0
            ? expectedTotal
            : received + responseTotal;

        await for (final chunk in response.stream) {
          if (isCancelled?.call() == true) {
            throw const _UpdateDownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          if (expected > 0) {
            onProgress?.call((received / expected).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;

        if (expectedTotal <= 0 || received >= expectedTotal) {
          lastError = null;
          break;
        }
        lastError = StateError(
          'Update download ended early ($received/$expectedTotal bytes).',
        );
      } on _UpdateDownloadCancelled {
        await sink?.close();
        if (await file.exists()) await file.delete();
        rethrow;
      } catch (error) {
        lastError = error;
        await sink?.close();
        // A dropped Android/background socket can leave package:http's
        // persistent client tied to the dead connection. Recreate it before
        // retrying so the next Range request gets a genuinely fresh socket.
        _resetClient();
      }

      if (attempt < 4) {
        await Future<void>.delayed(Duration(seconds: attempt < 2 ? 1 : 2));
      }
    }

    if (lastError != null) throw lastError;
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('Downloaded update file is empty.');
    }
    if (expectedTotal > 0 && await file.length() != expectedTotal) {
      throw StateError('Downloaded update file size did not match GitHub.');
    }

    final digest = update.assetDigest?.trim();
    if (digest != null && digest.toLowerCase().startsWith('sha256:')) {
      final expectedHash = digest.substring('sha256:'.length).toLowerCase();
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString().toLowerCase() != expectedHash) {
        await file.delete().catchError((_) => file);
        throw StateError('Downloaded update checksum did not match GitHub.');
      }
    }

    onProgress?.call(1);
    return file;
  }

  Future<AppUpdateInstallResult> install(
    AppUpdateInfo update,
    File file,
  ) async {
    if (Platform.isWindows) {
      // Keep Windows updates deliberately simple and observable. The old
      // helper -> silent installer -> helper restart chain could fail on a
      // locked file and then reopen the previous build, creating duplicate
      // windows if the user relaunched Orvix at the same time.
      //
      // Instead, hand the verified installer directly to Windows, then close
      // Orvix. The interactive installer owns file replacement and can show a
      // real error/retry UI if Windows has a lock. The installer itself offers
      // to launch the updated Orvix when setup completes.
      await LocalTorrentService.instance.dispose();

      final process = await Process.start(
        file.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      if (process.pid <= 0) {
        throw StateError('Windows installer could not be started.');
      }

      // Match the proven desktop-updater pattern: give Setup enough time to
      // create its UI/process before releasing the running app's file locks.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        // Close through the native window first so WM_DESTROY cleanup runs.
        // Keep exit(0) only as a last-resort fallback if a plugin/window hook
        // refuses to close for some unexpected reason.
        await windowManager.close();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (_) {}
      exit(0);
    }

    if (Platform.isAndroid) {
      try {
        final result = await _androidUpdateChannel.invokeMethod<String>(
          'installApk',
          {'path': file.path},
        );
        if (result == 'permission_required') {
          return AppUpdateInstallResult.permissionRequired;
        }
        return AppUpdateInstallResult.installerOpened;
      } on PlatformException {
        return _openReleasePage(update);
      } on MissingPluginException {
        return _openReleasePage(update);
      }
    }

    if (Platform.isMacOS) {
      await Process.start(
        'open',
        [file.path],
        mode: ProcessStartMode.detached,
      );
      return AppUpdateInstallResult.installerOpened;
    }

    return _openReleasePage(update);
  }

  Future<AppUpdateInstallResult> _openReleasePage(AppUpdateInfo update) async {
    final uri = Uri.tryParse(update.releaseUrl);
    if (uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return AppUpdateInstallResult.openedReleasePage;
    }
    return AppUpdateInstallResult.unsupported;
  }

  static bool isVersionNewer(String candidate, String current) {
    final a = _parseVersion(candidate);
    final b = _parseVersion(current);
    if (a == null || b == null) return false;

    // Orvix beta releases are sequential update builds. A prerelease of the
    // next base version (for example 0.7.8-beta.1) must update an installed
    // 0.7.7 stable build. Within the same base version, normal SemVer ordering
    // still applies: stable > rc > beta > alpha, and beta.2 > beta.1.
    for (var i = 0; i < 3; i++) {
      if (a.$1[i] != b.$1[i]) return a.$1[i] > b.$1[i];
    }

    if (a.$2 != b.$2) return a.$2 > b.$2;
    return a.$3 > b.$3;
  }

  static (List<int>, int, int)? _parseVersion(String raw) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)[.-]?(\d+)?)?',
    ).firstMatch(raw.trim());
    if (match == null) return null;
    final base = <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
    final label = match.group(4)?.toLowerCase();
    final stage = switch (label) {
      null => 4,
      'rc' => 3,
      'beta' => 2,
      'alpha' => 1,
      _ => 0,
    };
    final number = int.tryParse(match.group(5) ?? '') ?? 0;
    return (base, stage, number);
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void dispose() => _client.close();
}

class _UpdateDownloadCancelled implements Exception {
  const _UpdateDownloadCancelled();

  @override
  String toString() => 'Update download cancelled.';
}
