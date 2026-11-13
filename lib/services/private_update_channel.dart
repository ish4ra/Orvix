// DORMANT. The owner-only private update channel (GitHub draft releases via
// the `orvix-internal-update` Supabase Edge Function).
//
// Normal update discovery does not use this file: startup checks, manual
// Settings checks and the update banner work only from public GitHub
// releases (see public_release_discovery.dart). Nothing in the app
// constructs [PrivateUpdateChannel] today; it is kept, with its tests, so the
// channel can be re-enabled deliberately later instead of being rebuilt. The
// deployed Edge Function and its database objects are left untouched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_update_service.dart';
import 'platform_profile.dart';
import 'release_version.dart';

/// Result of asking the owner-only private update channel.
enum PrivateUpdateStatus {
  /// This platform has no private channel.
  unsupportedPlatform,

  /// No Orvix account session on this device.
  signedOut,

  /// Signed in, but the account is not an Orvix admin. The UI never mentions
  /// private builds to these accounts.
  notEntitled,

  /// The account session expired and could not be refreshed.
  sessionExpired,

  /// Admin only: the server has no GitHub credential configured.
  serverUnconfigured,

  /// Admin only: GitHub refused or failed the draft lookup.
  githubUnavailable,

  /// The private endpoint could not be reached or failed unexpectedly.
  unavailable,

  /// Admin: no private build newer than the installed version.
  noNewerBuild,

  /// Admin: a newer private build exists for this platform.
  available,
}

class PrivateUpdateCheck {
  const PrivateUpdateCheck(
    this.status, {
    this.update,
    this.draftsVisible,
    this.skippedDrafts = 0,
    this.githubStatus,
    this.failure,
  });

  final PrivateUpdateStatus status;

  /// Why the endpoint gave no usable answer ([PrivateUpdateStatus.unavailable]
  /// only): `timeout`, `not_deployed` (HTTP 404), `http_<status>`,
  /// `network` or `bad_response`. Holds no server detail.
  final String? failure;
  final AppUpdateInfo? update;

  /// Private drafts the server could see on GitHub (admin diagnostics).
  final int? draftsVisible;

  /// Drafts without a verified installer for this platform.
  final int skippedDrafts;
  final int? githubStatus;

  /// The server answered without `drafts_visible`: it still runs the
  /// orvix-internal-update version from before the diagnostics were added.
  bool get legacyServer =>
      status == PrivateUpdateStatus.noNewerBuild && draftsVisible == null;

  /// The server confirmed this account as an Orvix admin.
  bool get authorized => switch (status) {
        PrivateUpdateStatus.serverUnconfigured ||
        PrivateUpdateStatus.githubUnavailable ||
        PrivateUpdateStatus.noNewerBuild ||
        PrivateUpdateStatus.available =>
          true,
        _ => false,
      };
}

/// Calls the private update endpoint. Throws [FunctionException] for a
/// non-2xx answer, like supabase_flutter's `functions.invoke`.
typedef InternalUpdateInvoker = Future<Object?> Function(
    Map<String, Object?> body);

class PrivateUpdateChannel {
  PrivateUpdateChannel({
    InternalUpdateInvoker? invoker,
    bool Function()? hasAccountSession,
    String? platform,
  })  : _invoker = invoker,
        _hasAccountSession = hasAccountSession,
        _platformOverride = platform;

  final InternalUpdateInvoker? _invoker;
  final bool Function()? _hasAccountSession;
  final String? _platformOverride;

  /// How long the private check waits. The Edge Function may cold-start and
  /// then lists releases on GitHub.
  @visibleForTesting
  static Duration checkTimeout = const Duration(seconds: 20);

