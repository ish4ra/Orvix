import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_factory.dart';
import 'package:http/http.dart' as http;

class PikPakTransferService {
  PikPakTransferService({
    http.Client? client,
    FlutterSecureStorage? storage,
  })  : _client = client ?? http.Client(),
        _storage = storage ?? createOrvixSecureStorage();

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

  static const _videoExtensions = <String>{
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'm4v',
    'webm',
    'ts',
    'm2ts',
    'mpg',
    'mpeg',
    'flv',
  };

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final Map<String, int> _zeroProgressPolls = <String, int>{};

  // Source-provider metadata is kept only in memory. It lets Orvix follow the
  // exact file selected by a Stremio-compatible addon after PikPak turns a
  // torrent into a folder/season pack.
  final Map<String, _TorrentSelection> _selectionByTaskId =
      <String, _TorrentSelection>{};
  final Map<String, _TorrentSelection> _selectionByFileId =
      <String, _TorrentSelection>{};

  Future<PikPakAddResult> addResource(
    String resource, {
    String? name,
    String? parentFolderId,
  }) async {
    final envelope = _extractResourceEnvelope(resource);
    final cleanResource = envelope.resource;
    final selection = envelope.selection;

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
    final isMagnet =
        cleanResource.trimLeft().toLowerCase().startsWith('magnet:');
    final body = <String, dynamic>{
      'kind': 'drive#file',
      'name': isMagnet ? '' : (name?.trim() ?? ''),
      'parent_id': parentFolderId ?? '',
      'upload_type': 'UPLOAD_TYPE_URL',
      'url': {'url': cleanResource},
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
    final cleanFileId = _nonEmpty(fileId);
    if (cleanTaskId != null) {
      _zeroProgressPolls.remove(cleanTaskId);
      if (selection != null) _selectionByTaskId[cleanTaskId] = selection;
    }
    if (cleanFileId != null && selection != null) {
      _selectionByFileId[cleanFileId] = selection;
    }

    return PikPakAddResult(
      taskId: cleanTaskId,
      fileId: cleanFileId,
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

    final selection = _selectionByTaskId[taskId];
    if (selection != null && status.fileId != null) {
      _selectionByFileId[status.fileId!] = selection;
    }

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

  Future<String?> fetchPlayableUrl(
    String fileId, {
    bool preferOriginal = false,
  }) async {
    final selection = _selectionByFileId[fileId];
    return _resolvePlayableUrl(
      fileId,
      selection: selection,
      visited: <String>{},
      preferOriginal: preferOriginal,
    );
  }

  Future<String?> _resolvePlayableUrl(
    String fileId, {
    required _TorrentSelection? selection,
    required Set<String> visited,
    required bool preferOriginal,
  }) async {
    if (!visited.add(fileId)) return null;

    final info = await _fetchFileInfo(fileId);
    if (info == null) return null;

    final direct = _selectMediaUrl(
      info,
      preferOriginal: preferOriginal,
    );
    if (direct != null) return direct;

    final kind = info['kind']?.toString().toLowerCase() ?? '';
    final isFolder = kind.contains('folder');
    if (!isFolder) {
      // For AI Sinhala, the provider's original/download URL is the only safe
      // fallback. A transcoded rendition may have already stripped embedded
      // subtitle tracks and its bytes cannot match the original moviehash.
      return _fallbackDownloadUrl(info);
    }

    final candidate = await _findPlayableDescendant(fileId, selection);
    if (candidate == null) return null;

    if (selection != null) {
      _selectionByFileId[candidate.id] = selection;
    }
    return _resolvePlayableUrl(
      candidate.id,
      selection: selection,
      visited: visited,
      preferOriginal: preferOriginal,
    );
  }

  Future<Map<String, dynamic>?> _fetchFileInfo(String fileId) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'GET:/drive/v1/files/$fileId',
      deviceId: session.deviceId,
      userId: session.userId,
    );
    final uri = Uri.parse(
      '$_driveBase/drive/v1/files/${Uri.encodeComponent(fileId)}',
    ).replace(
      queryParameters: const {
        'usage': 'FETCH',
        '_magic': '2021',
        'thumbnail_size': 'SIZE_LARGE',
        'with_audit': 'true',
      },
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
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Follow PikPak's own rendition choice. The provider's `is_default` media
  /// is the closest match to playback in the official client; forcing a lower
  /// transcode based on file size caused buffering regressions on large remuxes.
  String? _selectMediaUrl(
    Map<String, dynamic> decoded, {
    bool preferOriginal = false,
  }) {
    final medias = decoded['medias'];
    if (medias is! List || medias.isEmpty) return null;

    final entries = medias
        .whereType<Map<String, dynamic>>()
        .where((media) => _mediaUrl(media) != null)
        .where((media) => media['need_more_quota'] != true)
        .where((media) =>
            !media.containsKey('is_visible') || media['is_visible'] != false)
        .toList(growable: false);
    if (entries.isEmpty) return null;

    if (preferOriginal) {
      // AI Sinhala needs the provider's original container bytes. PikPak's
      // default rendition is frequently a transcoded MP4/HLS representation;
      // that representation can lose the MKV's embedded subtitle tracks and
      // will not have the original OpenSubtitles moviehash.
      for (final media in entries) {
        if (media['is_origin'] == true) return _mediaUrl(media);
      }
      return null;
    }

    // Normal playback keeps PikPak's provider-selected default rendition for
    // smoother playback on huge/high-bitrate originals.
    for (final media in entries) {
      if (media['is_default'] == true) return _mediaUrl(media);
    }
    for (final media in entries) {
      if (media['is_origin'] == true) return _mediaUrl(media);
    }
    return _mediaUrl(entries.first);
  }

  int _mediaHeight(Map<String, dynamic> media) {
    final video = media['video'];
    if (video is Map<String, dynamic>) {
      final height = _parseInt(video['height']);
      if (height != null && height > 0) return height;
    }

    final resolution = media['resolution_name']?.toString().toLowerCase() ?? '';
    if (resolution.contains('4k')) return 2160;
    final match = RegExp(r'(\d{3,4})p').firstMatch(resolution);
    if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
    return 0;
  }

  int _mediaBitRate(Map<String, dynamic> media) {
    final video = media['video'];
    if (video is Map<String, dynamic>) {
      return _parseInt(video['bit_rate']) ?? 0;
    }
    return 0;
  }

  String? _mediaUrl(Map<String, dynamic> media) {
    final link = media['link'];
    if (link is Map<String, dynamic>) {
      final url = link['url']?.toString();
      if (url != null && url.startsWith('http')) return url;
    }
    final url = media['url']?.toString();
    if (url != null && url.startsWith('http')) return url;
    return null;
  }

  String? _fallbackDownloadUrl(Map<String, dynamic> decoded) {
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

  Future<_CloudFile?> _findPlayableDescendant(
    String rootId,
    _TorrentSelection? selection,
  ) async {
    final folders = <String>[rootId];
    final candidates = <_CloudFile>[];
    var scanned = 0;

    while (folders.isNotEmpty && scanned < 2500) {
      final parentId = folders.removeAt(0);
      final children = await _listChildren(parentId);
      for (final raw in children) {
        scanned++;
        final file = _CloudFile.fromJson(raw);
        if (file.id.isEmpty) continue;
        if (file.isFolder) {
          if (folders.length < 250) folders.add(file.id);
          continue;
        }
        if (_looksLikeVideo(file)) candidates.add(file);
      }
    }

    if (candidates.isEmpty) return null;

    // Stremio specifies that if no torrent file index is provided the largest
    // video is the intended default. PikPak often mirrors the torrent's
    // original_file_index, so fileIdx can be matched directly when available.
    candidates.sort((a, b) {
      final score = _candidateScore(b, selection).compareTo(
        _candidateScore(a, selection),
      );
      if (score != 0) return score;
      return b.size.compareTo(a.size);
    });
    return candidates.first;
  }

  int _candidateScore(_CloudFile file, _TorrentSelection? selection) {
    var score = 0;
    if (selection == null) return file.size.clamp(0, 1 << 30);

    if (selection.fileIndex != null && file.originalFileIndex != null) {
      if (selection.fileIndex == file.originalFileIndex) {
        score += 1000000000;
      } else if ((selection.fileIndex! - file.originalFileIndex!).abs() == 1) {
        // Some third-party APIs have historically exposed one-based indexes.
        // This is only a weak fallback; filename/size can still override it.
        score += 5000;
      }
    }

    final expectedName = _normalizeFileName(selection.fileName);
    final actualName = _normalizeFileName(file.name);
    if (expectedName.isNotEmpty) {
      if (actualName == expectedName) {
        score += 500000000;
      } else if (actualName.contains(expectedName) || expectedName.contains(actualName)) {
        score += 100000000;
      }
    }

    if (selection.videoSize != null && selection.videoSize! > 0 && file.size > 0) {
      final expected = selection.videoSize!;
      final delta = (file.size - expected).abs();
      final ratio = delta / expected;
      if (ratio <= .01) {
        score += 300000000;
      } else if (ratio <= .05) {
        score += 50000000;
      }
    }

    // If the addon did not provide enough metadata, follow Stremio's default
    // torrent behavior and prefer the largest video within THIS task output.
    score += (file.size ~/ (1024 * 1024)).clamp(0, 1000000);
    return score;
  }

  Future<List<Map<String, dynamic>>> _listChildren(String parentId) async {
    final session = await _session();
    final captcha = await _captcha(
      action: 'GET:/drive/v1/files',
      deviceId: session.deviceId,
      userId: session.userId,
    );

    final out = <Map<String, dynamic>>[];
    String? pageToken;
    for (var page = 0; page < 8; page++) {
      final query = <String, String>{
        'parent_id': parentId,
        'thumbnail_size': 'SIZE_MEDIUM',
        'limit': '500',
        'with_audit': 'true',
        if (pageToken != null && pageToken!.isNotEmpty) 'page_token': pageToken!,
      };
      final uri = Uri.parse('$_driveBase/drive/v1/files').replace(
        queryParameters: query,
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
      if (decoded is! Map<String, dynamic>) break;
      final files = decoded['files'];
      if (files is List) {
        out.addAll(files.whereType<Map<String, dynamic>>());
      }
      pageToken = _nonEmpty(decoded['next_page_token']?.toString());
      if (pageToken == null) break;
    }
    return out;
  }

  bool _looksLikeVideo(_CloudFile file) {
    final mime = file.mimeType.toLowerCase().trim();
    if (mime.isNotEmpty) {
      if (mime.startsWith('video/')) return true;
      if (!mime.contains('octet-stream')) return false;
    }
    final lower = file.name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0 || dot == lower.length - 1) return true;
    return _videoExtensions.contains(lower.substring(dot + 1));
  }

  _ResourceEnvelope _extractResourceEnvelope(String resource) {
    final trimmed = resource.trim();
    if (!trimmed.toLowerCase().startsWith('magnet:')) {
      return _ResourceEnvelope(resource: trimmed);
    }

    try {
      final question = trimmed.indexOf('?');
      if (question < 0 || question == trimmed.length - 1) {
        throw const PikPakTransferException(
          'Invalid magnet source returned by provider.',
        );
      }

      final rawParts = trimmed.substring(question + 1)
          .split('&')
          .where((part) => part.trim().isNotEmpty)
          .toList(growable: false);

      int? fileIndex;
      String? fileName;
      int? videoSize;
      String? videoHash;
      String? infoHash;
      final cleanParts = <String>[];

      for (final part in rawParts) {
        final equals = part.indexOf('=');
        final rawKey = equals < 0 ? part : part.substring(0, equals);
        final rawValue = equals < 0 ? '' : part.substring(equals + 1);
        final key = Uri.decodeQueryComponent(rawKey).toLowerCase();
        final value = Uri.decodeQueryComponent(rawValue);

        switch (key) {
          case 'x-orvix-file-idx':
          case 'x-pikora-file-idx':
            fileIndex ??= _parseInt(value);
            continue;
          case 'x-orvix-file-name':
          case 'x-pikora-file-name':
            fileName ??= _nonEmpty(value);
            continue;
          case 'x-orvix-video-size':
          case 'x-pikora-video-size':
            videoSize ??= _parseInt(value);
            continue;
          case 'x-orvix-video-hash':
          case 'x-pikora-video-hash':
            final cleanHash = value.trim().toLowerCase();
            if (RegExp(r'^[0-9a-f]{16}        }

        if (key == 'xt') {
          final lower = value.toLowerCase();
          if (lower.startsWith('urn:btih:')) {
            final hash = value.substring('urn:btih:'.length).trim();
            final valid = RegExp(
              r'^(?:[A-Fa-f0-9]{40}|[A-Za-z2-7]{32}|[A-Fa-f0-9]{64})$',
            ).hasMatch(hash);
            if (valid) infoHash = hash;
          }
        }

        cleanParts.add(part);
      }

      if (infoHash == null) {
        throw const PikPakTransferException(
          'Invalid magnet source: no usable BTIH hash was returned. Choose another source.',
        );
      }

      final clean = 'magnet:?${cleanParts.join('&')}';
      final selection = fileIndex == null &&
              fileName == null &&
              videoSize == null &&
              videoHash == null
          ? null
          : _TorrentSelection(
              fileIndex: fileIndex,
              fileName: fileName,
              videoSize: videoSize,
              videoHash: videoHash,
            );
      return _ResourceEnvelope(resource: clean, selection: selection);
    } on PikPakTransferException {
      rethrow;
    } catch (_) {
      throw const PikPakTransferException(
        'Invalid magnet source returned by provider. Choose another source.',
      );
    }
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

  int? _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  String _normalizeFileName(String? value) {
    if (value == null || value.trim().isEmpty) return '';
    final base = value.replaceAll('\\', '/').split('/').last;
    return base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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

class _TorrentSelection {
  const _TorrentSelection({
    this.fileIndex,
    this.fileName,
    this.videoSize,
    this.videoHash,
  });
  final int? fileIndex;
  final String? fileName;
  final int? videoSize;
  final String? videoHash;
}

class _ResourceEnvelope {
  const _ResourceEnvelope({required this.resource, this.selection});
  final String resource;
  final _TorrentSelection? selection;
}

class _CloudFile {
  const _CloudFile({
    required this.id,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.size,
    this.originalFileIndex,
  });

  final String id;
  final String name;
  final String kind;
  final String mimeType;
  final int size;
  final int? originalFileIndex;

  bool get isFolder => kind.toLowerCase().contains('folder');

  factory _CloudFile.fromJson(Map<String, dynamic> json) {
    int? parseInt(dynamic raw) {
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    }

    return _CloudFile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      size: parseInt(json['size']) ?? 0,
      originalFileIndex: parseInt(json['original_file_index']),
    );
  }
}

class PikPakTransferException implements Exception {
  const PikPakTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}
).hasMatch(cleanHash)) {
              videoHash ??= cleanHash;
            }
            continue;
        }

        if (key == 'xt') {
          final lower = value.toLowerCase();
          if (lower.startsWith('urn:btih:')) {
            final hash = value.substring('urn:btih:'.length).trim();
            final valid = RegExp(
              r'^(?:[A-Fa-f0-9]{40}|[A-Za-z2-7]{32}|[A-Fa-f0-9]{64})$',
            ).hasMatch(hash);
            if (valid) infoHash = hash;
          }
        }

        cleanParts.add(part);
      }

      if (infoHash == null) {
        throw const PikPakTransferException(
          'Invalid magnet source: no usable BTIH hash was returned. Choose another source.',
        );
      }

      final clean = 'magnet:?${cleanParts.join('&')}';
      final selection = fileIndex == null && fileName == null && videoSize == null
          ? null
          : _TorrentSelection(
              fileIndex: fileIndex,
              fileName: fileName,
              videoSize: videoSize,
            );
      return _ResourceEnvelope(resource: clean, selection: selection);
    } on PikPakTransferException {
      rethrow;
    } catch (_) {
      throw const PikPakTransferException(
        'Invalid magnet source returned by provider. Choose another source.',
      );
    }
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

  int? _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  String _normalizeFileName(String? value) {
    if (value == null || value.trim().isEmpty) return '';
    final base = value.replaceAll('\\', '/').split('/').last;
    return base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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

class _TorrentSelection {
  const _TorrentSelection({this.fileIndex, this.fileName, this.videoSize});
  final int? fileIndex;
  final String? fileName;
  final int? videoSize;
}

class _ResourceEnvelope {
  const _ResourceEnvelope({required this.resource, this.selection});
  final String resource;
  final _TorrentSelection? selection;
}

class _CloudFile {
  const _CloudFile({
    required this.id,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.size,
    this.originalFileIndex,
  });

  final String id;
  final String name;
  final String kind;
  final String mimeType;
  final int size;
  final int? originalFileIndex;

  bool get isFolder => kind.toLowerCase().contains('folder');

  factory _CloudFile.fromJson(Map<String, dynamic> json) {
    int? parseInt(dynamic raw) {
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    }

    return _CloudFile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      size: parseInt(json['size']) ?? 0,
      originalFileIndex: parseInt(json['original_file_index']),
    );
  }
}

class PikPakTransferException implements Exception {
  const PikPakTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}
