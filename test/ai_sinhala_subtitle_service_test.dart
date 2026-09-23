import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/ai_sinhala_subtitle_service.dart';

AiPreparedSubtitle _prepared() => AiPreparedSubtitle(
      key: 'test:key',
      title: 'Test',
      sourceUrl: 'https://example.invalid/sub.srt',
      sourceMatch: 'test',
      cues: [
        AiSubtitleCue(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
          source: 'First line',
          translation: 'පළමු පෙළ',
        ),
        AiSubtitleCue(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 6),
          source: 'Second line',
        ),
        AiSubtitleCue(
          start: const Duration(seconds: 10),
          end: const Duration(seconds: 11),
          source: 'Third line',
          translation: 'තුන්වන පෙළ',
        ),
      ],
    );

void main() {
  test('subtitleAt never leaks source English for untranslated cues', () {
    final prepared = _prepared();

    expect(
      prepared.subtitleAt(const Duration(milliseconds: 1500)),
      'පළමු පෙළ',
    );
    expect(
      prepared.subtitleAt(const Duration(milliseconds: 5500)),
      isEmpty,
    );
    expect(
      prepared.subtitleAt(const Duration(seconds: 3)),
      isEmpty,
    );
  });

  test('cueIndexNear moves to the next cue after a seek into a gap', () {
    final prepared = _prepared();

    expect(prepared.cueIndexNear(const Duration(milliseconds: 1500)), 0);
    expect(prepared.cueIndexNear(const Duration(seconds: 3)), 1);
    expect(prepared.cueIndexNear(const Duration(milliseconds: 10500)), 2);
  });

  test('source cue matching tolerates subtitle punctuation differences', () {
    final prepared = _prepared();

    expect(prepared.matchSourceCue('First line!')?.source, 'First line');
    expect(prepared.matchSourceCue('Completely unrelated dialogue'), isNull);
  });

  test('substantial English dialogue must come back in Sinhala script', () {
    expect(
      AiSinhalaSubtitleService.isLikelySinhalaTranslation(
        'You are just going to walk out of here',
        'ඔයා මෙතනින් නිකම්ම යන්නද හදන්නේ?',
      ),
      isTrue,
    );
    expect(
      AiSinhalaSubtitleService.isLikelySinhalaTranslation(
        'You are just going to walk out of here',
        'You are just going to walk out of here',
      ),
      isFalse,
    );
    expect(
      AiSinhalaSubtitleService.isLikelySinhalaTranslation(
        'You are just going to walk out of here',
        '',
      ),
      isFalse,
    );
  });

  test('short names and interjections are not falsely rejected', () {
    expect(
      AiSinhalaSubtitleService.isLikelySinhalaTranslation(
        'Michael!',
        'Michael!',
      ),
      isTrue,
    );
    expect(
      AiSinhalaSubtitleService.isLikelySinhalaTranslation(
        'Oh no!',
        'අයියෝ!',
      ),
      isTrue,
    );
  });

  test('embedded ASS subtitles are parsed with timing, commas and style tags intact', () {
    const ass = r'''[Script Info]
Title: Test

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.20,0:00:03.40,Default,,0,0,0,,{\i1}Michael,\Ndon't move.
Dialogue: 0,0:00:04.00,0:00:05.50,Default,,0,0,0,,{\an8}[door slams]
''';

    final cues = AiSinhalaSubtitleService.parseSubtitleForTesting(ass);

    expect(cues, hasLength(2));
    expect(cues[0].start, const Duration(milliseconds: 1200));
    expect(cues[0].end, const Duration(milliseconds: 3400));
    expect(cues[0].source, "Michael,\ndon't move.");
    expect(cues[1].source, '[door slams]');
  });

  test('exact torrent external subtitle matcher keeps the selected episode', () {
    final matching =
        AiSinhalaSubtitleService.externalTorrentSubtitleMatchScoreForTesting(
      'Prison.Break.S01E01.720p.HDTV.x264-LOL.English.srt',
      'Prison.Break.S01E01.720p.HDTV.x264-LOL.mkv',
    );
    final wrongEpisode =
        AiSinhalaSubtitleService.externalTorrentSubtitleMatchScoreForTesting(
      'Prison.Break.S01E02.720p.HDTV.x264-LOL.English.srt',
      'Prison.Break.S01E01.720p.HDTV.x264-LOL.mkv',
    );
    final ambiguousPackSubtitle =
        AiSinhalaSubtitleService.externalTorrentSubtitleMatchScoreForTesting(
      'English.srt',
      'Prison.Break.S01E01.720p.HDTV.x264-LOL.mkv',
    );

    expect(matching, greaterThan(0));
    expect(wrongEpisode, lessThan(0));
    expect(ambiguousPackSubtitle, lessThan(0));
  });

  test('torrent external subtitle content must actually look English', () {
    const english = '''WEBVTT

00:00:01.000 --> 00:00:02.000
What are you doing here?

00:00:03.000 --> 00:00:04.000
You have to get out of here now.

00:00:05.000 --> 00:00:06.000
I know what you are trying to do.

00:00:07.000 --> 00:00:08.000
This is not the place for that.

00:00:09.000 --> 00:00:10.000
We should go before they come back.

00:00:11.000 --> 00:00:12.000
Where did you put the car?

00:00:13.000 --> 00:00:14.000
He was there with your brother.

00:00:15.000 --> 00:00:16.000
They will know when we leave.
''';

    const spanish = '''WEBVTT

00:00:01.000 --> 00:00:02.000
No puedo creer que estés aquí.

00:00:03.000 --> 00:00:04.000
Tenemos que salir de este lugar ahora.

00:00:05.000 --> 00:00:06.000
Ella dijo que vendría mañana.

00:00:07.000 --> 00:00:08.000
Nadie sabe dónde está el coche.

00:00:09.000 --> 00:00:10.000
Vamos antes de que regresen.

00:00:11.000 --> 00:00:12.000
Necesito hablar contigo primero.

00:00:13.000 --> 00:00:14.000
Todo esto parece muy extraño.

00:00:15.000 --> 00:00:16.000
Después podemos volver a casa.
''';

    expect(
      AiSinhalaSubtitleService.subtitleTextLooksEnglishForTesting(english),
      isTrue,
    );
    expect(
      AiSinhalaSubtitleService.subtitleTextLooksEnglishForTesting(spanish),
      isFalse,
    );
  });

  test('native ASS cue formatting does not break transcript matching', () {
    final prepared = AiPreparedSubtitle(
      key: 'ass-match',
      title: 'Test',
      sourceUrl: 'embedded.ass',
      sourceMatch: 'embedded-native-track',
      cues: [
        AiSubtitleCue(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 3),
          source: "Michael,\ndon't move.",
        ),
      ],
    );

    final match = prepared.matchSourceCueRange(
      r"{\i1}Michael,\Ndon't move.",
    );
    expect(match?.index, 0);
  });

}
