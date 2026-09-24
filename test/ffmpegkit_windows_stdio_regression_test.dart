import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows FFmpegKit logs can never crash packaged Orvix via stdout', () {
    final main = File('lib/main.dart').readAsStringSync();

    expect(
      main,
      contains('LogRedirectionStrategy.neverPrintLogs'),
    );
    expect(
      main,
      contains('FFmpegKitConfig.enableLogCallback((_) {})'),
    );
    expect(
      main,
      contains("FFmpegKitInitializer._processLogCallbackEvent"),
    );
    expect(
      main,
      contains("trace.contains('_StdSink.write')"),
    );
    expect(
      main,
      contains("trace.contains('_RandomAccessFile.writeFromSync')"),
    );
    expect(
      main,
      contains('ffmpegkit-stdio-suppressed channel=platform'),
    );
    expect(
      main,
      contains('return true;'),
      reason:
          'the known harmless FFmpegKit stdout FileSystemException must be marked handled',
    );

    // Do not disable FFmpegKit redirection globally: Orvix still needs
    // per-session FFprobe/FFmpeg output for embedded subtitle extraction.
    expect(main, isNot(contains('FFmpegKitConfig.disableRedirection')));
  });
}
