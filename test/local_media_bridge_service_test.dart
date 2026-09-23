import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orvix/services/local_media_bridge_service.dart';

void main() {
  test('local media bridge proxies byte ranges and HEAD requests', () async {
    final bytes = List<int>.generate(2048, (index) => index % 251);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    final serverFuture = () async {
      await for (final request in upstream) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (request.method == 'HEAD') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..contentLength = bytes.length;
          await request.response.close();
          continue;
        }

        if (range != null && range.startsWith('bytes=')) {
          final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
          final start = int.parse(match!.group(1)!);
          final end = match.group(2)!.isEmpty
              ? bytes.length - 1
              : int.parse(match.group(2)!);
          final chunk = bytes.sublist(start, end + 1);
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            )
            ..contentLength = chunk.length
            ..add(chunk);
          await request.response.close();
          continue;
        }

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      }
    }();

    final handle = await LocalMediaBridgeService.instance.bridge(
      'http://127.0.0.1:${upstream.port}/episode.mkv',
      fileNameHint: 'episode.mkv',
    );

    final ranged = await http.get(
      Uri.parse(handle.url),
      headers: const {'Range': 'bytes=100-199'},
    );
    expect(ranged.statusCode, HttpStatus.partialContent);
    expect(ranged.bodyBytes, bytes.sublist(100, 200));
    expect(ranged.headers['content-range'], 'bytes 100-199/${bytes.length}');

    final client = HttpClient();
    final headRequest = await client.headUrl(Uri.parse(handle.url));
    final headResponse = await headRequest.close();
    expect(headResponse.statusCode, HttpStatus.ok);
    expect(headResponse.contentLength, bytes.length);
    await headResponse.drain<void>();
    client.close(force: true);

    await LocalMediaBridgeService.instance.release(handle.sessionId);
    await upstream.close(force: true);
    await serverFuture.timeout(const Duration(seconds: 2));
  });
}
