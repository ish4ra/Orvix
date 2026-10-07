import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'platform_profile.dart';

/// Lightweight, privacy-conscious product telemetry for the private Orvix
/// Control Center.
///
/// The client never asks for location permission and never reads GPS data.
/// Country is resolved server-side from the network request and only the
/// two-letter country code is persisted. Raw IP addresses are not stored.
///
/// Telemetry is deliberately isolated from playback/source logic. Failures are
/// swallowed so analytics can never block startup, playback or navigation.
class OrvixTelemetryService with WidgetsBindingObserver {
  OrvixTelemetryService._();

  static final OrvixTelemetryService instance = OrvixTelemetryService._();

  static const _installationKey = 'orvix_analytics_installation_id_v1';
  static const _functionName = 'orvix-telemetry';
  static const _heartbeatInterval = Duration(seconds: 60);

  final Random _random = Random.secure();

  StreamSubscription<AuthState>? _authSubscription;
  Timer? _heartbeatTimer;
  String? _installationId;
  String? _sessionId;
  String? _appVersion;
  String? _buildNumber;
  String? _deviceManufacturer;
  String? _deviceModel;
  String? _deviceType;
  bool _initialized = false;
  bool _foreground = true;
  bool _ended = false;

  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;

    final preferences = await SharedPreferences.getInstance();
    var installationId = preferences.getString(_installationKey);
    if (installationId == null || installationId.isEmpty) {
      installationId = _uuidV4();
      await preferences.setString(_installationKey, installationId);
    }

    final package = await PackageInfo.fromPlatform();
    await _loadDeviceInfo();

    _installationId = installationId;
    _sessionId = _uuidV4();
    _appVersion = package.version;
    _buildNumber = package.buildNumber;
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _initialized = true;

    WidgetsBinding.instance.addObserver(this);
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      switch (state.event) {
        case AuthChangeEvent.signedIn:
          unawaited(track(
            'auth_signed_in',
            category: 'account',
          ));
          break;
        case AuthChangeEvent.signedOut:
          unawaited(track(
            'auth_signed_out',
            category: 'account',
          ));
          break;
        default:
          break;
      }
    });

    unawaited(_send(type: 'session_start'));
    if (_foreground) _startHeartbeat();
  }

  Future<void> track(
    String eventName, {
    String category = 'app',
    Map<String, Object?> properties = const {},
  }) async {
    if (!_initialized || _ended) return;
    await _send(
      type: 'event',
      extra: {
        'event_name': eventName,
        'event_category': category,
        'properties': properties,
      },
    );
  }

  Future<void> recordError({
    required String errorType,
    required String message,
    StackTrace? stack,
    bool fatal = false,
  }) async {
    if (!_initialized || _ended) return;
    await _send(
      type: 'error',
      extra: {
        'error_type': errorType,
        'message': message,
        if (stack != null) 'stack': stack.toString(),
        'fatal': fatal,
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized || _ended) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _startHeartbeat();
        unawaited(track('app_resumed'));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _foreground = false;
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        unawaited(_send(
          type: 'event',
          extra: {
            'event_name': 'app_backgrounded',
            'event_category': 'app',
          },
        ));
        break;
      case AppLifecycleState.detached:
        _foreground = false;
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        _ended = true;
        unawaited(_send(type: 'session_end', allowEnded: true));
        break;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_send(type: 'heartbeat')),
    );
  }

  Future<void> _send({
    required String type,
    Map<String, Object?> extra = const {},
    bool allowEnded = false,
  }) async {
    if (!_initialized || (_ended && !allowEnded)) return;

    final installationId = _installationId;
    final sessionId = _sessionId;
    final appVersion = _appVersion;
    if (installationId == null ||
        sessionId == null ||
        appVersion == null ||
        appVersion.isEmpty) {
      return;
    }

    final body = <String, Object?>{
      'type': type,
      'installation_id': installationId,
      'session_id': sessionId,
      'platform': _platformName(),
      'is_tv': PlatformProfile.isAndroidTv,
      'os_version': Platform.operatingSystemVersion,
      'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      'app_version': appVersion,
      'build_number': _buildNumber,
      'device_manufacturer': _deviceManufacturer,
      'device_model': _deviceModel,
      'device_type': _deviceType,
      'is_foreground': _foreground,
      ...extra,
    };

    try {
      await Supabase.instance.client.functions.invoke(
        _functionName,
        body: body,
      );
    } catch (_) {
      // Telemetry must never affect the app's primary behavior.
    }
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final plugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        _deviceManufacturer = _cleanDeviceValue(info.manufacturer);
        _deviceModel = _cleanDeviceValue(info.model);
        _deviceType = PlatformProfile.isAndroidTv ? 'TV' : 'Mobile';
        return;
      }

      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        _deviceManufacturer = 'Apple';
        _deviceModel = _cleanDeviceValue(info.utsname.machine);
        _deviceType = 'Mobile';
        return;
      }

      if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        _deviceManufacturer = 'Apple';
        _deviceModel = _cleanDeviceValue(info.model);
        _deviceType = 'Desktop';
        return;
      }

      if (Platform.isWindows || Platform.isLinux) {
        _deviceType = 'Desktop';
      }
    } catch (_) {
      // Missing device metadata must never block app startup or telemetry.
      _deviceManufacturer = null;
      _deviceModel = null;
      _deviceType ??= PlatformProfile.isAndroidTv
          ? 'TV'
          : (Platform.isAndroid || Platform.isIOS ? 'Mobile' : 'Desktop');
    }
  }

  String? _cleanDeviceValue(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null ||
        cleaned.isEmpty ||
        cleaned.toLowerCase() == 'unknown') {
      return null;
    }
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  String _platformName() {
    if (PlatformProfile.isAndroidTv) return 'Android TV';
    if (Platform.isAndroid) return 'Android Mobile';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
