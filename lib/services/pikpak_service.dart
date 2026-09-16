import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class PikPakService {
  PikPakService({
    http.Client? client,
    FlutterSecureStorage? storage,
  })  : _client = client ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  static const _clientId = 'YUMx5nI8ZU8Ap8pm';
  static const _clientSecret = 'dbw2OtmVEeuUvIptb1Coygx';
  static const _clientVersion = '2.0.0';
  static const _packageName = 'mypikpak.com';
  static const _authBase = 'https://user.mypikpak.net';
  static const _tokenBase = 'https://user.mypikpak.com';
  static const _driveBase = 'https://api-drive.mypikpak.com';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:129.0) Gecko/20100101 Firefox/129.0';

  // Protocol constants used by PikPak's web captcha-sign flow.
  static const _captchaAlgorithms = <String>[
    'C9qPpZLN8ucRTaTiUMWYS9cQvWOE',
    '+r6CQVxjzJV6LCV',
    'F',
    'pFJRC',
    '9WXYIDGrwTCz2OiVlgZa90qpECPD6olt',
    '/750aCr4lm/Sly/c',
    'RB+DT/gZCrbV',
    '',
    'CyLsf7hdkIRxRm215hl',
    '7xHvLi2tOYP0Y92b',
    'ZGTXXxu8E/MIWaEDB+Sm/',
    '1UI3',
    'E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO',
    'ihtqpG6FMt65+Xk+tWUH2',
    'NhXXU9rg4XXdzo7u5o',
  ];

  final http.Client _client;
  final FlutterSecureStorage _storage;

  String? _pendingCaptchaToken;
  String? _pendingCaptchaUrl;
  String? _pendingUsername;
  DateTime? _pendingCaptchaExpiry;

  Future<bool> get isSignedIn async {
    final token = await _storage.read(key: 'pikpak_access_token');
    return token != null && token.isNotEmpty;
  }

  Future<String?> get signedInUsername =>
      _storage.read(key: 'pikpak_username');

  Future<PikPakLoginResult> login(String username, String password) async {
    final email = username.trim();
    if (email.isEmpty || password.isEmpty) {
      return const PikPakLoginResult.failure(
        'Enter your PikPak email/username and password.',
      );
    }

    final deviceId = await _ensureDeviceId();
    String? captchaToken;

    final pendingValid = _pendingCaptchaToken != null &&
        _pendingUsername == email &&
        (_pendingCaptchaExpiry?.isAfter(DateTime.now()) ?? false);

    if (pendingValid) {
      captchaToken = _pendingCaptchaToken;
    } else {
      final captcha = await _initCaptcha(
        action: 'POST:/v1/auth/signin',
        deviceId: deviceId,
        username: email,
      );
      captchaToken = captcha.token;
      _rememberPendingCaptcha(email, captcha);

      if (captcha.url != null && captcha.url!.isNotEmpty) {
        return PikPakLoginResult.verification(
          captcha.url!,
          'PikPak needs verification. Complete it, then press Sign in again.',
        );
      }
    }

    final response = await _client.post(
      Uri.parse('$_authBase/v1/auth/signin')
          .replace(queryParameters: const {'client_id': _clientId}),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'User-Agent': _userAgent,
        'X-Device-ID': deviceId,
        'X-Client-ID': _clientId,
        'X-Captcha-Token': captchaToken!,
      },
      body: jsonEncode({
        'captcha_token': captchaToken,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'username': email,
        'password': password,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      final message = _extractError(response.body, response.statusCode);
      final lowered = message.toLowerCase();
      if (lowered.contains('captcha') ||
          lowered.contains('verification') ||
          lowered.contains('verify')) {
        try {
          final captcha = await _initCaptcha(
            action: 'POST:/v1/auth/signin',
            deviceId: deviceId,
            username: email,
            oldToken: captchaToken,
          );
          _rememberPendingCaptcha(email, captcha);
          if (captcha.url != null && captcha.url!.isNotEmpty) {
            return PikPakLoginResult.verification(
              captcha.url!,
              'Complete PikPak verification, then press Sign in again.',
            );
          }
        } catch (_) {
          // Preserve the original server error below.
        }
      }
      return PikPakLoginResult.failure(message);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const PikPakLoginResult.failure('Invalid PikPak login response.');
    }

    final accessToken = decoded['access_token']?.toString();
    final refreshToken = decoded['refresh_token']?.toString();
    final userId = decoded['sub']?.toString();
    if (accessToken == null || accessToken.isEmpty || refreshToken == null) {
      return const PikPakLoginResult.failure(
        'PikPak did not return an access token.',
      );
    }

    await _storage.write(key: 'pikpak_access_token', value: accessToken);
    await _storage.write(key: 'pikpak_refresh_token', value: refreshToken);
    await _storage.write(key: 'pikpak_username', value: email);
    await _storage.write(key: 'pikpak_captcha_token', value: captchaToken);
    if (userId != null && userId.isNotEmpty) {
      await _storage.write(key: 'pikpak_user_id', value: userId);
    }

    _pendingCaptchaToken = null;
    _pendingCaptchaUrl = null;
    _pendingUsername = null;
    _pendingCaptchaExpiry = null;

    return const PikPakLoginResult.success('Connected to PikPak.');
  }

  Future<void> logout() async {
    for (final key in const [
      'pikpak_access_token',
      'pikpak_refresh_token',
      'pikpak_username',
      'pikpak_captcha_token',
      'pikpak_user_id',
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<List<PikPakFile>> listFiles({String parentId = ''}) async {
    var accessToken = await _storage.read(key: 'pikpak_access_token');
    if (accessToken == null || accessToken.isEmpty) {
      throw const PikPakException('Connect your PikPak account first.');
    }

    final deviceId = await _ensureDeviceId();
    final userId = await _storage.read(key: 'pikpak_user_id');
    final captcha = await _initCaptcha(
      action: 'GET:/drive/v1/files',
      deviceId: deviceId,
      userId: userId,
    );

    if (captcha.url != null && captcha.url!.isNotEmpty) {
      throw PikPakVerificationRequired(captcha.url!);
    }

    Future<http.Response> request(String token) {
      final uri = Uri.parse('$_driveBase/drive/v1/files').replace(
        queryParameters: {
          'thumbnail_size': 'SIZE_MEDIUM',
          'limit': '500',
          'with_audit': 'true',
          'parent_id': parentId,
        },
      );
      return _client.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': _userAgent,
          'Authorization': 'Bearer $token',
          'X-Device-ID': deviceId,
          'X-Captcha-Token': captcha.token,
        },
      ).timeout(const Duration(seconds: 30));
    }

    var response = await request(accessToken);
    if (response.statusCode == 401 && await refreshAccessToken()) {
      accessToken = await _storage.read(key: 'pikpak_access_token');
      if (accessToken != null) response = await request(accessToken);
    }

    if (response.statusCode != 200) {
      throw PikPakException(_extractError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final rawFiles = decoded['files'];
    if (rawFiles is! List) return const [];

    return rawFiles
        .whereType<Map<String, dynamic>>()
        .map(PikPakFile.fromJson)
        .toList(growable: false);
  }

  Future<bool> refreshAccessToken() async {
    final refreshToken = await _storage.read(key: 'pikpak_refresh_token');
    if (refreshToken == null || refreshToken.isEmpty) return false;

    final deviceId = await _ensureDeviceId();
    final captchaToken = await _storage.read(key: 'pikpak_captcha_token');

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': _userAgent,
      'X-Client-ID': _clientId,
      'X-Client-Version': _clientVersion,
      'X-Device-ID': deviceId,
    };
    if (captchaToken != null && captchaToken.isNotEmpty) {
      headers['X-Captcha-Token'] = captchaToken;
    }

    final response = await _client.post(
      Uri.parse('$_tokenBase/v1/auth/token')
          .replace(queryParameters: const {'client_id': _clientId}),
      headers: headers,
      body: jsonEncode({
        'client_id': _clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) return false;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return false;
    final newAccess = decoded['access_token']?.toString();
    if (newAccess == null || newAccess.isEmpty) return false;

    await _storage.write(key: 'pikpak_access_token', value: newAccess);
    final newRefresh = decoded['refresh_token']?.toString();
    if (newRefresh != null && newRefresh.isNotEmpty) {
      await _storage.write(key: 'pikpak_refresh_token', value: newRefresh);
    }
    final userId = decoded['sub']?.toString();
    if (userId != null && userId.isNotEmpty) {
      await _storage.write(key: 'pikpak_user_id', value: userId);
    }
    return true;
  }

  Future<_CaptchaResult> _initCaptcha({
    required String action,
    required String deviceId,
    String? username,
    String? userId,
    String oldToken = '',
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final sign = _captchaSign(deviceId, timestamp);

    final meta = <String, String>{
      'captcha_sign': sign,
      'client_id': _clientId,
      'client_version': _clientVersion,
      'device_id': deviceId,
      'package_name': _packageName,
      'timestamp': timestamp,
    };
    if (username != null && username.isNotEmpty) {
      meta['username'] = username;
    } else if (userId != null && userId.isNotEmpty) {
      meta['user_id'] = userId;
    }

    final response = await _client.post(
      Uri.parse('$_authBase/v1/shield/captcha/init')
          .replace(queryParameters: const {'client_id': _clientId}),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
        'X-Device-ID': deviceId,
        'X-Client-ID': _clientId,
      },
      body: jsonEncode({
        'action': action,
        'captcha_token': oldToken,
        'client_id': _clientId,
        'device_id': deviceId,
        'meta': meta,
        'redirect_uri': 'xlaccsdk01://xbase.cloud/callback?state=harbor',
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw PikPakException(_extractError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const PikPakException('Invalid PikPak captcha response.');
    }
    final token = decoded['captcha_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const PikPakException('PikPak returned no captcha token.');
    }

    return _CaptchaResult(
      token: token,
      url: decoded['url']?.toString(),
      expiresIn: int.tryParse(decoded['expires_in']?.toString() ?? '') ?? 300,
    );
  }

  void _rememberPendingCaptcha(String username, _CaptchaResult result) {
    _pendingUsername = username;
    _pendingCaptchaToken = result.token;
    _pendingCaptchaUrl = result.url;
    _pendingCaptchaExpiry = DateTime.now().add(
      Duration(seconds: result.expiresIn <= 0 ? 300 : result.expiresIn),
    );
  }

  String _captchaSign(String deviceId, String timestamp) {
    var value =
        '$_clientId$_clientVersion$_packageName$deviceId$timestamp';
    for (final algorithm in _captchaAlgorithms) {
      value = md5.convert(utf8.encode(value + algorithm)).toString();
    }
    return '1.$value';
  }

  Future<String> _ensureDeviceId() async {
    final existing = await _storage.read(key: 'pikpak_device_id');
    if (existing != null && existing.length == 32) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: 'pikpak_device_id', value: id);
    return id;
  }

  String _extractError(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        for (final key in const [
          'error_description',
          'message',
          'error',
          'error_code',
        ]) {
          final value = decoded[key];
          if (value != null && value.toString().trim().isNotEmpty) {
            return value.toString();
          }
        }
      }
    } catch (_) {}
    return 'PikPak request failed (HTTP $statusCode).';
  }

  void dispose() => _client.close();
}

class PikPakFile {
  const PikPakFile({
    required this.id,
    required this.name,
    required this.kind,
    this.size,
    this.mimeType,
    this.thumbnailLink,
    this.webContentLink,
  });

  final String id;
  final String name;
  final String kind;
  final String? size;
  final String? mimeType;
  final String? thumbnailLink;
  final String? webContentLink;

  bool get isFolder => kind.toLowerCase().contains('folder');

  factory PikPakFile.fromJson(Map<String, dynamic> json) {
    return PikPakFile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Untitled').toString(),
      kind: (json['kind'] ?? '').toString(),
      size: json['size']?.toString(),
      mimeType: json['mime_type']?.toString(),
      thumbnailLink: json['thumbnail_link']?.toString(),
      webContentLink: json['web_content_link']?.toString(),
    );
  }
}

class PikPakLoginResult {
  const PikPakLoginResult._({
    required this.ok,
    required this.message,
    this.verificationUrl,
  });

  const PikPakLoginResult.success(String message)
      : this._(ok: true, message: message);

  const PikPakLoginResult.failure(String message)
      : this._(ok: false, message: message);

  const PikPakLoginResult.verification(String url, String message)
      : this._(ok: false, message: message, verificationUrl: url);

  final bool ok;
  final String message;
  final String? verificationUrl;

  bool get needsVerification =>
      verificationUrl != null && verificationUrl!.isNotEmpty;
}

class PikPakException implements Exception {
  const PikPakException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PikPakVerificationRequired extends PikPakException {
  const PikPakVerificationRequired(this.url)
      : super('PikPak requires verification.');
  final String url;
}

class _CaptchaResult {
  const _CaptchaResult({
    required this.token,
    required this.url,
    required this.expiresIn,
  });

  final String token;
  final String? url;
  final int expiresIn;
}
