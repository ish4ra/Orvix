import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_factory.dart';
import 'package:http/http.dart' as http;

class TorBoxException implements Exception {
  const TorBoxException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TorBoxDeviceAuthorization {
  const TorBoxDeviceAuthorization({
    required this.deviceCode,
    required this.code,
    required this.verificationUrl,
    required this.friendlyVerificationUrl,
    required this.intervalSeconds,
    this.expiresAt,
  });

  final String deviceCode;
  final String code;
  final String verificationUrl;
  final String friendlyVerificationUrl;
  final int intervalSeconds;
  final DateTime? expiresAt;
}

class TorBoxAccount {
  const TorBoxAccount({this.email, this.plan, this.raw = const {}});
  final String? email;
  final String? plan;
  final Map<String, dynamic> raw;
}

enum TorBoxTransferKind { torrent, webDownload }

class TorBoxAddResult {
  const TorBoxAddResult({required this.kind, required this.id});
  final TorBoxTransferKind kind;
  final int id;
}

class TorBoxFile {
  const TorBoxFile({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType,
    this.path,
  });
  final int id;
  final String name;
  final int size;
  final String? mimeType;

  /// TorBox often exposes a short display name and a separate full torrent
  /// path. Preserve both: a generic subtitle name such as "English.srt" is
  /// ambiguous by itself, while its parent path may identify S01E01 exactly.
  final String? path;

  String get identityPath {
    final full = path?.trim();
    return full == null || full.isEmpty ? name : full;
  }

  bool get isVideo {
    final mime = mimeType?.toLowerCase() ?? '';
    if (mime.startsWith('video/')) return true;
    final lower = name.toLowerCase();
    return const ['.mkv', '.mp4', '.m4v', '.avi', '.mov', '.webm', '.ts', '.m2ts']
        .any(lower.endsWith);
  }

  bool get isTextSubtitle {
    final lower = identityPath.toLowerCase();
    return const ['.srt', '.ass', '.ssa', '.vtt']
        .any(lower.endsWith);
  }
}

class TorBoxSubtitleCandidate {
  const TorBoxSubtitleCandidate({
    required this.file,
    required this.score,
    required this.reason,
  });

  final TorBoxFile file;
  final int score;
  final String reason;
}

class TorBoxItem {
  const TorBoxItem({
    required this.id,
    required this.name,
    required this.progress,
    required this.size,
    required this.state,
    required this.cached,
    required this.downloadFinished,
    required this.files,
    required this.kind,
  });

  final int id;
  final String name;
  final double progress;
  final int size;
  final String state;
  final bool cached;
  final bool downloadFinished;
  final List<TorBoxFile> files;
  final TorBoxTransferKind kind;

  bool get isReady => cached || downloadFinished || progress >= 100;
  bool get isError {
    final s = state.toLowerCase();
    return s.contains('fail') || s.contains('error') || s.contains('stalled');
  }
}

class TorBoxService {
  TorBoxService({http.Client? client, FlutterSecureStorage? storage})
      : _client = client ?? http.Client(),
        _storage = storage ?? createOrvixSecureStorage();

  static const _base = 'https://api.torbox.app/v1/api';
  static const _tokenKey = 'orvix_torbox_api_token_v1';
  final http.Client _client;
  final FlutterSecureStorage _storage;

  Future<bool> get isConnected async => (await _token()) != null;

  Future<void> connectWithApiKey(String raw) async {
    final token = raw.trim();
    if (token.isEmpty) throw const TorBoxException('Enter your TorBox API key.');
    final account = await _fetchAccount(token);
    if (account.raw.isEmpty) throw const TorBoxException('TorBox rejected this API key.');
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<TorBoxDeviceAuthorization> startDeviceAuthorization() async {
    final uri = Uri.parse('$_base/user/auth/device/start').replace(
      queryParameters: const {'app': 'Orvix'},
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 25));
    final data = _unwrap(response);
    if (data is! Map<String, dynamic>) {
      throw const TorBoxException('TorBox returned an invalid device-login response.');
    }
    return TorBoxDeviceAuthorization(
      deviceCode: data['device_code']?.toString() ?? '',
      code: data['code']?.toString() ?? '',
      verificationUrl: data['verification_url']?.toString() ?? 'https://torbox.app',
      friendlyVerificationUrl:
          data['friendly_verification_url']?.toString() ?? 'https://tor.box/link',
      intervalSeconds: _int(data['interval'])?.clamp(2, 30) ?? 5,
      expiresAt: DateTime.tryParse(data['expires_at']?.toString() ?? ''),
    );
  }

