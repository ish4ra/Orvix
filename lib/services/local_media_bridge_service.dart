import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

class LocalMediaBridgeHandle {
  const LocalMediaBridgeHandle({
    required this.url,
    required this.sessionId,
  });

  final String url;
  final String sessionId;
}

/// Cross-platform loopback media bridge used for cloud/debrid playback.
///
/// TorBox/PikPak return signed HTTPS URLs. The player and the embedded
/// subtitle extractor should read the exact same byte stream, so Orvix exposes
/// that remote file through one local range-aware URL. The bridge does not
/// transcode or rewrite media; it simply proxies GET/HEAD byte-range requests.
class LocalMediaBridgeService {
  LocalMediaBridgeService._();

  static final LocalMediaBridgeService instance =
      LocalMediaBridgeService._();

  final http.Client _client = http.Client();
  final Map<String, _BridgeSession> _sessions = <String, _BridgeSession>{};
  HttpServer? _server;
  int _counter = 0;

  Future<LocalMediaBridgeHandle> bridge(
    String remoteUrl, {
    String? fileNameHint,
  }) async {
    final remote = Uri.tryParse(remoteUrl);
    if (remote == null ||
        !(remote.scheme == 'http' || remote.scheme == 'https')) {
      throw ArgumentError.value(remoteUrl, 'remoteUrl', 'Expected HTTP/HTTPS');
    }

    final server = await _ensureServer();
    final sessionId = _newSessionId();
    final fileName = _safeFileName(
      fileNameHint ??
          (remote.pathSegments.isEmpty
              ? 'stream'
              : remote.pathSegments.last),
    );
    _sessions[sessionId] = _BridgeSession(remote: remote);

    return LocalMediaBridgeHandle(
      sessionId: sessionId,
      url: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        pathSegments: <String>['media', sessionId, fileName],
      ).toString(),
    );
  }

  Future<void> release(String sessionId) async {
    _sessions.remove(sessionId);
  }

  Future<void> dispose() async {
    _sessions.clear();
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    _client.close();
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    _server = server;
    unawaited(_serve(server));
    return server;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.pathSegments.length < 2 ||
        request.uri.pathSegments.first != 'media') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final session = _sessions[request.uri.pathSegments[1]];
    if (session == null) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }

    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final upstream = http.Request(request.method, session.remote)
      ..followRedirects = true
      ..maxRedirects = 8;

    _copyRequestHeader(request, upstream, HttpHeaders.rangeHeader);
    _copyRequestHeader(request, upstream, HttpHeaders.ifRangeHeader);
    _copyRequestHeader(request, upstream, HttpHeaders.ifNoneMatchHeader);
    _copyRequestHeader(request, upstream, HttpHeaders.ifModifiedSinceHeader);
    _copyRequestHeader(request, upstream, HttpHeaders.acceptHeader);
    _copyRequestHeader(request, upstream, HttpHeaders.userAgentHeader);

    try {
      final response =
          await _client.send(upstream).timeout(const Duration(seconds: 35));

      request.response.statusCode = response.statusCode;
      for (final name in <String>[
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
        'content-disposition',
      ]) {
        _copyResponseHeader(response, request, name);
      }

      if (request.method == 'HEAD') {
        await response.stream.drain<void>();
      } else {
        await request.response.addStream(response.stream);
      }
    } on TimeoutException {
      request.response.statusCode = HttpStatus.gatewayTimeout;
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _copyRequestHeader(
    HttpRequest from,
    http.Request to,
    String name,
  ) {
    final value = from.headers.value(name);
    if (value != null && value.trim().isNotEmpty) {
      to.headers[name] = value;
    }
  }

  void _copyResponseHeader(
    http.StreamedResponse from,
    HttpRequest to,
    String name,
  ) {
    final value = from.headers[name.toLowerCase()] ?? from.headers[name];
    if (value != null && value.trim().isNotEmpty) {
      to.response.headers.set(name, value);
    }
  }

  String _newSessionId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(36);
    _counter = (_counter + 1) & 0xffff;
    return '$now$random' + _counter.toRadixString(36);
  }

  String _safeFileName(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return 'stream.mkv';
    return cleaned.length > 120
        ? cleaned.substring(cleaned.length - 120)
        : cleaned;
  }
}

class _BridgeSession {
  const _BridgeSession({required this.remote});
  final Uri remote;
}
