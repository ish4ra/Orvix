import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orvix/services/torrentcheap_hls.dart';
import 'package:orvix/services/torrentcheap_models.dart';
import 'package:orvix/services/torrentcheap_service.dart';

// Synthetic identifiers only. No real torrent, account or stream appears here.
const _hash = '0123456789abcdef0123456789abcdef01234567';
const _magnet = 'magnet:?xt=urn:btih:$_hash&dn=Sample';

TorrentCheapMagnetMetadata _metadata() => const TorrentCheapMagnetMetadata(
      infoHash: _hash,
      name: 'Sample',
      files: [
        TorrentCheapMagnetFile(
            index: 0, path: 'Sample/sample.mkv', sizeBytes: 900),
        TorrentCheapMagnetFile(
            index: 1, path: 'Sample/sample.en.srt', sizeBytes: 10),
        TorrentCheapMagnetFile(index: 2, path: 'Sample/readme.txt', sizeBytes: 1),
      ],
    );

TorrentCheapPlaybackSource _stream({
  String url = 'https://s00.torrentcheap.com/files/video-stream/test/master.m3u8',
  DateTime? expiresAt,
}) =>
    TorrentCheapPlaybackSource(
      masterPlaylistUri: Uri.parse(url),
      expiresAt: expiresAt,
    );

class _FakeGateway implements TorrentCheapGateway {
  bool connected = true;
  TorrentCheapMagnetMetadata metadata = _metadata();
  int activeCount = 0;
  List<TorrentCheapTask> active = [];
  List<TorrentCheapTask> history = [];
  Map<String?, List<TorrentCheapFolderPage>> folders = {};
  List<TorrentCheapPlaybackSource> playback = [];
  Object? throwOnMetadata;

  final calls = <String>[];
  List<int>? createdSelection;
  final pageTokens = <String?>[];

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<TorrentCheapMagnetMetadata> fetchMagnetMetadata(String magnet) async {
    calls.add('metadata');
    final error = throwOnMetadata;
    if (error != null) throw error;
    return metadata;
  }

  @override
  Future<String> createTask(String magnet, List<int> selectedFileIndexes) async {
    calls.add('create');
    createdSelection = selectedFileIndexes;
    return 'task-1';
  }

  @override
  Future<int> activeTaskCount() async => activeCount;

  @override
  Future<List<TorrentCheapTask>> activeTasks() async => active;

  @override
  Future<List<TorrentCheapTask>> taskHistory() async => history;

  @override
  Future<TorrentCheapFolderPage> listFolder(
    String? folderId, {
    String? pageToken,
  }) async {
    pageTokens.add(pageToken);
    final pages = folders[folderId] ?? const <TorrentCheapFolderPage>[];
    if (pages.isEmpty) return const TorrentCheapFolderPage(entries: []);
    final index = pageToken == null ? 0 : int.parse(pageToken);
    return pages[index.clamp(0, pages.length - 1)];
  }

  @override
  Future<TorrentCheapPlaybackSource> resolvePlayback(String fileId) async {
    calls.add('playback');
    return playback.removeAt(0);
  }
}

Matcher _throwsKind(TorrentCheapErrorKind kind) => throwsA(
      isA<TorrentCheapException>().having((e) => e.kind, 'kind', kind),
    );

