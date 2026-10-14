import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'local_torrent_service.dart';
import 'platform_profile.dart';
import 'public_release_discovery.dart';
import 'release_version.dart';

export 'public_release_discovery.dart' show UpdateChannel, UpdatePlatform, UpdateTarget;

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
    this.prerelease = false,
    this.viaReleaseFeed = false,
    this.internalVersion,
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

  /// A public beta/prerelease. Never offered by the automatic check.
  final bool prerelease;

  /// Found through the release feed while the GitHub API was unavailable:
  /// no GitHub checksum is known, only the file size.
  final bool viaReleaseFeed;

  /// Set only by the dormant private channel (private_update_channel.dart).
  /// Public discovery never produces such an update.
  final String? internalVersion;
}

enum AppUpdateInstallResult {
  installerOpened,
  permissionRequired,
  openedReleasePage,

  /// macOS: the downloaded archive was shown in Finder for the user to
  /// install by hand.
  revealedDownload,
  unsupported,
}

/// An update step failed; [message] is written for the user.
class UpdateFailure implements Exception {
  const UpdateFailure(this.message, {this.retryable = true});

  final String message;

  /// Retrying the same download can help (false for a rejected APK).
  final bool retryable;

  @override
  String toString() => message;
}

enum UpdateCheckStatus {
  available,
  upToDate,
  noCompatibleAsset,
  rateLimited,
  timeout,
  network,
  serverError,
  refused,
  httpError,
  invalidResponse,
  incomplete,
  unsupportedPlatform,
  installedVersionUnknown,
}

/// Everything an update check needs to explain its result.
class UpdateCheckReport {
  const UpdateCheckReport({
    required this.status,
    required this.installedVersion,
    this.update,
    this.channel = UpdateChannel.stableAndPrerelease,
    this.target,
    this.newestWithoutAsset,
    this.httpStatus,
    this.rateLimitResetAt,
    this.releasesInspected = 0,
  });

  final UpdateCheckStatus status;
  final String? installedVersion;

  /// The newest eligible update with an installer for this device.
  final AppUpdateInfo? update;
  final UpdateChannel channel;
  final UpdateTarget? target;

  /// The version of a newer eligible release without an installer for this
  /// device (it may be newer than [update]).
  final String? newestWithoutAsset;
  final int? httpStatus;
  final DateTime? rateLimitResetAt;
  final int releasesInspected;

  /// The check could not reach a conclusion. Never shown as "up to date".
  bool get failed => switch (status) {
        UpdateCheckStatus.available ||
        UpdateCheckStatus.upToDate ||
        UpdateCheckStatus.noCompatibleAsset =>
          false,
        _ => true,
      };
}

/// Runs the Android package installer for an APK and returns
/// `installer_opened` or `permission_required`. Throws [PlatformException]
/// with `apk_invalid`, `package_mismatch` or `version_code_not_newer` when
/// the APK cannot update this installation.
typedef AndroidApkInstaller = Future<String?> Function(String apkPath);

