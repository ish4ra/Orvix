import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/home_screen.dart';
import 'package:orvix/services/media_state_service.dart';

const _movie = MediaItem(
    id: 'tt0050083', kind: MediaKind.movie, title: '12 Angry Men', year: '1957');
const _series = MediaItem(
  id: 'tt0903747',
  kind: MediaKind.series,
  title: 'Breaking Bad',
  episodes: [EpisodeItem(id: 'e1', season: 1, episode: 1, title: 'Pilot')],
);

ContinueWatchingEntry _entry(
  MediaItem item, {
  EpisodeItem? episode,
  required int position,
  required int duration,
}) =>
    ContinueWatchingEntry(
      item: item,
      episode: episode,
      position: Duration(minutes: position),
      duration: Duration(minutes: duration),
      updatedAt: DateTime(2026, 10, 1),
    );

void main() {
  test('TV card text matches the Windows and phone cards', () {
    final movie = _entry(_movie, position: 20, duration: 97);
    expect(tvContinueDetail(movie), 'Movie  •  1957');
    expect(tvContinueChip(movie), '1h 17m left');

    final episode =
        _entry(_series, episode: _series.episodes.first, position: 1, duration: 58);
    expect(tvContinueDetail(episode), 'S01E01  •  Pilot');
    expect(tvContinueChip(episode), '57m left');
  });

  test('chips for unstarted, finished and unknown-length entries', () {
    expect(
      tvContinueChip(_entry(_series,
          episode: _series.episodes.first, position: 0, duration: 58)),
      'Up next',
    );
    expect(tvContinueChip(_entry(_movie, position: 96, duration: 97)),
        'Almost done');
    expect(tvContinueChip(_entry(_movie, position: 5, duration: 0)), 'Resume');
  });
}
