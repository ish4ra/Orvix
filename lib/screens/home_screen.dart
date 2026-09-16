import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/media_state_service.dart';
import '../widgets/media_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.mediaState,
    required this.onOpen,
  });

  final CatalogService catalog;
  final MediaStateService mediaState;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _homeFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _homeFuture = _loadHome();
  }

  Future<_HomeData> _loadHome() async {
    final groups = await Future.wait([
      widget.catalog.popularMovies(limit: 30),
      widget.catalog.popularSeries(limit: 30),
      widget.catalog.topRatedMovies(limit: 30),
      widget.catalog.topRatedSeries(limit: 30),
    ]);
    final continueWatching = await widget.mediaState.continueWatching(limit: 18);
    final watchlist = await widget.mediaState.watchlist();
    return _HomeData(
      movies: groups[0],
      series: groups[1],
      ratedMovies: groups[2],
      ratedSeries: groups[3],
      continueWatching: continueWatching,
      watchlist: watchlist,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _homeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 42),
                const SizedBox(height: 12),
                Text('Could not load the catalog\n${snapshot.error}', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => setState(_load),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        final data = snapshot.data ?? const _HomeData.empty();
        final hero = data.movies.isNotEmpty ? data.movies.first : null;

        return RefreshIndicator(
          onRefresh: () async {
            setState(_load);
            await _homeFuture;
          },
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (hero != null) _Hero(item: hero, onOpen: () => widget.onOpen(hero)),
              if (data.continueWatching.isNotEmpty)
                _ContinueRail(
                  items: data.continueWatching,
                  onOpen: (entry) => widget.onOpen(entry.item),
                ),
              _MediaRail(title: 'My Watchlist', items: data.watchlist, onOpen: widget.onOpen),
              _MediaRail(title: 'Popular Movies', items: data.movies, onOpen: widget.onOpen),
              _MediaRail(title: 'Popular TV', items: data.series, onOpen: widget.onOpen),
              _MediaRail(title: 'Top Rated Movies', items: data.ratedMovies, onOpen: widget.onOpen),
              _MediaRail(title: 'Top Rated TV', items: data.ratedSeries, onOpen: widget.onOpen),
              const SizedBox(height: 48),
            ],
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.item, required this.onOpen});
  final MediaItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 430,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.background != null)
            Image.network(
              item.background!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x2208090D), Color(0xFF08090D)],
                stops: [0.15, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xEF08090D), Color(0x0008090D)],
                stops: [0, .74],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 70, 40, 44),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.8,
                          ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      [
                        item.typeLabel,
                        if (item.year != null) item.year!,
                        if (item.rating != null) '★ ${item.rating!.toStringAsFixed(1)}',
                      ].join('  •  '),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.description != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        item.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('View & Play'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueRail extends StatelessWidget {
  const _ContinueRail({required this.items, required this.onOpen});

  final List<ContinueWatchingEntry> items;
  final ValueChanged<ContinueWatchingEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              children: [
                Text(
                  'Continue Watching',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 10),
                const Icon(Icons.history_rounded, size: 20),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 315,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final entry = items[index];
                return SizedBox(
                  width: 150,
                  child: Column(
                    children: [
                      Expanded(child: MediaCard(item: entry.item, onTap: () => onOpen(entry))),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 4,
                          value: entry.progress,
                          backgroundColor: const Color(0xFF1C202B),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          entry.episode?.label ?? '${(entry.progress * 100).round()}% watched',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaRail extends StatelessWidget {
  const _MediaRail({
    required this.title,
    required this.items,
    required this.onOpen,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 300,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final item = items[index];
                return MediaCard(item: item, onTap: () => onOpen(item));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeData {
  const _HomeData({
    required this.movies,
    required this.series,
    required this.ratedMovies,
    required this.ratedSeries,
    required this.continueWatching,
    required this.watchlist,
  });

  const _HomeData.empty()
      : movies = const [],
        series = const [],
        ratedMovies = const [],
        ratedSeries = const [],
        continueWatching = const [],
        watchlist = const [];

  final List<MediaItem> movies;
  final List<MediaItem> series;
  final List<MediaItem> ratedMovies;
  final List<MediaItem> ratedSeries;
  final List<ContinueWatchingEntry> continueWatching;
  final List<MediaItem> watchlist;
}
