import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/free_p2p_live_probe_service.dart';
import 'package:orvix/services/local_torrent_service.dart';
import 'package:orvix/services/source_provider_service.dart';

void main() {
  test('Ready now requires sustained multi-window evidence', () {
    const ready = LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: 1024 * 1024,
      elapsed: Duration(seconds: 1),
      firstByteLatency: Duration(milliseconds: 450),
      peers: 20,
      connections: 6,
      downloadSpeedBytesPerSecond: 3 * 1024 * 1024,
      sampleWindowsPassed: 2,
    );
    expect(ready.label, 'READY NOW');

    const singleBurst = LocalTorrentProbeResult(
      playableNow: false,
      bytesReceived: 512 * 1024,
      elapsed: Duration(seconds: 2),
      firstByteLatency: Duration(milliseconds: 200),
      peers: 50,
      connections: 8,
      downloadSpeedBytesPerSecond: 8 * 1024 * 1024,
      sampleWindowsPassed: 1,
    );
    // Peers and a single burst, but no sustained second window: stalled.
    expect(singleBurst.status, LocalTorrentProbeStatus.stalled);
    expect(singleBurst.label, 'STALLED');
  });

  test('live score rewards bandwidth headroom for the actual payload', () {
    const live = LocalTorrentProbeResult(
      playableNow: true,
      bytesReceived: 1024 * 1024,
      elapsed: Duration(seconds: 1),
      firstByteLatency: Duration(milliseconds: 600),
      peers: 20,
      connections: 6,
      downloadSpeedBytesPerSecond: 2 * 1024 * 1024,
      sampleWindowsPassed: 2,
    );
    const compact = SourceResult(
      provider: 'test',
      title: 'compact',
      resource: 'magnet:?xt=urn:btih:compact',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
      seeders: 20,
      sizeBytes: 1200 * 1024 * 1024,
    );
    const heavy = SourceResult(
      provider: 'test',
      title: 'heavy',
      resource: 'magnet:?xt=urn:btih:heavy',
      isMagnet: true,
      sortMode: SourceSortMode.seeders,
      seeders: 20,
      sizeBytes: 14 * 1024 * 1024 * 1024,
    );
    const duration = Duration(hours: 2);

    expect(
      live.scoreFor(compact, mediaDuration: duration),
      greaterThan(live.scoreFor(heavy, mediaDuration: duration)),
    );
  });

  test('runtime parser supports common movie and episode formats', () {
    expect(
      FreeP2pLiveProbeService.parseMediaRuntime('2h 10min'),
      const Duration(hours: 2, minutes: 10),
    );
    expect(
      FreeP2pLiveProbeService.parseMediaRuntime('45 min'),
      const Duration(minutes: 45),
    );
    expect(
      FreeP2pLiveProbeService.parseMediaRuntime('1:35'),
      const Duration(hours: 1, minutes: 35),
    );
  });

}