  Future<bool> redeemDeviceAuthorization(String deviceCode) async {
    final response = await _client
        .post(
          Uri.parse('$_base/user/auth/device/token'),
          headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({'device_code': deviceCode}),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 400 || response.statusCode == 404) return false;
    final data = _unwrap(response);
    if (data is! Map<String, dynamic>) return false;
    final token = (data['access_token'] ?? data['token'])?.toString().trim();
    if (token == null || token.isEmpty) return false;
    await _storage.write(key: _tokenKey, value: token);
    return true;
  }

  Future<TorBoxAccount> account() async {
    final token = await _requireToken();
    return _fetchAccount(token);
  }

  Future<TorBoxAccount> _fetchAccount(String token) async {
    final response = await _client
        .get(Uri.parse('$_base/user/me?settings=false'), headers: _headers(token))
        .timeout(const Duration(seconds: 25));
    final raw = _unwrap(response);
    if (raw is! Map<String, dynamic>) {
      throw const TorBoxException('Could not read TorBox account data.');
    }
    final email = _firstString(raw, ['email', 'username']);
    String? plan;
    final planRaw = raw['plan'];
    if (planRaw is Map) {
      plan = _firstString(Map<String, dynamic>.from(planRaw), ['name', 'plan_name']);
    } else {
      plan = planRaw?.toString();
    }
    return TorBoxAccount(email: email, plan: plan, raw: raw);
  }

  Future<List<TorBoxItem>> listTorrents({bool fresh = false}) async {
    final token = await _requireToken();
    final uri = Uri.parse('$_base/torrents/mylist').replace(queryParameters: {
      'bypass_cache': fresh ? 'true' : 'false',
      'limit': '1000',
    });
    final response = await _client.get(uri, headers: _headers(token)).timeout(const Duration(seconds: 30));
    final data = _unwrap(response);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((e) => _parseItem(Map<String, dynamic>.from(e), TorBoxTransferKind.torrent))
        .toList(growable: false);
  }

  Future<List<TorBoxItem>> listWebDownloads({bool fresh = false}) async {
    final token = await _requireToken();
    final uri = Uri.parse('$_base/webdl/mylist').replace(queryParameters: {
      'bypass_cache': fresh ? 'true' : 'false',
      'limit': '1000',
    });
    final response = await _client.get(uri, headers: _headers(token)).timeout(const Duration(seconds: 30));
    final data = _unwrap(response);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((e) => _parseItem(Map<String, dynamic>.from(e), TorBoxTransferKind.webDownload))
        .toList(growable: false);
  }

  Future<TorBoxItem?> getItem(TorBoxTransferKind kind, int id, {bool fresh = true}) async {
    final token = await _requireToken();
    final scope = kind == TorBoxTransferKind.torrent ? 'torrents' : 'webdl';
    final uri = Uri.parse('$_base/$scope/mylist').replace(queryParameters: {
      'id': '$id',
      'bypass_cache': fresh ? 'true' : 'false',
    });
    final response = await _client.get(uri, headers: _headers(token)).timeout(const Duration(seconds: 30));
    final data = _unwrap(response);
    if (data is Map) return _parseItem(Map<String, dynamic>.from(data), kind);
    if (data is List && data.isNotEmpty && data.first is Map) {
      return _parseItem(Map<String, dynamic>.from(data.first as Map), kind);
    }
    return null;
  }

