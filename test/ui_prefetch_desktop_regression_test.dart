import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('title warmup and desktop refresh regressions stay locked', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final card = File('lib/widgets/media_card.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final catalog = File('lib/services/catalog_service.dart').readAsStringSync();
    final sources =
        File('lib/services/source_provider_service.dart').readAsStringSync();
    final tvSources =
        File('lib/screens/tv_source_browser_screen.dart').readAsStringSync();

    expect(home, contains('widget.catalog.peekDetails(item) ?? item'));
    expect(home, contains('await widget.sources.prefetch(rich, episode: episode)'));
    expect(home, contains('class _DesktopHomeView'));
    expect(home, contains('class _DesktopFeaturedHero'));
    expect(card, contains('MouseRegion('));
    expect(card, contains('onEnter: (_) => widget.onPreview?.call()'));

    expect(catalog, contains('MediaItem? peekDetails(MediaItem item)'));
    expect(catalog, contains('_enrichEpisodeRatingsInBackground'));
    expect(
      sources,
      contains('const Duration(minutes: 5)'),
    );

    expect(details, contains('class _MobileSeasonTileState'));
    expect(details, isNot(contains('poster: item.seasonPoster(season)')));
    expect(details, contains('const lime = Color(0xFFB9FF45)'));
    expect(details, contains('var freeStreamingRanking = !hasCloudConnection'));
    expect(details, isNot(contains("'Best'")));
    expect(details, contains('class _DesktopEpisodeCard'));
    expect(details, contains('_desktopDetailsLayout(item)'));

    expect(tvSources, contains('preferFreeP2p'));
    expect(tvSources, contains("label: 'Default'"));
    expect(tvSources, isNot(contains("label: 'Best'")));
  });
}
