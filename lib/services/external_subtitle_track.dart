import 'ai_sinhala_subtitle_service.dart';

/// A subtitle file loaded beside the stream (a local file or an OpenSubtitles
/// download): SRT, WebVTT or ASS/SSA, parsed by the same production parser
/// the AI Sinhala pipeline uses.
class ExternalSubtitleTrack {
  ExternalSubtitleTrack({
    required this.label,
    required this.cues,
    this.language,
    this.source = 'file',
  });

  factory ExternalSubtitleTrack.parse(
    String text, {
    required String label,
    String? language,
    String source = 'file',
  }) =>
      ExternalSubtitleTrack(
        label: label,
        language: language,
        source: source,
        cues: AiSinhalaSubtitleService.parseSubtitleText(text),
      );

  final String label;
  final String? language;

  /// 'file' or 'online'.
  final String source;
  final List<AiSubtitleCue> cues;

  bool get isEmpty => cues.isEmpty;

  /// Lines to show at [position]. A positive [offset] shows each line later,
  /// a negative one earlier.
  List<String> linesAt(Duration position, {Duration offset = Duration.zero}) {
    final at = position - offset;
    if (cues.isEmpty || at < Duration.zero) return const <String>[];
    // Last cue that starts at or before [at].
    var low = 0;
    var high = cues.length - 1;
    var index = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (cues[mid].start <= at) {
        index = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (index < 0) return const <String>[];
    final lines = <String>[];
    // Overlapping cues: walk back over cues that are still showing.
    for (var i = index; i >= 0 && i > index - 8; i--) {
      final cue = cues[i];
      if (cue.start <= at && at < cue.end) lines.insert(0, cue.source);
    }
    return lines;
  }
}