  Future<TorBoxAddResult> addResource(String resource, {String? name}) async {
    final token = await _requireToken();
    final clean = _stripOrvixMetadata(resource);
    if (clean.toLowerCase().startsWith('magnet:')) {
      final request = http.MultipartRequest('POST', Uri.parse('$_base/torrents/createtorrent'))
        ..headers.addAll(_headers(token, json: false))
        ..fields['magnet'] = clean
        ..fields['seed'] = '1'
        ..fields['allow_zip'] = 'false'
        ..fields['as_queued'] = 'false';
      if (name?.trim().isNotEmpty == true) request.fields['name'] = name!.trim();
      final response = await http.Response.fromStream(await request.send()).timeout(const Duration(seconds: 45));
      final data = _unwrap(response);
      if (data is! Map) throw const TorBoxException('TorBox did not return a torrent id.');
      final id = _int(data['torrent_id'] ?? data['id']);
      if (id == null) throw const TorBoxException('TorBox did not return a torrent id.');
      return TorBoxAddResult(kind: TorBoxTransferKind.torrent, id: id);
    }

    final uri = Uri.tryParse(clean);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const TorBoxException('TorBox can add a magnet or a direct HTTP/HTTPS link.');
    }
    final request = http.MultipartRequest('POST', Uri.parse('$_base/webdl/createwebdownload'))
      ..headers.addAll(_headers(token, json: false))
      ..fields['link'] = clean
      ..fields['as_queued'] = 'false';
    if (name?.trim().isNotEmpty == true) request.fields['name'] = name!.trim();
    final response = await http.Response.fromStream(await request.send()).timeout(const Duration(seconds: 45));
    final data = _unwrap(response);
    if (data is! Map) throw const TorBoxException('TorBox did not return a web-download id.');
    final id = _int(data['webdownload_id'] ?? data['web_id'] ?? data['id']);
    if (id == null) throw const TorBoxException('TorBox did not return a web-download id.');
    return TorBoxAddResult(kind: TorBoxTransferKind.webDownload, id: id);
  }

  TorBoxFile? choosePlayableFile(
    TorBoxItem item, {
    String? fileNameHint,
    int? fileIndex,
  }) {
    final videos = item.files.where((f) => f.isVideo).toList();
    if (videos.isEmpty) return null;
    final hint = fileNameHint?.trim().toLowerCase();
    if (hint != null && hint.isNotEmpty) {
      for (final file in videos) {
        final lower = file.name.toLowerCase();
        if (lower == hint || lower.endsWith('/$hint') || lower.contains(hint)) return file;
      }
    }
    if (fileIndex != null && fileIndex >= 0 && fileIndex < item.files.length) {
      final candidate = item.files[fileIndex];
      if (candidate.isVideo) return candidate;
    }
    videos.sort((a, b) => b.size.compareTo(a.size));
    return videos.first;
  }

