import 'package:shared_preferences/shared_preferences.dart';

enum HomeSectionId {
  continueWatching,
  myLibrary,
  myWatchlist,
  popularMovies,
  popularTv,
  imdbTopMovies,
  imdbTopTv,
  topRatedMovies,
  topRatedTv,
}

extension HomeSectionLabel on HomeSectionId {
  String get label {
    switch (this) {
      case HomeSectionId.continueWatching:
        return 'Continue Watching';
      case HomeSectionId.myLibrary:
        return 'My Library';
      case HomeSectionId.myWatchlist:
        return 'My Watchlist';
      case HomeSectionId.popularMovies:
        return 'Popular Movies';
      case HomeSectionId.popularTv:
        return 'Popular TV';
      case HomeSectionId.imdbTopMovies:
        return 'IMDb Top 250 Movies';
      case HomeSectionId.imdbTopTv:
        return 'IMDb Top 250 TV';
      case HomeSectionId.topRatedMovies:
        return 'Top Rated Movies';
      case HomeSectionId.topRatedTv:
        return 'Top Rated TV';
    }
  }
}

class HomePreferencesService {
  static const _key = 'pikora_home_sections_v1';

  static const defaultSections = <HomeSectionId>[
    HomeSectionId.continueWatching,
    HomeSectionId.myLibrary,
    HomeSectionId.myWatchlist,
    HomeSectionId.popularMovies,
    HomeSectionId.popularTv,
    HomeSectionId.topRatedMovies,
    HomeSectionId.topRatedTv,
  ];

  Future<List<HomeSectionId>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key);
    if (stored == null || stored.isEmpty) return [...defaultSections];
    final parsed = <HomeSectionId>[];
    for (final value in stored) {
      HomeSectionId? section;
      for (final candidate in HomeSectionId.values) {
        if (candidate.name == value) {
          section = candidate;
          break;
        }
      }
      if (section != null && !parsed.contains(section)) parsed.add(section);
    }
    return parsed.isEmpty ? [...defaultSections] : parsed;
  }

  Future<void> save(List<HomeSectionId> sections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, sections.map((e) => e.name).toList());
  }
}