/// Public update checks, download, verification and installer handoff.
///
/// Discovery uses public GitHub releases only. It needs no Orvix account and
/// never asks the private update channel.
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    Future<String> Function()? installedVersionLoader,
    Future<UpdatePlatform?> Function()? platformLoader,
    Future<Directory> Function()? downloadDirectory,
    AndroidApkInstaller? androidInstaller,
    Future<void> Function(File installer)? windowsInstallerLauncher,
    Future<void> Function(File archive)? macosRevealer,
    Future<bool> Function(Uri uri)? urlOpener,
    Future<void> Function(Duration delay)? sleep,
  })  : _client = client ?? http.Client(),
        _installedVersionLoader = installedVersionLoader ?? installedVersion,
        _platformLoader = platformLoader ?? detectPlatform,
        _downloadDirectory = downloadDirectory ?? _defaultDownloadDirectory,
        _androidInstaller = androidInstaller ?? _installApkThroughChannel,
        _windowsInstallerLauncher =
            windowsInstallerLauncher ?? _launchWindowsInstaller,
        _macosRevealer = macosRevealer ?? _revealInFinder,
        _urlOpener = urlOpener ?? _openExternal,
        _sleep = sleep ?? Future<void>.delayed {
    _discovery = PublicReleaseDiscovery(client: () => _client);
  }

  static const MethodChannel _androidUpdateChannel =
      MethodChannel('orvix/app_update');

  http.Client _client;
  late final PublicReleaseDiscovery _discovery;
  final Future<String> Function() _installedVersionLoader;
  final Future<UpdatePlatform?> Function() _platformLoader;
  final Future<Directory> Function() _downloadDirectory;
  final AndroidApkInstaller _androidInstaller;
  final Future<void> Function(File installer) _windowsInstallerLauncher;
  final Future<void> Function(File archive) _macosRevealer;
  final Future<bool> Function(Uri uri) _urlOpener;
  final Future<void> Function(Duration delay) _sleep;
  String? _installedVersionCache;
  Future<UpdatePlatform?>? _platform;

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

  /// The product this build updates as, or null where Orvix has no update
  /// path (Linux, web).
  static Future<UpdatePlatform?> detectPlatform() async {
    if (Platform.isAndroid) {
      if (PlatformProfile.isAndroidTv) {
        return const UpdatePlatform(UpdateTarget.androidTv);
      }
      var abis = const <String>[];
      try {
        abis = await _androidUpdateChannel
                .invokeListMethod<String>('deviceAbis') ??
            const [];
      } catch (_) {
        // Unknown ABIs: only the universal phone APK is offered.
      }
      return UpdatePlatform(UpdateTarget.androidMobile, androidAbis: abis);
    }
    if (Platform.isWindows) return const UpdatePlatform(UpdateTarget.windows);
    if (Platform.isMacOS) return const UpdatePlatform(UpdateTarget.macos);
    if (Platform.isIOS) return const UpdatePlatform(UpdateTarget.ios);
    return null;
  }

  Future<UpdatePlatform?> platform() => _platform ??= _platformLoader();

  /// The installed version this service compares against.
  Future<String> currentVersion() => _currentVersion();

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

  /// The automatic (startup) check: a newer public stable release with an
  /// installer for this device, or null. Betas, drafts and failed checks
  /// never produce a prompt. iOS keeps its previous behaviour of no
  /// automatic prompt, because the app cannot install the update itself.
  Future<AppUpdateInfo?> checkAutomatic() async {
    final target = await platform();
    if (target == null || !target.installsInApp) return null;
    final report = await check(UpdateChannel.stable);
    final update = report.update;
    if (update == null || update.prerelease) return null;
    return update;
  }

  /// The manual Settings check: public stable releases and public betas.
  Future<UpdateCheckReport> checkForUpdateReport() =>
      check(UpdateChannel.stableAndPrerelease);

  Future<UpdateCheckReport> check(UpdateChannel channel) async {
    final String installedText;
    final ReleaseVersion? installed;
    try {
      installedText = await _currentVersion();
      installed = ReleaseVersion.tryParse(installedText);
    } catch (_) {
      return UpdateCheckReport(
        status: UpdateCheckStatus.installedVersionUnknown,
        installedVersion: null,
        channel: channel,
      );
    }
    if (installed == null) {
      return UpdateCheckReport(
        status: UpdateCheckStatus.installedVersionUnknown,
        installedVersion: installedText,
        channel: channel,
      );
    }
    final target = await platform();
    if (target == null) {
      return UpdateCheckReport(
        status: UpdateCheckStatus.unsupportedPlatform,
        installedVersion: installedText,
        channel: channel,
      );
    }

    final result = await _discovery.discover(
      installed: installed,
      platform: target,
      channel: channel,
      allowFeedFallback: channel == UpdateChannel.stableAndPrerelease,
    );
    if (result.status == DiscoveryStatus.network ||
        result.status == DiscoveryStatus.timeout) {
      // A dead socket can stay pooled in package:http's client.
      _resetClient();
    }

    final release = result.release;
    final asset = result.asset;
    final update = release == null || asset == null
        ? null
        : AppUpdateInfo(
            tag: release.tag,
            version: release.version.toString(),
            title: release.title,
            notes: release.notes,
            releaseUrl: release.htmlUrl,
            assetName: asset.name,
            assetUrl: asset.url,
            assetDigest: asset.digest,
            assetSize: asset.size,
            prerelease: release.isPrerelease,
            viaReleaseFeed: result.viaReleaseFeed,
          );
    return UpdateCheckReport(
      status: _statusOf(result.status),
      installedVersion: installedText,
      update: update,
      channel: channel,
      target: target.target,
      newestWithoutAsset: result.newestWithoutAsset?.version.toString(),
      httpStatus: result.httpStatus,
      rateLimitResetAt: result.rateLimitResetAt,
      releasesInspected: result.releasesInspected,
    );
  }

  static UpdateCheckStatus _statusOf(DiscoveryStatus status) =>
      switch (status) {
        DiscoveryStatus.available => UpdateCheckStatus.available,
        DiscoveryStatus.upToDate => UpdateCheckStatus.upToDate,
        DiscoveryStatus.noCompatibleAsset =>
          UpdateCheckStatus.noCompatibleAsset,
        DiscoveryStatus.rateLimited => UpdateCheckStatus.rateLimited,
        DiscoveryStatus.timeout => UpdateCheckStatus.timeout,
        DiscoveryStatus.network => UpdateCheckStatus.network,
        DiscoveryStatus.serverError => UpdateCheckStatus.serverError,
        DiscoveryStatus.refused => UpdateCheckStatus.refused,
        DiscoveryStatus.httpError => UpdateCheckStatus.httpError,
        DiscoveryStatus.invalidResponse => UpdateCheckStatus.invalidResponse,
        DiscoveryStatus.incomplete => UpdateCheckStatus.incomplete,
      };

  static Future<Directory> _defaultDownloadDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}${Platform.pathSeparator}orvix-updates');
  }

  Future<File> download(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (update.internalVersion != null) {
      throw const UpdateFailure(
        'Private builds are not offered by this version of Orvix.',
        retryable: false,
      );
    }
    final source = Uri.tryParse(update.assetUrl);
    if (source == null || source.scheme != 'https' || source.host.isEmpty) {
      throw const UpdateFailure(
        'This release has no valid download link.',
        retryable: false,
      );
    }
    final updateDir = await _downloadDirectory();
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
        final request = http.Request('GET', source);
        request.headers['User-Agent'] = 'Orvix-Updater';
        if (received > 0) request.headers['Range'] = 'bytes=$received-';

        final response = await _client.send(request).timeout(
              const Duration(seconds: 30),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          unawaited(response.stream.drain<void>().catchError((_) {}));
          final code = response.statusCode;
          throw UpdateFailure(
            'GitHub returned HTTP $code for the download.',
            // A missing or forbidden file does not appear by retrying now.
            retryable: code < 400 || code >= 500 || code == 408 || code == 429,
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
        lastError = UpdateFailure(
          'The download ended early ($received of $expectedTotal bytes).',
        );
      } on _UpdateDownloadCancelled {
        await sink?.close();
        if (await file.exists()) await file.delete();
        rethrow;
      } catch (error) {
        lastError = error;
        await sink?.close();
        if (error is UpdateFailure && !error.retryable) break;
        // A dropped Android/background socket can leave package:http's
        // persistent client tied to the dead connection. Recreate it before
        // retrying so the next Range request gets a genuinely fresh socket.
        _resetClient();
      }

      if (attempt < 4) {
        await _sleep(Duration(seconds: attempt < 2 ? 1 : 2));
      }
    }

    if (lastError != null) {
      if (await file.exists()) await file.delete();
      if (lastError is UpdateFailure) throw lastError;
      if (lastError is TimeoutException) {
        throw const UpdateFailure('The download timed out. Check the '
            'connection and try again.');
      }
      throw const UpdateFailure('The download failed. Check the connection '
          'and try again.');
    }
    if (!await file.exists() || await file.length() <= 0) {
      throw const UpdateFailure('The downloaded file is empty.');
    }
    if (expectedTotal > 0 && await file.length() != expectedTotal) {
      await file.delete();
      throw const UpdateFailure(
          'The downloaded file size did not match GitHub.');
    }

    final digest = update.assetDigest?.trim();
    if (digest != null && digest.toLowerCase().startsWith('sha256:')) {
      final expectedHash = digest.substring('sha256:'.length).toLowerCase();
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString().toLowerCase() != expectedHash) {
        await file.delete().catchError((_) => file);
        throw const UpdateFailure(
          "The download did not match GitHub's checksum and was deleted. "
          'Try again.',
        );
      }
    }

    onProgress?.call(1);
    return file;
  }

  /// Hands a downloaded and verified update to the platform installer.
  Future<AppUpdateInstallResult> install(
    AppUpdateInfo update,
    File file,
  ) async {
    final target = (await platform())?.target;
    switch (target) {
      case UpdateTarget.windows:
        await _windowsInstallerLauncher(file);
        return AppUpdateInstallResult.installerOpened;
      case UpdateTarget.androidMobile:
      case UpdateTarget.androidTv:
        return _installAndroid(update, file);
      case UpdateTarget.macos:
        await _macosRevealer(file);
        return AppUpdateInstallResult.revealedDownload;
      case UpdateTarget.ios:
      case null:
        return openReleasePage(update);
    }
  }

  Future<AppUpdateInstallResult> _installAndroid(
    AppUpdateInfo update,
    File file,
  ) async {
    final String? result;
    try {
      result = await _androidInstaller(file.path);
    } on PlatformException catch (error) {
      final rejected = switch (error.code) {
        'version_code_not_newer' =>
          'Android would reject this APK: its version code is lower than '
              'the installed Orvix. It was not installed.',
        'package_mismatch' =>
          'This APK is not an Orvix update for this app. It was not '
              'installed.',
        'apk_invalid' => 'The downloaded APK could not be read. Try again.',
        _ => null,
      };
      if (rejected != null) {
        await file.delete().catchError((_) => file);
        throw UpdateFailure(
          rejected,
          retryable: error.code == 'apk_invalid',
        );
      }
      return openReleasePage(update);
    } on MissingPluginException {
      return openReleasePage(update);
    }
    if (result == 'permission_required') {
      return AppUpdateInstallResult.permissionRequired;
    }
    return AppUpdateInstallResult.installerOpened;
  }

  /// Opens the GitHub release page (iOS, and a fallback elsewhere).
  Future<AppUpdateInstallResult> openReleasePage(AppUpdateInfo update) async {
    final uri = Uri.tryParse(update.releaseUrl);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        await _urlOpener(uri)) {
      return AppUpdateInstallResult.openedReleasePage;
    }
    return AppUpdateInstallResult.unsupported;
  }

  static Future<String?> _installApkThroughChannel(String path) =>
      _androidUpdateChannel.invokeMethod<String>('installApk', {'path': path});

  static Future<void> _launchWindowsInstaller(File file) async {
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
      throw const UpdateFailure('The Windows installer could not be started.');
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

  /// The macOS build is a ZIP of Orvix.app that is not notarized, so it
  /// cannot be installed silently. Show it in Finder; the UI explains the
  /// remaining steps.
  static Future<void> _revealInFinder(File file) async {
    await Process.start(
      'open',
      ['-R', file.path],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<bool> _openExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// SemVer precedence; see [ReleaseVersion]. False for invalid versions.
  static bool isVersionNewer(String candidate, String current) =>
      ReleaseVersion.isNewer(candidate, current);

  void dispose() => _client.close();
}

class _UpdateDownloadCancelled implements Exception {
  const _UpdateDownloadCancelled();

  @override
  String toString() => 'Update download cancelled.';
}
