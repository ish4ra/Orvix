import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/local_torrent_service.dart';

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
    expect(ready.label, 'Ready now');

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
    expect(singleBurst.label, 'No live data');
  });
}