void main() {
  late _FakeGateway gateway;
  late TorrentCheapService service;

  setUp(() {
    gateway = _FakeGateway();
    service = TorrentCheapService(gateway: gateway, enabled: true);
  });

  group('availability', () {
    test('the experimental build flag is off by default', () {
      expect(TorrentCheapService.experimentalBuildFlag, isFalse);
    });

    test('a default service is unavailable and never touches a gateway',
        () async {
      final defaultService = TorrentCheapService(gateway: gateway);
      expect(defaultService.isAvailable, isFalse);
      expect(await defaultService.isConnected(), isFalse);
      await expectLater(
        defaultService.lookupMagnet(_magnet),
        _throwsKind(TorrentCheapErrorKind.unavailable),
      );
      expect(gateway.calls, isEmpty);
    });

    test('enabled without a transport is still unavailable', () async {
      final noTransport = TorrentCheapService(enabled: true);
      expect(noTransport.isAvailable, isFalse);
      await expectLater(
        noTransport.listFolder(null),
        _throwsKind(TorrentCheapErrorKind.unavailable),
      );
    });

    test('a disconnected account asks the user to connect', () async {
      gateway.connected = false;
      await expectLater(
        service.lookupMagnet(_magnet),
        _throwsKind(TorrentCheapErrorKind.notConnected),
      );
      expect(gateway.calls, isEmpty);
    });
  });

  group('magnet validation', () {
    test('normalizes hex and base32 info hashes', () {
      expect(
        TorrentCheapService.normalizedInfoHash(
            'magnet:?xt=urn:btih:${_hash.toUpperCase()}&dn=x'),
        _hash,
      );
      expect(
        TorrentCheapService.normalizedInfoHash(
            'magnet:?dn=x&xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH'),
        _hash,
      );
    });

    test('rejects things that are not v1 magnet links', () {
      for (final input in [
        '',
        'https://example.com/file.torrent',
        'magnet:?dn=no-hash',
        'magnet:?xt=urn:btih:1234',
        'magnet:?xt=urn:btmh:1220abcdef',
        'xt=urn:btih:$_hash',
      ]) {
        expect(TorrentCheapService.normalizedInfoHash(input), isNull,
            reason: input);
      }
    });

    test('invalid magnets are rejected before any provider request', () async {
      await expectLater(
        service.lookupMagnet('not a magnet'),
        _throwsKind(TorrentCheapErrorKind.invalidMagnet),
      );
      expect(gateway.calls, isEmpty);
    });

    test('a magnet with no files is a provider error', () async {
      gateway.metadata = const TorrentCheapMagnetMetadata(
          infoHash: _hash, name: 'Empty', files: []);
      await expectLater(
        service.lookupMagnet(_magnet),
        _throwsKind(TorrentCheapErrorKind.provider),
      );
    });

    test('lookup returns the provider file list', () async {
      final metadata = await service.lookupMagnet(_magnet);
      expect(metadata.files.map((f) => f.name),
          ['sample.mkv', 'sample.en.srt', 'readme.txt']);
      expect(metadata.totalBytes, 911);
    });
  });

  group('task submission', () {
    test('sends a sorted, de-duplicated selection', () async {
      final id = await service.submitMagnet(_magnet, _metadata(), [1, 0, 1]);
      expect(id, 'task-1');
      expect(gateway.createdSelection, [0, 1]);
    });

    test('rejects empty or unknown file selections', () async {
      await expectLater(
        service.submitMagnet(_magnet, _metadata(), const []),
        _throwsKind(TorrentCheapErrorKind.invalidSelection),
      );
      await expectLater(
        service.submitMagnet(_magnet, _metadata(), const [0, 9]),
        _throwsKind(TorrentCheapErrorKind.invalidSelection),
      );
      expect(gateway.calls, isNot(contains('create')));
    });

    test('rejects metadata that belongs to another magnet', () async {
      await expectLater(
        service.submitMagnet(
          'magnet:?xt=urn:btih:${'f' * 40}',
          _metadata(),
          const [0],
        ),
        _throwsKind(TorrentCheapErrorKind.invalidSelection),
      );
    });

    test('does not submit when the active-task limit is reached', () async {
      gateway.activeCount = 5;
      await expectLater(
        service.submitMagnet(_magnet, _metadata(), const [0]),
        _throwsKind(TorrentCheapErrorKind.taskLimitReached),
      );
      expect(gateway.calls, isNot(contains('create')));
    });

    test('provider limit errors pass through unchanged', () async {
      gateway.throwOnMetadata = const TorrentCheapException(
          TorrentCheapErrorKind.quotaExceeded, 'Storage is full.');
      await expectLater(
        service.lookupMagnet(_magnet),
        _throwsKind(TorrentCheapErrorKind.quotaExceeded),
      );
    });

    test('unexpected transport errors never leak their text', () async {
      gateway.throwOnMetadata = Exception(
          'GET https://s00.torrentcheap.com/x?sig=secret failed for $_magnet');
      try {
        await service.lookupMagnet(_magnet);
        fail('expected an exception');
      } on TorrentCheapException catch (e) {
        expect(e.kind, TorrentCheapErrorKind.network);
        expect(e.message, isNot(contains('secret')));
        expect(e.message, isNot(contains(_hash)));
      }
    });
  });

  group('task tracking', () {
    test('reuses a completed download with the same info hash', () async {
      gateway.history = const [
        TorrentCheapTask(
            id: 'failed',
            state: TorrentCheapTaskState.failed,
            infoHash: _hash),
        TorrentCheapTask(
            id: 'done',
            state: TorrentCheapTaskState.completed,
            infoHash: '0123456789ABCDEF0123456789ABCDEF01234567'),
      ];
      expect((await service.findCompletedTask(_hash))?.id, 'done');
      expect(await service.findCompletedTask('f' * 40), isNull);
    });

    test('finds a task in active tasks, then in history', () async {
      gateway.active = const [
        TorrentCheapTask(
            id: 'a', state: TorrentCheapTaskState.downloading, progress: 0.5),
      ];
      gateway.history = const [
        TorrentCheapTask(id: 'h', state: TorrentCheapTaskState.completed),
      ];
      expect((await service.taskStatus('a')).progress, 0.5);
      expect((await service.taskStatus('h')).isComplete, isTrue);
      await expectLater(
        service.taskStatus('missing'),
        _throwsKind(TorrentCheapErrorKind.notFound),
      );
    });

    test('waits through progress until the task completes', () async {
      final states = [
        const TorrentCheapTask(id: 't', state: TorrentCheapTaskState.queued),
        const TorrentCheapTask(
            id: 't', state: TorrentCheapTaskState.downloading, progress: 0.4),
        const TorrentCheapTask(
            id: 't', state: TorrentCheapTaskState.completed, progress: 1),
      ];
      final delays = <Duration>[];
      final polling = TorrentCheapService(
        gateway: gateway,
        enabled: true,
        delay: (d) async {
          delays.add(d);
          gateway.active = [states.removeAt(0)];
        },
      );
      gateway.active = [states.removeAt(0)];
      final seen = <double>[];
      final done = await polling.waitForCompletion(
        't',
        pollInterval: const Duration(seconds: 2),
        onProgress: (task) => seen.add(task.progress),
      );
      expect(done.isComplete, isTrue);
      expect(seen, [0, 0.4, 1]);
      expect(delays, hasLength(2));
    });

    test('reports a failed task with its message redacted', () async {
      gateway.active = const [
        TorrentCheapTask(
          id: 't',
          state: TorrentCheapTaskState.failed,
          message: 'No peers for $_magnet',
        ),
      ];
      try {
        await service.waitForCompletion('t');
        fail('expected an exception');
      } on TorrentCheapException catch (e) {
        expect(e.kind, TorrentCheapErrorKind.provider);
        expect(e.message, contains('No peers'));
        expect(e.message, isNot(contains(_hash)));
      }
    });

    test('gives up on a task whose progress never moves', () async {
      gateway.active = const [
        TorrentCheapTask(id: 't', state: TorrentCheapTaskState.downloading),
      ];
      final polling = TorrentCheapService(
          gateway: gateway, enabled: true, delay: (_) async {});
      await expectLater(
        polling.waitForCompletion('t', stallAfter: 3),
        _throwsKind(TorrentCheapErrorKind.stalled),
      );
    });

    test('times out on a task that keeps progressing too slowly', () async {
      var now = DateTime(2026);
      var progress = 0.0;
      final polling = TorrentCheapService(
        gateway: gateway,
        enabled: true,
        clock: () => now,
        delay: (d) async {
          now = now.add(d);
          progress += 0.01;
          gateway.active = [
            TorrentCheapTask(
                id: 't',
                state: TorrentCheapTaskState.downloading,
                progress: progress),
          ];
        },
      );
      gateway.active = const [
        TorrentCheapTask(id: 't', state: TorrentCheapTaskState.downloading),
      ];
      await expectLater(
        polling.waitForCompletion(
          't',
          pollInterval: const Duration(seconds: 10),
          timeout: const Duration(seconds: 30),
        ),
        _throwsKind(TorrentCheapErrorKind.timeout),
      );
    });
  });

  group('cloud files', () {
    test('follows pagination and stops on a repeated token', () async {
      gateway.folders[null] = const [
        TorrentCheapFolderPage(
          entries: [
            TorrentCheapCloudEntry(id: '1', name: 'a.mkv', isFolder: false),
          ],
          nextPageToken: '1',
        ),
        TorrentCheapFolderPage(
          entries: [
            TorrentCheapCloudEntry(id: '2', name: 'b.mkv', isFolder: false),
          ],
          nextPageToken: '1',
        ),
      ];
      final entries = await service.listFolder(null);
      expect(entries.map((e) => e.id), ['1', '2']);
      expect(gateway.pageTokens, [null, '1']);
    });

    test('finds the requested video inside sub-folders', () async {
      gateway.folders['root'] = const [
        TorrentCheapFolderPage(entries: [
          TorrentCheapCloudEntry(
              id: 'big', name: 'Extras.mkv', isFolder: false, sizeBytes: 5000),
          TorrentCheapCloudEntry(id: 'sub', name: 'Season', isFolder: true),
          TorrentCheapCloudEntry(
              id: 'txt', name: 'notes.txt', isFolder: false, sizeBytes: 9999),
        ]),
      ];
      gateway.folders['sub'] = const [
        TorrentCheapFolderPage(entries: [
          TorrentCheapCloudEntry(
              id: 'ep1', name: 'Show.S01E01.mkv', isFolder: false, sizeBytes: 900),
          TorrentCheapCloudEntry(
              id: 'ep2', name: 'Show.S01E02.mp4', isFolder: false, sizeBytes: 800),
        ]),
      ];

      final named = await service.findPlayableVideo('root',
          preferredName: 'show.s01e02.mp4');
      expect(named?.id, 'ep2');
      final largest = await service.findPlayableVideo('root');
      expect(largest?.id, 'big');
      final shallow = await service.findPlayableVideo('root',
          preferredName: 'Show.S01E02.mp4', maxDepth: 0);
      expect(shallow?.id, 'big');
    });

    test('an empty folder has no playable video', () async {
      expect(await service.findPlayableVideo('nothing'), isNull);
    });
  });

  group('playback', () {
    test('returns a trusted HLS source with its headers intact', () async {
      gateway.playback = [
        TorrentCheapPlaybackSource(
          masterPlaylistUri: Uri.parse(
              'https://s00.torrentcheap.com/files/video-stream/test/master.m3u8'),
          httpHeaders: const {'Referer': 'https://www.torrentcheap.com/'},
        ),
      ];
      final source = await service.resolvePlayback('file');
      expect(source.isTranscoded, isTrue);
      expect(source.httpHeaders['Referer'], 'https://www.torrentcheap.com/');
    });

    test('refuses stream links outside TorrentCheap or without https',
        () async {
      for (final url in [
        'http://s00.torrentcheap.com/master.m3u8',
        'https://evil.example/master.m3u8',
        'https://torrentcheap.com.evil.example/master.m3u8',
        'https://nottorrentcheap.com/master.m3u8',
      ]) {
        gateway.playback = [_stream(url: url)];
        await expectLater(
          service.resolvePlayback('file'),
          _throwsKind(TorrentCheapErrorKind.unsupportedStream),
          reason: url,
        );
      }
    });

    test('re-resolves once when the first link is about to expire', () async {
      final now = DateTime(2026, 1, 1, 12);
      final clocked = TorrentCheapService(
          gateway: gateway, enabled: true, clock: () => now);
      gateway.playback = [
        _stream(expiresAt: now.add(const Duration(seconds: 30))),
        _stream(expiresAt: now.add(const Duration(hours: 1))),
      ];
      final source = await clocked.resolvePlayback('file');
      expect(source.expiresAt, now.add(const Duration(hours: 1)));
      expect(gateway.calls.where((c) => c == 'playback'), hasLength(2));
    });

    test('fails when the provider keeps returning expired links', () async {
      final now = DateTime(2026, 1, 1, 12);
      final clocked = TorrentCheapService(
          gateway: gateway, enabled: true, clock: () => now);
      gateway.playback = [
        _stream(expiresAt: now.subtract(const Duration(minutes: 1))),
        _stream(expiresAt: now),
      ];
      await expectLater(
        clocked.resolvePlayback('file'),
        _throwsKind(TorrentCheapErrorKind.streamExpired),
      );
    });

    test('a probe refusal stops playback before the player opens', () async {
      final probe = TorrentCheapHlsProbe(
        client: MockClient((_) async => http.Response('', 403)),
      );
      final probed = TorrentCheapService(
          gateway: gateway, enabled: true, probe: probe);
      gateway.playback = [_stream()];
      await expectLater(
        probed.resolvePlayback('file'),
        _throwsKind(TorrentCheapErrorKind.unauthorized),
      );
    });
  });

  group('log redaction', () {
    test('removes magnets, query strings, stream ids and credentials', () {
      final redacted = TorrentCheapService.redactForLog(
        'add $_magnet then GET '
        'https://s00.torrentcheap.com/files/video-stream/abc123/master.m3u8?token=t0k '
        'Cookie: session=s3cr3t\nAuthorization: Bearer b34r3r',
      );
      for (final secret in [_hash, 'abc123', 't0k', 's3cr3t', 'b34r3r']) {
        expect(redacted, isNot(contains(secret)), reason: secret);
      }
      expect(redacted, contains('magnet:[redacted]'));
      expect(redacted, contains('https://s00.torrentcheap.com/files/video-stream/'));
    });
  });
}