  /// Rank text subtitle files that live inside the *same TorBox torrent* as
  /// the selected video. This never searches another release.
  ///
  /// TV packs are deliberately strict: an explicit SxxEyy/NxEE mismatch is
  /// rejected. A generic subtitle filename is accepted only when it is in the
  /// same torrent directory as the selected video and that directory contains
  /// exactly one video, or when its release-name tokens strongly match.
  static List<TorBoxSubtitleCandidate> rankSubtitleCandidatesForVideo(
    TorBoxItem item,
    TorBoxFile video, {
    int? season,
    int? episode,
  }) {
    final subtitles = item.files.where((file) => file.isTextSubtitle).toList();
    if (subtitles.isEmpty) return const <TorBoxSubtitleCandidate>[];

    final videoIdentity = _normalizePath(video.identityPath);
    final videoDirectory = _directoryOf(videoIdentity);
    final sameDirectoryVideoCount = item.files
        .where((file) =>
            file.isVideo &&
            _directoryOf(_normalizePath(file.identityPath)) == videoDirectory)
        .length;

    final requestedEpisode =
        season != null && episode != null ? 's$season-e$episode' : null;
    final videoEpisode = _episodeKey(videoIdentity);
    final targetEpisode = requestedEpisode ?? videoEpisode;
    final videoTokens = _releaseTokens(videoIdentity);

    final ranked = <TorBoxSubtitleCandidate>[];
    for (final subtitle in subtitles) {
      final identity = _normalizePath(subtitle.identityPath);
      final subtitleEpisode = _episodeKey(identity);
      final subtitleDirectory = _directoryOf(identity);
      final sameDirectory = subtitleDirectory == videoDirectory;
      final subtitleTokens = _releaseTokens(identity);

      if (targetEpisode != null &&
          subtitleEpisode != null &&
          subtitleEpisode != targetEpisode) {
        continue;
      }
      if (targetEpisode == null && subtitleEpisode != null) {
        continue;
      }

      final overlap = subtitleTokens.intersection(videoTokens).length;
      final shorter = subtitleTokens.length < videoTokens.length
          ? subtitleTokens.length
          : videoTokens.length;
      final ratio = shorter == 0 ? 0.0 : overlap / shorter;

      var score = 0;
      final reasons = <String>[];

      if (targetEpisode != null && subtitleEpisode == targetEpisode) {
        score += 1200;
        reasons.add('exact-episode');
      }

      if (sameDirectory) {
        score += 180;
        reasons.add('same-directory');
        if (sameDirectoryVideoCount == 1) {
          score += 650;
          reasons.add('single-video-directory');
        }
      }

      if (overlap >= 2) {
        score += overlap * 55;
        score += (ratio * 260).round();
        reasons.add('release-token-overlap=$overlap');
      }

      final lower = identity.toLowerCase();
      if (RegExp(r'(^|[^a-z])(eng|english)([^a-z]|$)').hasMatch(lower)) {
        score += 100;
        reasons.add('english-name');
      }

      if (targetEpisode != null && subtitleEpisode == null) {
        final safeByDirectory = sameDirectory && sameDirectoryVideoCount == 1;
        final safeByStem = overlap >= 3 && ratio >= .55;
        if (!safeByDirectory && !safeByStem) continue;
      }

      if (targetEpisode == null) {
        final safeByDirectory = sameDirectory && sameDirectoryVideoCount == 1;
        final safeByStem = overlap >= 3 && ratio >= .55;
        if (!safeByDirectory && !safeByStem) continue;
      }

      if (score <= 0) continue;
      ranked.add(
        TorBoxSubtitleCandidate(
          file: subtitle,
          score: score,
          reason: reasons.join(','),
        ),
      );
    }

    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  static String _normalizePath(String raw) =>
      raw.replaceAll('\\', '/').trim().toLowerCase();

  static String _directoryOf(String normalizedPath) {
    final slash = normalizedPath.lastIndexOf('/');
    return slash <= 0 ? '' : normalizedPath.substring(0, slash);
  }

  static String? _episodeKey(String raw) {
    final standard =
        RegExp(r's(\d{1,2})[ ._-]*e(\d{1,3})', caseSensitive: false)
            .firstMatch(raw);
    if (standard != null) {
      final season = int.tryParse(standard.group(1) ?? '');
      final episode = int.tryParse(standard.group(2) ?? '');
      if (season != null && episode != null) return 's$season-e$episode';
    }

    final compact =
        RegExp(r'(^|[^0-9])(\d{1,2})x(\d{1,3})([^0-9]|$)')
            .firstMatch(raw);
    if (compact != null) {
      final season = int.tryParse(compact.group(2) ?? '');
      final episode = int.tryParse(compact.group(3) ?? '');
      if (season != null && episode != null) return 's$season-e$episode';
    }
    return null;
  }

  static Set<String> _releaseTokens(String raw) {
    final clean = raw
        .replaceAll(
          RegExp(
            r'\.(?:srt|ass|ssa|vtt|mkv|mp4|m4v|avi|mov|webm|ts|m2ts)$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    const noise = <String>{
      'en',
      'eng',
      'english',
      'sub',
      'subs',
      'subtitle',
      'subtitles',
      'sdh',
      'cc',
      'hi',
      'forced',
      'default',
    };
    return clean
        .split(RegExp(r'\s+'))
        .where((token) => token.length >= 2 && !noise.contains(token))
        .toSet();
  }

  Future<String> requestDownloadUrl(TorBoxItem item, TorBoxFile file) async {
    final token = await _requireToken();
    final scope = item.kind == TorBoxTransferKind.torrent ? 'torrents' : 'webdl';
    final idKey = item.kind == TorBoxTransferKind.torrent ? 'torrent_id' : 'web_id';
    final uri = Uri.parse('$_base/$scope/requestdl').replace(queryParameters: {
      'token': token,
      idKey: '${item.id}',
      'file_id': '${file.id}',
      'redirect': 'false',
      'append_name': 'true',
    });
    final response = await _client.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 30));
    final data = _unwrap(response);
    final url = data?.toString();
    if (url == null || !url.startsWith('http')) {
      throw const TorBoxException('TorBox did not return a playable download URL.');
    }
    return url;
  }

