// Subtitle text shown by the Android ExoPlayer screen: encodings, markup
// left in cues, Media3's parsed-cue format and the Playback info summary.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/exo_playback_diagnostics.dart';
import 'package:orvix/services/external_subtitle_track.dart';
import 'package:orvix/services/orvix_exo_player.dart';
import 'package:orvix/services/subtitle_text_cleanup.dart';

import 'support/fake_exo_backend.dart';

void main() {
  group('decoding', () {
    test('Windows-1252 quotes, dashes and ellipses are not control characters',
        () {
      // "It’s – “fine”…" in Windows-1252.
      final bytes = <int>[
        ...'It'.codeUnits, 0x92, ...'s '.codeUnits, 0x96, 0x20, 0x93, //
        ...'fine'.codeUnits, 0x94, 0x85,
      ];
      final text = AndroidExoPlayerScreen.decodeSubtitleBytes(bytes);
      expect(text, 'It’s – “fine”…');
      expect(RegExp('[\u0080-\u009F]').hasMatch(text), isFalse,
          reason: 'C1 controls are drawn as boxes or "?" on TV');
    });

    test('UTF-8 with or without a BOM, and UTF-16 with a BOM', () {
      expect(SubtitleTextCleanup.decode(utf8.encode('Señor')), 'Señor');
      expect(
          SubtitleTextCleanup.decode([0xEF, 0xBB, 0xBF, ...utf8.encode('ok')]),
          'ok');
      final le = <int>[0xFF, 0xFE];
      final be = <int>[0xFE, 0xFF];
      for (final unit in 'Hi ♪'.codeUnits) {
        le.addAll([unit & 0xFF, unit >> 8]);
        be.addAll([unit >> 8, unit & 0xFF]);
      }
      expect(SubtitleTextCleanup.decode(le), 'Hi ♪');
      expect(SubtitleTextCleanup.decode(be), 'Hi ♪');
    });

    test('Sinhala UTF-8 stays intact', () {
      const sinhala = 'ආයුබෝවන්';
      expect(SubtitleTextCleanup.decode(utf8.encode(sinhala)), sinhala);
    });
  });

  group('cleanup', () {
    test('entities, ASS hard spaces and invisible characters', () {
      expect(SubtitleTextCleanup.clean('Tom &amp; Jerry &#39;99&#x21;'),
          "Tom & Jerry '99!");
      expect(SubtitleTextCleanup.clean(r'Wait\hhere'), 'Wait here');
      expect(SubtitleTextCleanup.clean('a​b﻿c\u0085d'), 'abcd');
      expect(SubtitleTextCleanup.clean(r'Line one\NLine two'),
          'Line one\nLine two');
    });

    test('visible text is never removed', () {
      expect(SubtitleTextCleanup.clean('♪ *sighs* ¿Qué? 100%'),
          '♪ *sighs* ¿Qué? 100%');
      expect(SubtitleTextCleanup.clean('  spaced   out  \n\n second '),
          'spaced out\nsecond');
      expect(SubtitleTextCleanup.clean('&unknown; stays'), '&unknown; stays');
    });

    test('external SRT and ASS cues are shown without markup', () {
      final srt = ExternalSubtitleTrack.parse(
        '1\n00:00:01,000 --> 00:00:03,000\n'
        '{\\an8}<i>Rock &amp; roll</i>\n\n'
        '2\n00:00:04,000 --> 00:00:05,000\n​\n',
        label: 'test',
      );
      expect(srt.cues, hasLength(1), reason: 'An invisible-only cue is dropped');
      expect(srt.linesAt(const Duration(seconds: 2)), ['Rock & roll']);

      final ass = ExternalSubtitleTrack.parse(
        '[Events]\n'
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
        'Effect, Text\n'
        r'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\i1}Hello\hthere{\i0}\NWorld',
        label: 'test',
      );
      expect(ass.linesAt(const Duration(seconds: 2)), ['Hello there\nWorld']);
    });
  });

  group('Media3 embedded tracks', () {
    OrvixExoTrack track(String mime, {String? codecs}) =>
        OrvixExoTrack.fromMap({
          'type': 'text',
          'group': 2,
          'track': 0,
          'language': 'en',
          'mimeType': mime,
          'codecs': codecs,
          'selected': true,
        });

    test('parsed cues report the format the file really carries', () {
      final srt = track(OrvixExoTrack.parsedCuesMime,
          codecs: 'application/x-subrip');
      expect(srt.formatMime, 'application/x-subrip');
      expect(srt.codecName, 'SRT');
      expect(srt.isBitmapSubtitle, isFalse);

      final ass = track(OrvixExoTrack.parsedCuesMime, codecs: 'text/x-ssa');
      expect(ass.isAssSubtitle, isTrue);
      expect(ass.codecName, 'ASS/SSA');

      final pgs = track(OrvixExoTrack.parsedCuesMime, codecs: 'application/pgs');
      expect(pgs.isBitmapSubtitle, isTrue,
          reason: 'Image subtitles are never offered as styled text');

      // Older Media3 or a sideloaded track: the MIME type itself.
      expect(track('application/vobsub').isBitmapSubtitle, isTrue);
    });

    test('embedded cue text is cleaned and counted for Playback info',
        () async {
      final backend = FakeExoBackend();
      final controller = OrvixExoController(url: 'http://x/v.mkv', backend: backend);
      await controller.open();
      final id = backend.lastId;
      backend.emit(id, {
        'event': 'tracks',
        'tracks': [
          {
            'type': 'text',
            'group': 2,
            'track': 0,
            'language': 'en',
            'mimeType': OrvixExoTrack.parsedCuesMime,
            'codecs': 'application/x-subrip',
            'selected': true,
            'supported': true,
          },
          {
            'type': 'text',
            'group': 3,
            'track': 0,
            'language': 'it',
            'mimeType': OrvixExoTrack.parsedCuesMime,
            'codecs': 'application/pgs',
            'selected': false,
            'supported': true,
          },
        ],
      });
      expect(exoSubtitleTrackSummary(controller.value),
          '2: English SRT ✓ selected, Italian PGS (image)');
      final selected = controller.value.textTracks.first;
      expect(exoSubtitleCueSummary(controller.value, selected),
          startsWith('None received yet'));

      backend.emit(id, {
        'event': 'cues',
        'text': ['It\u0092s &amp; fine​', '﻿'],
        'bitmaps': <Object?>[],
      });
      expect(controller.value.cueText, ['Its & fine'],
          reason: 'Controls and zero-width characters are dropped');
      expect(controller.value.cueEvents, 1);
      expect(exoSubtitleCueSummary(controller.value, selected), '1 received');

      // An empty cue update (the line ends) is not counted.
      backend.emit(id, {'event': 'cues', 'text': <Object?>[], 'bitmaps': <Object?>[]});
      expect(controller.value.cueEvents, 1);
      expect(controller.value.cueText, isEmpty);
      controller.dispose();
    });

    test('no tracks at all is reported as such', () {
      expect(exoSubtitleTrackSummary(const OrvixExoValue()),
          'None in this video');
    });
  });
}
