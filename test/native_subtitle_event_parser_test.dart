import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/native_subtitle_event_parser.dart';

void main() {
  test('parses overlapping MPV ass-full events without flattening timing', () {
    const raw = '''
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:10.00,0:00:12.40,Default,,0,0,0,,{\\i1}First English line{\\i0}
Dialogue: 0,0:00:11.20,0:00:15.00,Default,,0,0,0,,Second line, with a comma
''';

    final events = NativeSubtitleEventParser.parseAssFull(raw);

    expect(events, hasLength(2));
    expect(events[0].start, const Duration(seconds: 10));
    expect(events[0].end, const Duration(milliseconds: 12400));
    expect(events[0].text, 'First English line');
    expect(events[1].start, const Duration(milliseconds: 11200));
    expect(events[1].end, const Duration(seconds: 15));
    expect(events[1].text, 'Second line, with a comma');
  });

  test('cleans ASS line breaks and ignores duplicate or non-English events', () {
    const raw = r'''
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello there\NHow are you?
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello there\NHow are you?
Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,こんにちは 世界
Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,No.
Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}
Dialogue: 0,0:99:00.00,0:99:02.00,Default,,0,0,0,,Invalid timing line
''';

    final events = NativeSubtitleEventParser.parseAssFull(raw);

    expect(events, hasLength(2));
    expect(events[0].text, 'Hello there\nHow are you?');
    expect(events[1].text, 'No.');
  });
}
