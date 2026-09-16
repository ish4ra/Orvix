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
  final Map<String, int> _zeroProgressPolls = <String, int>{};

  Future<PikPakAddResult> addResource(
    String resource, {
    String? name,
    String? parentFolderId,
  }) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'POST:/drive/v1/files',
      deviceId: session.deviceId,
      userId: session.userId,
    );

    // Keep this payload close to PikPak's web/offline-download flow. In
    // particular, parent_id and folder_type are significant for URL/magnet
    // tasks. For magnet resources we deliberately let PikPak obtain the real
    // torrent/folder name from metadata instead of forcing the catalog title.
    final isMagnet = resource.trimLeft().toLowerCase().startsWith('magnet:');
    final body = <String, dynamic>{
      'kind': 'drive#file',
      'name': isMagnet ? '' : (name?.trim() ?? ''),
      'parent_id': parentFolderId ?? '',
      'upload_type': 'UPLOAD_TYPE_URL',
      'url': {'url': resource},
      'folder_type': '',
    };

    final response = await _client
        .post(
          Uri.parse('$_driveBase/drive/v1/files'),
          headers: _driveHeaders(session, captcha),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PikPakTransferException(
        _extractError(response.body, response.statusCode),
      );
    }

    Map<String, dynamic> decoded = const {};
    try {
      final raw = jsonDecode(response.body);
      if (raw is Map<String, dynamic>) decoded = raw;
    } catch (_) {}

    String? taskId;
    String? fileId;
    final task = decoded['task'];
    if (task is Map<String, dynamic>) {
      taskId = task['id']?.toString();
      fileId = task['file_id']?.toString();
    }
    final file = decoded['file'];
    if ((fileId == null || fileId.isEmpty) && file is Map<String, dynamic>) {
      fileId = file['id']?.toString();
    }
    if (fileId == null || fileId.isEmpty) {
      fileId = decoded['id']?.toString();
    }

    final cleanTaskId = _nonEmpty(taskId);
    if (cleanTaskId != null) _zeroProgressPolls.remove(cleanTaskId);

    return PikPakAddResult(
      taskId: cleanTaskId,
      fileId: _nonEmpty(fileId),
    );
  }

  Future<PikPakTaskStatus> getTaskStatus(String taskId) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'GET:/drive/v1/tasks',
      deviceId: session.deviceId,
      userId: session.userId,
    );
    final uri = Uri.parse(
      '$_driveBase/drive/v1/tasks/${Uri.encodeComponent(taskId)}',
    );
    final response = await _client
        .get(
          uri,
          headers: _driveHeaders(session, captcha, contentType: false),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw PikPakTransferException(
        _extractError(response.body, response.statusCode),
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const PikPakTransferException('Invalid PikPak task response.');
    }

    final status = PikPakTaskStatus(
      taskId: taskId,
      phase: decoded['phase']?.toString() ?? '',
      progress: _parseProgress(decoded['progress']),
      fileId: _nonEmpty(decoded['file_id']?.toString()),
      message: decoded['message']?.toString() ?? decoded['error']?.toString(),
    );

    if (status.isComplete || status.isError || status.progress > 0) {
      _zeroProgressPolls.remove(taskId);
    } else {
      final checks = (_zeroProgressPolls[taskId] ?? 0) + 1;
      _zeroProgressPolls[taskId] = checks;

      if (checks >= 15) {
        _zeroProgressPolls.remove(taskId);
        throw const PikPakTransferException(
          'PikPak accepted this source but it has stayed at 0% for about 30 seconds. '
          'The source may have no active peers or may be temporarily unavailable. '
          'Choose another source and try again.',
        );
      }
    }

    return status;
  }

  Future<String?> fetchPlayableUrl(String fileId) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'GET:/drive/v1/files/$fileId',
      deviceId: session.deviceId,
      userId: session.userId,
    );
    final uri = Uri.parse(
      '$_driveBase/drive/v1/files/${Uri.encodeComponent(fileId)}',
    ).replace(queryParameters: const {'usage': 'FETCH'});
    final response = await _client
        .get(
          uri,
          headers: _driveHeaders(session, captcha, contentType: false),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw PikPakTransferException(
        _extractError(response.body, response.statusCode),
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    // For video playback, PikPak's media entries are the streaming-optimized
    // path. Prefer the default rendition, then the origin rendition, then the
    // first usable media. web_content_link remains a download-style fallback.
    final medias = decoded['medias'];
    if (medias is List && medias.isNotEmpty) {
      final entries = medias.whereType<Map<String, dynamic>>().toList();
      Map<String, dynamic>? selected;
      for (final media in entries) {
        if (media['is_default'] == true) {
          selected = media;
          break;
        }
      }
      if (selected == null) {
        for (final media in entries) {
          if (media['is_origin'] == true) {
            selected = media;
            break;
          }
        }
      }

      final ordered = <Map<String, dynamic>>[
        if (selected != null) selected,
        ...entries.where((media) => !identical(media, selected)),
      ];
      for (final media in ordered) {
        final link = media['link'];
        if (link is Map<String, dynamic>) {
          final url = link['url']?.toString();
          if (url != null && url.startsWith('http')) return url;
        }
        final url = media['url']?.toString();
        if (url != null && url.startsWith('http')) return url;
      }
    }

    final direct = decoded['web_content_link']?.toString();
    if (direct != null && direct.startsWith('http')) return direct;

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
    if (token == null ||
        token.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
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
      'X-Client-ID': _clientId,
      'X-Client-Version': _clientVersion,
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
      throw PikPakTransferException(
        _extractError(response.body, response.statusCode),
      );
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

  double _parseProgress(dynamic raw) {
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '') ?? 0;
    if (value <= 1 && value > 0) {
      return (value * 100).clamp(0, 100).toDouble();
    }
    return value.clamp(0, 100).toDouble();
  }

  String? _nonEmpty(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
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

class PikPakAddResult {
  const PikPakAddResult({this.taskId, this.fileId});
  final String? taskId;
  final String? fileId;
}

class PikPakTaskStatus {
  const PikPakTaskStatus({
    required this.taskId,
    required this.phase,
    required this.progress,
    this.fileId,
    this.message,
  });

  final String taskId;
  final String phase;
  final double progress;
  final String? fileId;
  final String? message;

  bool get isComplete => phase == 'PHASE_TYPE_COMPLETE';
  bool get isError => phase == 'PHASE_TYPE_ERROR';
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