  String? _platform() {
    final override = _platformOverride;
    if (override != null) return override;
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) {
      return PlatformProfile.isAndroidTv ? 'android_tv' : 'android_mobile';
    }
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios_modern';
    return null;
  }

  bool _signedIn() {
    final override = _hasAccountSession;
    if (override != null) return override();
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      // Supabase is not initialized (tests, or a build without accounts).
      return false;
    }
  }

  Future<Object?> _invoke(Map<String, Object?> body) async {
    final invoker = _invoker;
    if (invoker != null) return invoker(body);
    // supabase_flutter refreshes an expired access token before sending and
    // throws when that refresh fails.
    final response = await Supabase.instance.client.functions.invoke(
      'orvix-internal-update',
      body: body,
    );
    return response.data;
  }

  /// Error bodies normally arrive decoded; a non-JSON content type leaves
  /// them as text.
  static Object? _decodeDetails(Object? details) {
    if (details is! String) return details;
    try {
      return jsonDecode(details);
    } catch (_) {
      return details;
    }
  }

  static String? _errorCode(Object? details) =>
      details is Map ? details['error']?.toString() : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  /// Asks the owner-only private channel for a build newer than [installed].
  ///
  /// Authorization happens only on the server (Supabase session + admin
  /// allowlist); this client never decides it is an admin.
  Future<PrivateUpdateCheck> check(String installed) async {
    final platform = _platform();
    if (platform == null) {
      return const PrivateUpdateCheck(PrivateUpdateStatus.unsupportedPlatform);
    }
    if (!_signedIn()) {
      return const PrivateUpdateCheck(PrivateUpdateStatus.signedOut);
    }
    Object? data;
    try {
      data = await _invoke({'action': 'check', 'platform': platform})
          .timeout(checkTimeout);
    } on TimeoutException {
      return const PrivateUpdateCheck(PrivateUpdateStatus.unavailable,
          failure: 'timeout');
    } on FunctionException catch (error) {
      final details = _decodeDetails(error.details);
      final code = _errorCode(details);
      return switch (error.status) {
        401 => const PrivateUpdateCheck(PrivateUpdateStatus.sessionExpired),
        403 => const PrivateUpdateCheck(PrivateUpdateStatus.notEntitled),
        502 when code == 'github_unavailable' => PrivateUpdateCheck(
            PrivateUpdateStatus.githubUnavailable,
            githubStatus:
                details is Map ? _asInt(details['github_status']) : null,
          ),
        503 when code == 'internal_updates_unconfigured' =>
          const PrivateUpdateCheck(PrivateUpdateStatus.serverUnconfigured),
        404 => const PrivateUpdateCheck(PrivateUpdateStatus.unavailable,
            failure: 'not_deployed'),
        final status => PrivateUpdateCheck(PrivateUpdateStatus.unavailable,
            failure: 'http_$status'),
      };
    } on AuthException {
      // The stored session could not be refreshed.
      return const PrivateUpdateCheck(PrivateUpdateStatus.sessionExpired);
    } catch (_) {
      return const PrivateUpdateCheck(PrivateUpdateStatus.unavailable,
          failure: 'network');
    }

    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    if (data is! Map || data['releases'] is! List) {
      return const PrivateUpdateCheck(PrivateUpdateStatus.unavailable,
          failure: 'bad_response');
    }
    AppUpdateInfo? best;
    for (final item in data['releases'] as List) {
      if (item is! Map) continue;
      final version = item['version']?.toString() ?? '';
      final name = item['asset_name']?.toString() ?? '';
      final digest = item['sha256']?.toString() ?? '';
      final size = item['size_bytes'];
      if (version.isEmpty || name.isEmpty || digest.length != 64 ||
          RegExp(r'[^0-9a-f]').hasMatch(digest) ||
          size is! num || size <= 0 ||
          !ReleaseVersion.isNewer(version, installed)) {
        continue;
      }
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
        prerelease: true,
        internalVersion: version,
      );
      if (best == null || ReleaseVersion.isNewer(version, best.version)) {
        best = candidate;
      }
    }
    final skipped = data['skipped'];
    return PrivateUpdateCheck(
      best == null
          ? PrivateUpdateStatus.noNewerBuild
          : PrivateUpdateStatus.available,
      update: best,
      draftsVisible: _asInt(data['drafts_visible']),
      skippedDrafts: skipped is List ? skipped.length : 0,
    );
  }

  /// A short-lived signed URL for a private build. The download must match
  /// the checksum reported by [check].
  Future<String> signedDownloadUrl(AppUpdateInfo update) async {
    final platform = _platform();
    if (platform == null || !_signedIn()) {
      throw StateError('Sign in to your authorized Orvix account.');
    }
    Object? data;
    try {
      data = await _invoke({
        'action': 'download',
        'platform': platform,
        'version': update.internalVersion,
      }).timeout(const Duration(seconds: 15));
    } on FunctionException catch (error) {
      throw StateError(switch (error.status) {
        401 => 'Your Orvix session expired. Sign in again, then retry.',
        403 => 'This account is not authorized for this update.',
        404 => 'This private build is no longer available.',
        _ => 'Private update download is not available right now.',
      });
    } on AuthException {
      throw StateError('Your Orvix session expired. Sign in again, then retry.');
    }
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    if (data is! Map || data['url'] is! String) {
      throw StateError('Private update download is not available.');
    }
    if (data['sha256']?.toString() !=
        update.assetDigest?.replaceFirst('sha256:', '')) {
      throw StateError('Private update checksum metadata changed.');
    }
    final uri = Uri.tryParse(data['url'] as String);
    if (uri == null || uri.scheme != 'https') {
      throw StateError('Private update URL is invalid.');
    }
    return uri.toString();
  }
}
