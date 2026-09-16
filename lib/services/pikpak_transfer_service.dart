import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class PikPakTransferService {
  PikPakTransferService({
    http.Client? client,
    FlutterSecureStorage? storage,
  })  : _client = client ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  static const _clientId = 'YUMx5nI8ZU8Ap8pm';
  static const _clientVersion = '2.0.0';
  static const _packageName = 'mypikpak.com';
  static const _authBase = 'https://user.mypikpak.net';
  static const _driveBase = 'https://api-drive.mypikpak.com';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:129.0) Gecko/20100101 Firefox/129.0';

  static const _algorithms = <String>[
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

  Future<void> addResource(String resource, {String? name}) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'POST:/drive/v1/files',
      deviceId: session.deviceId,
      userId: session.userId,
    );

    final body = <String, dynamic>{
      'kind': 'drive#file',
      'params': const {'from': 'manual'},
      'upload_type': 'UPLOAD_TYPE_URL',
      'url': {'url': resource},
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    };

    final response = await _client
        .post(
          Uri.parse('$_driveBase/drive/v1/files'),
          headers: _driveHeaders(session, captcha),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PikPakTransferException(_extractError(response.body, response.statusCode));
    }
  }

  Future<String?> fetchPlayableUrl(String fileId) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'GET:/drive/v1/files/$fileId',
      deviceId: session.deviceId,
      userId: session.userId,
    );
    final uri = Uri.parse('$_driveBase/drive/v1/files/${Uri.encodeComponent(fileId)}')
        .replace(queryParameters: const {'usage': 'FETCH'});
    final response = await _client
        .get(uri, headers: _driveHeaders(session, captcha, contentType: false))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw PikPakTransferException(_extractError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final direct = decoded['web_content_link']?.toString();
    if (direct != null && direct.startsWith('http')) return direct;

    final medias = decoded['medias'];
    if (medias is List) {
      for (final media in medias.whereType<Map<String, dynamic>>()) {
        final link = media['link'];
        if (link is Map<String, dynamic>) {
          final url = link['url']?.toString();
          if (url != null && url.startsWith('http')) return url;
        }
        final url = media['url']?.toString();
        if (url != null && url.startsWith('http')) return url;
      }
    }

    final links = decoded['links'];
    if (links is Map<String, dynamic>) {
      for (final value in links.values) {
        if (value is Map<String, dynamic>) {
          final url = value['url']?.toString();
          if (url != null && url.startsWith('http')) return url;
        }
      }
    }
    return null;
  }

  Future<_Session> _session() async {
    final token = await _storage.read(key: 'pikpak_access_token');
    final deviceId = await _storage.read(key: 'pikpak_device_id');
    final userId = await _storage.read(key: 'pikpak_user_id');
    if (token == null || token.isEmpty || deviceId == null || deviceId.isEmpty) {
      throw const PikPakTransferException('Connect PikPak first.');
    }
    return _Session(token: token, deviceId: deviceId, userId: userId);
  }

  Map<String, String> _driveHeaders(
    _Session session,
    String captcha, {
    bool contentType = true,
  }) {
    return {
      if (contentType) 'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      'User-Agent': _userAgent,
      'Authorization': 'Bearer ${session.token}',
      'X-Device-ID': session.deviceId,
      'X-Captcha-Token': captcha,
    };
  }

  Future<String> _captcha({
    required String action,
    required String deviceId,
    String? userId,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    var sign = '$_clientId$_clientVersion$_packageName$deviceId$timestamp';
    for (final algorithm in _algorithms) {
      sign = md5.convert(utf8.encode(sign + algorithm)).toString();
    }

    final meta = <String, String>{
      'captcha_sign': '1.$sign',
      'client_id': _clientId,
      'client_version': _clientVersion,
      'device_id': deviceId,
      'package_name': _packageName,
      'timestamp': timestamp,
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
    };

    final response = await _client
        .post(
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
            'captcha_token': '',
            'client_id': _clientId,
            'device_id': deviceId,
            'meta': meta,
            'redirect_uri': 'xlaccsdk01://xbase.cloud/callback?state=harbor',
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw PikPakTransferException(_extractError(response.body, response.statusCode));
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const PikPakTransferException('Invalid PikPak captcha response.');
    }
    final url = decoded['url']?.toString();
    if (url != null && url.isNotEmpty) {
      throw const PikPakTransferException(
        'PikPak needs account verification before this operation.',
      );
    }
    final captcha = decoded['captcha_token']?.toString();
    if (captcha == null || captcha.isEmpty) {
      throw const PikPakTransferException('PikPak returned no captcha token.');
    }
    return captcha;
  }

  String _extractError(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        for (final key in const ['error_description', 'message', 'error', 'error_code']) {
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

class _Session {
  const _Session({required this.token, required this.deviceId, this.userId});
  final String token;
  final String deviceId;
  final String? userId;
}

class PikPakTransferException implements Exception {
  const PikPakTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}
