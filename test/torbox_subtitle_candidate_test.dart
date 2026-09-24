import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/torbox_service.dart';

void main() {
  TorBoxItem item(List<TorBoxFile> files) => TorBoxItem(
        id: 77,
        name: 'Prison Break Season 1',
        progress: 100,
        size: 0,
        state: 'completed',
        cached: true,
        downloadFinished: true,
        files: files,
        kind: TorBoxTransferKind.torrent,
      );

  test('TorBox sibling subtitles reject the wrong episode in a season pack', () {
    const video = TorBoxFile(
      id: 10,
      name: 'Prison.Break.S01E01.720p.HDTV.x264-LOL.mkv',
      path: 'Prison.Break.S01/Prison.Break.S01E01.720p.HDTV.x264-LOL.mkv',
      size: 700000000,
    );
    const correct = TorBoxFile(
      id: 11,
      name: 'Prison.Break.S01E01.720p.HDTV.x264-LOL.English.srt',
      path:
          'Prison.Break.S01/Subs/Prison.Break.S01E01.720p.HDTV.x264-LOL.English.srt',
      size: 90000,
    );
    const wrong = TorBoxFile(
      id: 12,
      name: 'Prison.Break.S01E02.720p.HDTV.x264-LOL.English.srt',
      path:
          'Prison.Break.S01/Subs/Prison.Break.S01E02.720p.HDTV.x264-LOL.English.srt',
      size: 91000,
    );

    final ranked = TorBoxService.rankSubtitleCandidatesForVideo(
      item([video, correct, wrong]),
      video,
      season: 1,
      episode: 1,
    );

    expect(ranked.map((candidate) => candidate.file.id), contains(11));
    expect(ranked.map((candidate) => candidate.file.id), isNot(contains(12)));
    expect(ranked.first.reason, contains('exact-episode'));
  });

  test('generic English.srt is safe inside a directory with one video', () {
    const video = TorBoxFile(
      id: 20,
      name: 'episode.mkv',
      path: 'Prison.Break.S01E01/episode.mkv',
      size: 700000000,
    );
    const subtitle = TorBoxFile(
      id: 21,
      name: 'English.srt',
      path: 'Prison.Break.S01E01/English.srt',
      size: 80000,
    );

    final ranked = TorBoxService.rankSubtitleCandidatesForVideo(
      item([video, subtitle]),
      video,
      season: 1,
      episode: 1,
    );

    expect(ranked, hasLength(1));
    expect(ranked.single.file.id, 21);
    expect(ranked.single.reason, contains('single-video-directory'));
  });

  test('bare pack-level English.srt is rejected when the folder has many videos', () {
    const episode1 = TorBoxFile(
      id: 30,
      name: 'Prison.Break.S01E01.mkv',
      path: 'Prison.Break.S01/Prison.Break.S01E01.mkv',
      size: 700000000,
    );
    const episode2 = TorBoxFile(
      id: 31,
      name: 'Prison.Break.S01E02.mkv',
      path: 'Prison.Break.S01/Prison.Break.S01E02.mkv',
      size: 700000000,
    );
    const ambiguous = TorBoxFile(
      id: 32,
      name: 'English.srt',
      path: 'Prison.Break.S01/English.srt',
      size: 80000,
    );

    final ranked = TorBoxService.rankSubtitleCandidatesForVideo(
      item([episode1, episode2, ambiguous]),
      episode1,
      season: 1,
      episode: 1,
    );

    expect(ranked, isEmpty);
  });

  test('TorBox file keeps full path identity separate from short name', () {
    const file = TorBoxFile(
      id: 40,
      name: 'English.srt',
      path: 'Prison.Break.S01E01/Subs/English.srt',
      size: 80000,
    );

    expect(file.name, 'English.srt');
    expect(file.identityPath, 'Prison.Break.S01E01/Subs/English.srt');
    expect(file.isTextSubtitle, isTrue);
  });
}
