class NativeSubtitleEvent {
  const NativeSubtitleEvent({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

/// Parses MPV's `sub-text/ass-full` property.
///
/// MPV converts text subtitle formats such as SRT to ASS for this property and
/// can return multiple simultaneous Dialogue events. Keeping each event's own
/// start/end time is essential: the aggregate `sub-start` / `sub-end`
/// properties collapse overlaps and cannot safely drive a translated overlay.
class NativeSubtitleEventParser {
  const NativeSubtitleEventParser._();

  static Duration? _parseClock(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 3) return null;
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final seconds = double.tryParse(parts[2]);
    if (hours == null ||
        minutes == null ||
        seconds == null ||
        !seconds.isFinite ||
        hours < 0 ||
        minutes < 0 ||
        seconds < 0 ||
        minutes > 59 ||
        seconds >= 60) {
      return null;
    }
    return Duration(
      milliseconds:
          ((hours * 3600 + minutes * 60 + seconds) * 1000).round(),
    );
  }

  static List<String>? _splitDialogueFields(String raw) {
    final colon = raw.indexOf(':');
    if (colon < 0) return null;
    final body = raw.substring(colon + 1).trimLeft();
    final fields = <String>[];
    var start = 0;

    // ASS Dialogue has 10 fields. Split only the first 9 commas because the
    // subtitle Text field may itself contain commas.
    for (var i = 0; i < body.length && fields.length < 9; i++) {
      if (body.codeUnitAt(i) == 44) {
        fields.add(body.substring(start, i));
        start = i + 1;
      }
    }
    if (fields.length != 9 || start > body.length) return null;
    fields.add(body.substring(start));
    return fields;
  }

  static String _cleanText(String raw) {
    return raw
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ')
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .trim();
  }

  static bool _looksLikeEnglishDialogue(String text) {
    final words = RegExp(r"[A-Za-z][A-Za-z'’\-]*")
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((word) => word.length > 1)
        .toList(growable: false);
    if (words.length < 2) return false;

    final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
    final otherLetters =
        RegExp(r'[\u0080-\uFFFF]').allMatches(text).length;
    return latin >= 4 && latin >= otherLetters * 2;
  }

  static List<NativeSubtitleEvent> parseAssFull(String raw) {
    final result = <NativeSubtitleEvent>[];
    final seen = <String>{};

    for (final rawLine in raw.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (!line.toLowerCase().startsWith('dialogue:')) continue;
      final fields = _splitDialogueFields(line);
      if (fields == null || fields.length != 10) continue;

      final start = _parseClock(fields[1]);
      final end = _parseClock(fields[2]);
      final text = _cleanText(fields[9]);
      if (start == null ||
          end == null ||
          end <= start ||
          text.isEmpty ||
          !_looksLikeEnglishDialogue(text)) {
        continue;
      }

      final key =
          '${start.inMilliseconds}|${end.inMilliseconds}|${text.toLowerCase()}';
      if (!seen.add(key)) continue;
      result.add(NativeSubtitleEvent(start: start, end: end, text: text));
    }

    result.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return a.end.compareTo(b.end);
    });
    return result;
  }
}
