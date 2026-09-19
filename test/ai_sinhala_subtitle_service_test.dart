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
}