  Future<void> logout() => _storage.delete(key: _tokenKey);
  void dispose() => _client.close();

  TorBoxItem _parseItem(Map<String, dynamic> raw, TorBoxTransferKind kind) {
    final filesRaw = raw['files'];
    final files = <TorBoxFile>[];
    if (filesRaw is List) {
      for (var i = 0; i < filesRaw.length; i++) {
        final value = filesRaw[i];
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        final id = _int(map['id'] ?? map['file_id']) ?? i;
        final name =
            _firstString(map, ['name', 'short_name', 'path', 'absolute_path']) ??
                'File ${i + 1}';
        final fullPath = _firstString(
          map,
          ['path', 'absolute_path', 'name'],
        );
        files.add(TorBoxFile(
          id: id,
          name: name,
          size: _int(map['size'] ?? map['bytes']) ?? 0,
          mimeType: _firstString(map, ['mimetype', 'mime_type', 'mime']),
          path: fullPath,
        ));
      }
    }
    final rawProgress = raw['progress'];
    double progress = rawProgress is num ? rawProgress.toDouble() : double.tryParse(rawProgress?.toString() ?? '') ?? 0;
    if (progress > 0 && progress <= 1) progress *= 100;
    final cached = raw['cached'] == true || raw['cached']?.toString().toLowerCase() == 'true';
    final finished = raw['download_finished'] == true || raw['download_finished']?.toString().toLowerCase() == 'true';
    return TorBoxItem(
      id: _int(raw['id'] ?? raw[kind == TorBoxTransferKind.torrent ? 'torrent_id' : 'webdownload_id']) ?? 0,
      name: _firstString(raw, ['name', 'title', 'filename']) ?? 'TorBox item',
      progress: progress.clamp(0, 100).toDouble(),
      size: _int(raw['size'] ?? raw['total_size']) ?? 0,
      state: _firstString(raw, ['download_state', 'state', 'status']) ?? '',
      cached: cached,
      downloadFinished: finished,
      files: files,
      kind: kind,
    );
  }

  Future<String?> _token() async {
    final value = (await _storage.read(key: _tokenKey))?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<String> _requireToken() async {
    final token = await _token();
    if (token == null) throw const TorBoxException('Connect TorBox first.');
    return token;
  }

  Map<String, String> _headers(String token, {bool json = true}) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
      };

  dynamic _unwrap(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) return response.body;
      throw TorBoxException('TorBox request failed (${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300 ||
        (decoded is Map && decoded['success'] == false)) {
      String message = 'TorBox request failed (${response.statusCode}).';
      if (decoded is Map) {
        message = (decoded['detail'] ?? decoded['error'] ?? decoded['message'] ?? message).toString();
      }
      throw TorBoxException(message);
    }
    if (decoded is Map && decoded.containsKey('data')) return decoded['data'];
    return decoded;
  }

  String _stripOrvixMetadata(String resource) {
    if (!resource.toLowerCase().startsWith('magnet:')) return resource.trim();
    final uri = Uri.tryParse(resource.trim());
    if (uri == null) return resource.trim();
    final kept = <String>[];
    for (final part in uri.query.split('&')) {
      if (part.toLowerCase().startsWith('x-pikora-') || part.toLowerCase().startsWith('x-orvix-')) continue;
      if (part.trim().isNotEmpty) kept.add(part);
    }
    return '${uri.scheme}:${uri.path}?${kept.join('&')}';
  }

  static int? _int(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final v = map[key]?.toString().trim();
      if (v != null && v.isNotEmpty && v != 'null') return v;
    }
    return null;
  }
}
