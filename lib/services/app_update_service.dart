import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
}

enum AppUpdateInstallResult {
  installerOpened,
  permissionRequired,
  openedReleasePage,
  unsupported,
}

class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const currentVersion = '0.7.6-beta.19';
  static const _releasesUrl =
      'https://api.github.com/repos/ish4ra/Orvix/releases?per_page=12';
  static const MethodChannel _androidUpdateChannel =
      MethodChannel('orvix/app_update');

  final http.Client _client;

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
    try {
      final response = await _client
          .get(
            Uri.parse(_releasesUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Orvix-Updater',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! List) return null;

      AppUpdateInfo? best;
      for (final raw in decoded) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['draft'] == true) continue;
        final tag = raw['tag_name']?.toString().trim() ?? '';
        if (tag.isEmpty || !isVersionNewer(tag, currentVersion)) continue;

        final asset = _selectAsset(raw['assets']);
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
        if (best == null || isVersionNewer(candidate.version, best.version)) {
          best = candidate;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
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
  }) async {
    final request = http.Request('GET', Uri.parse(update.assetUrl));
    request.headers['User-Agent'] = 'Orvix-Updater';
    final response = await _client.send(request).timeout(
          const Duration(seconds: 25),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Update download returned HTTP ${response.statusCode}.');
    }

    final temp = await getTemporaryDirectory();
    final updateDir = Directory(
      '${temp.path}${Platform.pathSeparator}orvix-updates',
    );
    await updateDir.create(recursive: true);
    final file = File(
      '${updateDir.path}${Platform.pathSeparator}${update.assetName}',
    );
    if (await file.exists()) await file.delete();

    final sink = file.openWrite();
    final expected =
        response.contentLength ?? update.assetSize ?? 0;
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (expected > 0) {
          onProgress?.call((received / expected).clamp(0.0, 1.0));
        }
      }
    } finally {
      await sink.close();
    }

    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('Downloaded update file is empty.');
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
