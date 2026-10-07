import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/home_preferences_service.dart';
import '../services/media_state_service.dart';
import '../services/platform_profile.dart';
import '../services/source_provider_service.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../widgets/horizontal_scroll_rail.dart';
import '../widgets/media_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.sources,
    required this.mediaState,
    required this.onOpen,
    required this.onResume,
  });

  final CatalogService catalog;
  final SourceProviderService sources;
  final MediaStateService mediaState;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<ContinueWatchingEntry> onResume;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _preferences = HomePreferencesService();
  final Set<String> _warmingTitles = <String>{};
  late Future<_HomeData> _homeFuture;
  Timer? _heroRotationTimer;
  int _heroIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
    // On TV the hero follows the focused title instead of rotating, and a
    // periodic rebuild of the whole Home would disturb the remote.
    if (PlatformProfile.isAndroidTv) return;
    _heroRotationTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        if (mounted) setState(() => _heroIndex++);
      },
    );
  }

  @override
  void dispose() {
    _heroRotationTimer?.cancel();
    super.dispose();
  }

  void _load() {
    _heroIndex = 0;
    _homeFuture = _loadHome();
  }

  String _warmKey(MediaItem item) => '${item.kind.name}:${item.id}';

  void _prefetchMetadata(MediaItem item) {
    unawaited(widget.catalog.prefetchDetails(item));
  }

  void _prefetchItem(MediaItem item) {
    final key = _warmKey(item);
    if (!_warmingTitles.add(key)) return;
    unawaited(() async {
      try {
        final rich = await widget.catalog.details(item) ?? item;
        EpisodeItem? episode;
        if (rich.kind == MediaKind.series && rich.episodes.isNotEmpty) {
          final ordered = [...rich.episodes]
            ..sort((a, b) {
              final bySeason = a.season.compareTo(b.season);
              return bySeason != 0
                  ? bySeason
                  : a.episode.compareTo(b.episode);
            });
          episode = ordered.first;
        }
        await widget.sources.prefetch(rich, episode: episode);
      } catch (_) {
        // Hover/focus prefetch must never block navigation.
      } finally {
        _warmingTitles.remove(key);
      }
    }());
  }

  void _openItem(MediaItem item) {
    _prefetchItem(item);
    // If hover/focus or Home warm-up already completed, navigate with the rich
    // object itself so Details does not render a sparse placeholder first.
    widget.onOpen(widget.catalog.peekDetails(item) ?? item);
  }

  Future<_HomeData> _loadHome() async {
    final sections = await _preferences.load();
    final media = <HomeSectionId, List<MediaItem>>{};

    Future<void> loadMedia(
      HomeSectionId section,
      Future<List<MediaItem>> Function() loader,
    ) async {
      if (!sections.contains(section)) return;
      try {
        media[section] = await loader();
      } catch (_) {
        media[section] = const [];
      }
    }

    await Future.wait<void>([
      loadMedia(
        HomeSectionId.popularMovies,
        () => widget.catalog.popularMovies(limit: 30),
      ),
      loadMedia(
        HomeSectionId.popularTv,
        () => widget.catalog.popularSeries(limit: 30),
      ),
      loadMedia(
        HomeSectionId.topRatedMovies,
        () => widget.catalog.topRatedMovies(limit: 30),
      ),
      loadMedia(
        HomeSectionId.topRatedTv,
        () => widget.catalog.topRatedSeries(limit: 30),
      ),
    ]).timeout(
      const Duration(seconds: 24),
      onTimeout: () => <void>[],
    );

    // These rows currently resolve through the same IMDb top-rated requests as
    // topRatedMovies/topRatedTv. Loading them again on startup doubled the
    // slowest network work and could leave Home on a spinner after a brief
    // connection loss. Reuse the already-loaded rows instead.
    if (sections.contains(HomeSectionId.imdbTopMovies)) {
      media[HomeSectionId.imdbTopMovies] =
          media[HomeSectionId.topRatedMovies] ?? const <MediaItem>[];
    }
    if (sections.contains(HomeSectionId.imdbTopTv)) {
      media[HomeSectionId.imdbTopTv] =
          media[HomeSectionId.topRatedTv] ?? const <MediaItem>[];
    }

    final continueWatching = sections.contains(HomeSectionId.continueWatching)
        ? await widget.mediaState.continueWatching(limit: 24)
        : const <ContinueWatchingEntry>[];
    final library = sections.contains(HomeSectionId.myLibrary)
        ? await widget.mediaState.library()
        : const <MediaItem>[];
    final watchlist = sections.contains(HomeSectionId.myWatchlist)
        ? await widget.mediaState.watchlist()
        : const <MediaItem>[];

    media[HomeSectionId.myLibrary] = library;
    media[HomeSectionId.myWatchlist] = watchlist;

    // Warm a useful part of every visible rail instead of only the first two
    // titles globally. Metadata is cheap enough to fan out modestly; source
    // prefetch is limited to the first six likely interactions.
    final warm = <MediaItem>[];
    final seenWarm = <String>{};
    for (final section in sections) {
      for (final item in (media[section] ?? const <MediaItem>[]).take(3)) {
        final key = '${item.kind.name}:${item.id}';
        if (seenWarm.add(key)) warm.add(item);
        if (warm.length >= 18) break;
      }
      if (warm.length >= 18) break;
    }
    for (final item in warm.skip(6)) {
      _prefetchMetadata(item);
    }
    for (final item in warm.take(6)) {
      _prefetchItem(item);
    }

    final heroCandidates = <MediaItem>[];
    final seenHero = <String>{};
    for (final section in sections) {
      if (section == HomeSectionId.continueWatching) continue;
      for (final item in (media[section] ?? const <MediaItem>[]).take(10)) {
        final key = '${item.kind.name}:${item.id}';
        if (seenHero.add(key)) heroCandidates.add(item);
      }
    }
    if (heroCandidates.isEmpty) {
      for (final entry in continueWatching) {
        final item = entry.item;
        final key = '${item.kind.name}:${item.id}';
        if (seenHero.add(key)) heroCandidates.add(item);
      }
    }
    heroCandidates.shuffle(Random());

    return _HomeData(
      sections: sections,
      media: media,
      continueWatching: continueWatching,
      heroCandidates: heroCandidates,
    );
  }

  Future<void> _customizeHome() async {
    final active = [...await _preferences.load()];
    if (!mounted) return;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF0D120E),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final inactive = HomeSectionId.values.where((s) => !active.contains(s)).toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .82,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Customize Home',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Drag rows to reorder them. Hide or add shelves whenever you want.',
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        FilledButton(
                          onPressed: () async {
                            await _preferences.save(active);
                            if (sheetContext.mounted) Navigator.pop(sheetContext, true);
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Visible rows',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ReorderableListView.builder(
                        itemCount: active.length,
                        onReorder: (oldIndex, newIndex) {
                          setSheetState(() {
                            if (newIndex > oldIndex) newIndex--;
                            final section = active.removeAt(oldIndex);
                            active.insert(newIndex, section);
                          });
                        },
                        itemBuilder: (context, index) {
                          final section = active[index];
                          return Container(
                            key: ValueKey(section.name),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF171A23),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFF292E3C)),
                            ),
                            child: ListTile(
                              leading: const Icon(Icons.drag_indicator_rounded),
                              title: Text(section.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                              trailing: IconButton(
                                tooltip: 'Hide row',
                                onPressed: () => setSheetState(() => active.remove(section)),
                                icon: const Icon(Icons.visibility_off_outlined),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (inactive.isNotEmpty) ...[
                      const Divider(height: 28),
                      Text(
                        'Hidden rows',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: inactive
                            .map(
                              (section) => ActionChip(
                                avatar: const Icon(Icons.add_rounded, size: 18),
                                label: Text(section.label),
                                onPressed: () => setSheetState(() => active.add(section)),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (saved == true && mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _homeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (PlatformProfile.isAndroidTv) {
            return const _TvHomeSkeleton();
          }
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && PlatformProfile.isAndroidTv) {
          return TvMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Could not load the catalog',
            message: 'Check the TV\'s connection and try again.',
            action: TvButton(
              kind: TvButtonKind.primary,
              icon: Icons.refresh,
              label: 'Retry',
              autofocus: true,
              preferred: true,
              onPressed: () => setState(_load),
            ),
          );
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

        final data = snapshot.data ?? _HomeData.empty();
        final hero = data.heroAt(_heroIndex);

        if (PlatformProfile.isAndroidTv) {
          return _TvHomeView(
            data: data,
            hero: hero,
            onOpen: _openItem,
            onResume: widget.onResume,
            onPrefetch: _prefetchItem,
            onRetry: () => setState(_load),
          );
        }

        if (Platform.isWindows && MediaQuery.sizeOf(context).width >= 900) {
          return _DesktopHomeView(
            data: data,
            hero: hero,
            onOpen: _openItem,
            onPrefetch: _prefetchItem,
            onCustomize: _customizeHome,
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            setState(_load);
            await _homeFuture;
          },
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (hero != null)
                _Hero(
                  item: hero,
                  onOpen: () => _openItem(hero),
                  onCustomize: PlatformProfile.isAndroidMobile
                      ? _customizeHome
                      : null,
                ),
              if (!PlatformProfile.isAndroidMobile)
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 18, 32, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _customizeHome,
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Customize Home'),
                      ),
                    ],
                  ),
                ),
              for (final section in data.sections)
                if (section == HomeSectionId.continueWatching)
                  if (data.continueWatching.isNotEmpty)
                    _ContinueRail(
                      items: data.continueWatching,
                      onOpen: widget.onResume,
                    )
                  else
                    const SizedBox.shrink()
                else
                  _MediaRail(
                    title: section.label,
                    items: data.items(section),
                    onOpen: _openItem,
                    onPrefetch: _prefetchItem,
                  ),
              const SizedBox(height: 48),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopHomeView extends StatelessWidget {
  const _DesktopHomeView({
    required this.data,
    required this.hero,
    required this.onOpen,
    required this.onPrefetch,
    required this.onCustomize,
  });

  final _HomeData data;
  final MediaItem? hero;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPrefetch;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context) {
    final featured = hero;
    return ColoredBox(
      color: const Color(0xFF060807),
      child: ListView(
        key: const PageStorageKey('orvix-windows-home-v1'),
        cacheExtent: 1900,
        padding: const EdgeInsets.only(bottom: 72),
        children: [
          if (featured != null)
            _DesktopFeaturedHero(
              item: featured,
              onOpen: () => onOpen(featured),
              onPreview: () => onPrefetch(featured),
              onCustomize: onCustomize,
            ),
          if (data.continueWatching.isNotEmpty)
            _DesktopContinueRail(
              items: data.continueWatching,
              onOpen: (entry) => onOpen(entry.item),
              onPrefetch: (entry) => onPrefetch(entry.item),
            ),
          for (final section in data.sections)
            if (section != HomeSectionId.continueWatching)
              _DesktopPosterShelf(
                title: section.label,
                items: data.items(section),
                onOpen: onOpen,
                onPrefetch: onPrefetch,
              ),
        ],
      ),
    );
  }
}

class _DesktopFeaturedHero extends StatelessWidget {
  const _DesktopFeaturedHero({
    required this.item,
    required this.onOpen,
    required this.onPreview,
    required this.onCustomize,
  });

  final MediaItem item;
  final VoidCallback onOpen;
  final VoidCallback onPreview;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final backdrop = item.background ?? item.poster;
    return MouseRegion(
      onEnter: (_) => onPreview(),
      child: SizedBox(
        height: 520,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdrop?.trim().isNotEmpty == true)
              CachedNetworkImage(
                imageUrl: backdrop!,
                fit: BoxFit.cover,
                alignment: Alignment.centerRight,
                memCacheWidth: 1800,
                fadeInDuration: Duration.zero,
                placeholder: (_, __) =>
                    const ColoredBox(color: Color(0xFF0A0D0B)),
                errorWidget: (_, __, ___) =>
                    const ColoredBox(color: Color(0xFF0A0D0B)),
              )
            else
              const ColoredBox(color: Color(0xFF0A0D0B)),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xFF060807),
                    Color(0xF5060807),
                    Color(0xB0060807),
                    Color(0x30060807),
                    Color(0x00060807),
                  ],
                  stops: [0, .23, .48, .76, 1],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x20000000),
                    Color(0x00000000),
                    Color(0x18000000),
                    Color(0xFF060807),
                  ],
                  stops: [0, .35, .72, 1],
                ),
              ),
            ),
            Positioned(
              top: 26,
              right: 34,
              child: IconButton.filledTonal(
                tooltip: 'Customize Home',
                onPressed: onCustomize,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xB5141816),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.tune_rounded),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(54, 66, 54, 48),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.logo?.trim().isNotEmpty == true)
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 430,
                            maxHeight: 130,
                          ),
                          child: CachedNetworkImage(
                            imageUrl: item.logo!,
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            fadeInDuration: Duration.zero,
                            errorWidget: (_, __, ___) => Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 46,
                                height: 1.02,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.1,
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 46,
                            height: 1.02,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.1,
                          ),
                        ),
                      const SizedBox(height: 15),
                      Wrap(
                        spacing: 9,
                        runSpacing: 8,
                        children: [
                          _DesktopHeroPill(item.typeLabel),
                          if (item.year != null) _DesktopHeroPill(item.year!),
                          if (item.runtime != null)
                            _DesktopHeroPill(item.runtime!),
                          if (item.rating != null)
                            _DesktopHeroPill(
                              '★ ${item.rating!.toStringAsFixed(1)}',
                            ),
                          ...item.genres.take(3).map(_DesktopHeroPill.new),
                        ],
                      ),
                      if (item.description?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 17),
                        Text(
                          item.description!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFE3E8E4),
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                      ],
                      const SizedBox(height: 23),
                      FilledButton.icon(
                        onPressed: onOpen,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Open title'),
                        style: FilledButton.styleFrom(
                          backgroundColor: lime,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 25,
                            vertical: 16,
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopHeroPill extends StatelessWidget {
  const _DesktopHeroPill(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xA6121614),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: .14)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFE9ECEA),
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DesktopPosterShelf extends StatelessWidget {
  const _DesktopPosterShelf({
    required this.title,
    required this.items,
    required this.onOpen,
    required this.onPrefetch,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPrefetch;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 46),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: -.35,
              ),
            ),
          ),
          const SizedBox(height: 13),
          HorizontalScrollRail(
            height: 315,
            padding: const EdgeInsets.symmetric(
              horizontal: 46,
              vertical: 7,
            ),
            separatorWidth: 15,
            scrollStep: 690,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return RepaintBoundary(
                child: MediaCard(
                  item: item,
                  width: 158,
                  focusScale: 1.045,
                  onFocusChanged: (focused) {
                    if (focused) onPrefetch(item);
                  },
                  onPreview: () => onPrefetch(item),
                  onTap: () => onOpen(item),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DesktopContinueRail extends StatelessWidget {
  const _DesktopContinueRail({
    required this.items,
    required this.onOpen,
    required this.onPrefetch,
  });

  final List<ContinueWatchingEntry> items;
  final ValueChanged<ContinueWatchingEntry> onOpen;
  final ValueChanged<ContinueWatchingEntry> onPrefetch;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 46),
            child: Text(
              'Continue Watching',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: -.35,
              ),
            ),
          ),
          const SizedBox(height: 13),
          HorizontalScrollRail(
            height: 198,
            padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 6),
            separatorWidth: 16,
            scrollStep: 720,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final entry = items[index];
              return _ContinueLandscapeCard(
                entry: entry,
                width: 330,
                height: 186,
                onTap: () => onOpen(entry),
                onPreview: () => onPrefetch(entry),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ContinueLandscapeCard extends StatefulWidget {
  const _ContinueLandscapeCard({
    required this.entry,
    required this.width,
    required this.height,
    required this.onTap,
    this.onPreview,
  });

  final ContinueWatchingEntry entry;
  final double width;
  final double height;
  final VoidCallback onTap;
  final VoidCallback? onPreview;

  @override
  State<_ContinueLandscapeCard> createState() =>
      _ContinueLandscapeCardState();
}

class _ContinueLandscapeCardState extends State<_ContinueLandscapeCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final active = _hovered || _focused;
    final entry = widget.entry;
    final episode = entry.episode;
    final image =
        episode?.thumbnail ?? entry.item.background ?? entry.item.poster;
    final remaining =
        (entry.duration - entry.position).inMinutes.clamp(0, 9999);
    final episodeLabel = episode == null
        ? entry.item.typeLabel
        : [
            episode.label,
            if (episode.title.trim().isNotEmpty) episode.title.trim(),
          ].join('  •  ');

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onPreview?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.018 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Material(
            color: const Color(0xFF101411),
            borderRadius: BorderRadius.circular(13),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              focusColor: Colors.transparent,
              onFocusChange: (focused) {
                setState(() => _focused = focused);
                if (focused) widget.onPreview?.call();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: active
                        ? lime.withValues(alpha: .92)
                        : const Color(0xFF2D342F),
                    width: active ? 1.7 : 1,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (image?.trim().isNotEmpty == true)
                      CachedNetworkImage(
                        imageUrl: image!,
                        fit: BoxFit.cover,
                        memCacheWidth: 720,
                        fadeInDuration: Duration.zero,
                        placeholder: (_, __) =>
                            const ColoredBox(color: Color(0xFF151A16)),
                        errorWidget: (_, __, ___) =>
                            const ColoredBox(color: Color(0xFF151A16)),
                      )
                    else
                      const ColoredBox(color: Color(0xFF151A16)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x25000000),
                            Color(0x08000000),
                            Color(0xE8000000),
                          ],
                          stops: [0, .42, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 9,
                      right: 9,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xD9161917),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          remaining > 0 ? '${remaining}m left' : 'Resume',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 13,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 7,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            episodeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFD0D6D1),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              minHeight: 4,
                              value: entry.progress,
                              backgroundColor:
                                  Colors.white.withValues(alpha: .22),
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(lime),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinueWideCard extends StatefulWidget {
  const _ContinueWideCard({
    required this.entry,
    required this.width,
    required this.height,
    required this.imageWidth,
    required this.onTap,
    this.onPreview,
    this.autofocus = false,
  });

  final ContinueWatchingEntry entry;
  final double width;
  final double height;
  final double imageWidth;
  final VoidCallback onTap;
  final VoidCallback? onPreview;
  final bool autofocus;

  @override
  State<_ContinueWideCard> createState() => _ContinueWideCardState();
}

class _ContinueWideCardState extends State<_ContinueWideCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final active = _hovered || _focused;
    final entry = widget.entry;
    final item = entry.item;
    final episode = entry.episode;
    final image = episode?.thumbnail ?? item.background ?? item.poster;
    final isUpNext = item.kind == MediaKind.series && entry.progress <= .001;
    final compact = widget.height <= 125;

    final detail = episode != null
        ? [
            episode.label,
            if (episode.title.trim().isNotEmpty) episode.title.trim(),
          ].join('  •  ')
        : [
            item.typeLabel,
            if (item.year?.trim().isNotEmpty == true) item.year!.trim(),
          ].join('  •  ');

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onPreview?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.018 : 1,
        duration: const Duration(milliseconds: 115),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Material(
            color: const Color(0xFF111512),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              autofocus: widget.autofocus,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              onFocusChange: (value) {
                setState(() => _focused = value);
                if (value) widget.onPreview?.call();
              },
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 115),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: active
                        ? lime.withValues(alpha: .88)
                        : const Color(0xFF303731),
                    width: active ? 1.6 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: widget.imageWidth,
                      height: double.infinity,
                      child: image?.trim().isNotEmpty == true
                          ? CachedNetworkImage(
                              imageUrl: image!,
                              fit: BoxFit.cover,
                              memCacheWidth: compact ? 300 : 420,
                              fadeInDuration: Duration.zero,
                              placeholder: (_, __) => const ColoredBox(
                                color: Color(0xFF171C18),
                              ),
                              errorWidget: (_, __, ___) => const ColoredBox(
                                color: Color(0xFF171C18),
                                child: Center(
                                  child: Icon(
                                    Icons.movie_outlined,
                                    color: Color(0xFF7D887F),
                                  ),
                                ),
                              ),
                            )
                          : const ColoredBox(
                              color: Color(0xFF171C18),
                              child: Center(
                                child: Icon(
                                  Icons.movie_outlined,
                                  color: Color(0xFF7D887F),
                                ),
                              ),
                            ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 12 : 15,
                          compact ? 11 : 15,
                          compact ? 12 : 15,
                          compact ? 10 : 13,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: const Color(0xFFF0F3F0),
                                      fontSize: compact ? 14 : 17,
                                      height: 1.05,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                if (isUpNext) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: compact ? 7 : 9,
                                      vertical: compact ? 3 : 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: lime,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      'Up Next',
                                      style: TextStyle(
                                        color: Colors.black,
                                        fontSize: compact ? 9 : 10.5,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            SizedBox(height: compact ? 7 : 10),
                            Text(
                              detail,
                              maxLines: compact ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: const Color(0xFFADB7B0),
                                fontSize: compact ? 10.5 : 12.5,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: compact ? 3.5 : 4,
                                value: entry.progress,
                                backgroundColor:
                                    Colors.white.withValues(alpha: .10),
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(lime),
                              ),
                            ),
                            SizedBox(height: compact ? 5 : 7),
                            Text(
                              '${(entry.progress * 100).round()}% watched',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: const Color(0xFF98A29B),
                                fontSize: compact ? 9.5 : 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.item,
    required this.onOpen,
    this.onCustomize,
  });
  final MediaItem item;
  final VoidCallback onOpen;
  final VoidCallback? onCustomize;

  @override
  Widget build(BuildContext context) {
    final tv = PlatformProfile.isAndroidTv;
    final mobile = PlatformProfile.isAndroidMobile;
    return SizedBox(
      height: tv ? 330 : 430,
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
            padding: EdgeInsets.fromLTRB(
              tv ? 28 : (mobile ? 24 : 40),
              tv ? 40 : 70,
              tv ? 28 : (mobile ? 24 : 40),
              tv ? 28 : 44,
            ),
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
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: onOpen,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 12,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('View & Play'),
                            ),
                          ),
                        ),
                        if (onCustomize != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onCustomize,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 12,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(
                                Icons.tune_rounded,
                                size: 18,
                              ),
                              label: const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('Customize Home'),
                              ),
                            ),
                          ),
                        ],
                      ],
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
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Continue Watching',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(width: 9),
                Text(
                  '${items.length}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 172,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1000,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final entry = items[index];
                return _ContinueLandscapeCard(
                  entry: entry,
                  width: 292,
                  height: 160,
                  onTap: () => onOpen(entry),
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
    required this.onPrefetch,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPrefetch;

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
            height: PlatformProfile.isAndroidTv ? 255 : 300,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: PlatformProfile.isAndroidTv ? 24 : 32,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final item = items[index];
                return MediaCard(
                  item: item,
                  width: PlatformProfile.isAndroidTv ? 138 : 150,
                  compact: PlatformProfile.isAndroidTv,
                  onFocusChanged: (focused) {
                    if (focused) onPrefetch(item);
                  },
                  onPreview: () => onPrefetch(item),
                  onTap: () => onOpen(item),
                );
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
    required this.sections,
    required this.media,
    required this.continueWatching,
    required this.heroCandidates,
  });

  factory _HomeData.empty() => const _HomeData(
        sections: <HomeSectionId>[],
        media: <HomeSectionId, List<MediaItem>>{},
        continueWatching: <ContinueWatchingEntry>[],
        heroCandidates: <MediaItem>[],
      );

  final List<HomeSectionId> sections;
  final Map<HomeSectionId, List<MediaItem>> media;
  final List<ContinueWatchingEntry> continueWatching;
  final List<MediaItem> heroCandidates;

  List<MediaItem> items(HomeSectionId section) => media[section] ?? const [];

  MediaItem? heroAt(int index) {
    if (heroCandidates.isEmpty) return null;
    return heroCandidates[index % heroCandidates.length];
  }
}


class _TvHomeView extends StatefulWidget {
  const _TvHomeView({
    required this.data,
    required this.hero,
    required this.onOpen,
    required this.onResume,
    required this.onPrefetch,
    required this.onRetry,
  });

  final _HomeData data;
  final MediaItem? hero;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<ContinueWatchingEntry> onResume;
  final ValueChanged<MediaItem> onPrefetch;
  final VoidCallback onRetry;

  @override
  State<_TvHomeView> createState() => _TvHomeViewState();
}

class _TvHomeViewState extends State<_TvHomeView> {
  /// The title the hero shows: the focused card once focus rests on it.
  late final ValueNotifier<MediaItem?> _featured =
      ValueNotifier<MediaItem?>(widget.hero);
  Timer? _featureDebounce;

  @override
  void didUpdateWidget(covariant _TvHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_featured.value == null && widget.hero != null) {
      _featured.value = widget.hero;
    }
  }

  @override
  void dispose() {
    _featureDebounce?.cancel();
    _featured.dispose();
    super.dispose();
  }

  /// Prefetch at once, but only swap the hero (and its backdrop image) when
  /// focus stops moving, so a held DPAD key does not load every backdrop.
  void _focusTitle(MediaItem item) {
    widget.onPrefetch(item);
    _featureDebounce?.cancel();
    _featureDebounce = Timer(const Duration(milliseconds: 240), () {
      if (mounted) _featured.value = item;
    });
  }

  static String _remaining(ContinueWatchingEntry entry) {
    final left = entry.duration - entry.position;
    if (entry.duration <= Duration.zero || left <= Duration.zero) return '';
    final minutes = left.inMinutes;
    if (minutes >= 60) return '${minutes ~/ 60} h ${minutes % 60} min left';
    return minutes <= 1 ? 'Almost done' : '$minutes min left';
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final rows = <Widget>[];
    return LayoutBuilder(
      builder: (context, constraints) {
        final heroHeight = (constraints.maxHeight * .44).clamp(220.0, 470.0);
        const spacing = 18.0;
        final available = constraints.maxWidth - TvMetrics.pageHorizontal * 2;
        final posterWidth =
            ((available + spacing) / 6.3 - spacing).clamp(116.0, 172.0);
        final landscapeWidth = (posterWidth * 2.1).clamp(250.0, 360.0);

        rows.clear();
        if (data.continueWatching.isNotEmpty) {
          rows.add(TvRow(
            key: const ValueKey('tv-home-continue'),
            title: 'Continue Watching',
            itemCount: data.continueWatching.length,
            itemWidth: landscapeWidth,
            itemHeight: TvLandscapeCard.heightFor(landscapeWidth),
            itemBuilder: (context, index, node) {
              final entry = data.continueWatching[index];
              final episode = entry.episode;
              return TvLandscapeCard(
                focusNode: node,
                width: landscapeWidth,
                imageUrl: entry.item.background ?? entry.item.poster,
                title: entry.item.title,
                badge: episode == null
                    ? null
                    : 'S${episode.season} · E${episode.episode}',
                subtitle: [
                  if (episode != null && episode.title.trim().isNotEmpty)
                    episode.title.trim(),
                  _remaining(entry),
                ].where((part) => part.isNotEmpty).join('  •  '),
                progress: entry.progress,
                onFocusChange: (focused) {
                  if (focused) _focusTitle(entry.item);
                },
                onPressed: () => widget.onResume(entry),
              );
            },
          ));
        }
        for (final section in data.sections) {
          if (section == HomeSectionId.continueWatching) continue;
          final items = data.items(section);
          if (items.isEmpty) continue;
          rows.add(TvRow(
            key: ValueKey('tv-home-${section.name}'),
            title: section.label,
            itemCount: items.length,
            itemWidth: posterWidth,
            itemHeight: TvPosterCard.heightFor(
                posterWidth, MediaQuery.textScalerOf(context)),
            itemBuilder: (context, index, node) {
              final item = items[index];
              return TvPosterCard(
                focusNode: node,
                item: item,
                width: posterWidth,
                onFocusChange: (focused) {
                  if (focused) _focusTitle(item);
                },
                onPressed: () => widget.onOpen(item),
              );
            },
          ));
        }

        if (widget.hero == null && rows.isEmpty) {
          return TvMessage(
            icon: Icons.movie_filter_outlined,
            title: 'Nothing to show yet',
            message: 'Home rows could not be loaded. Check the connection and try again.',
            action: TvButton(
              kind: TvButtonKind.primary,
              icon: Icons.refresh,
              label: 'Retry',
              preferred: true,
              onPressed: widget.onRetry,
            ),
          );
        }

        return Stack(
          children: [
            Positioned(
              top: 0,
              right: 0,
              width: constraints.maxWidth * .74,
              height: heroHeight + 70,
              child: ValueListenableBuilder<MediaItem?>(
                valueListenable: _featured,
                builder: (context, item, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  child: TvNetworkImage(
                    key: ValueKey(item?.background ?? 'none'),
                    url: item?.background,
                    cacheWidth: 1280,
                    alignment: Alignment.topCenter,
                    placeholder: const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              width: constraints.maxWidth * .74,
              height: heroHeight + 72,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF050806), Color(0x99050806), Color(0x14050806)],
                    stops: [0, .45, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: heroHeight + 72,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00050806), Color(0x33050806), Color(0xFF050806)],
                    stops: [0, .6, 1],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: heroHeight,
                  child: ValueListenableBuilder<MediaItem?>(
                    valueListenable: _featured,
                    builder: (context, item, _) => item == null
                        ? const SizedBox.shrink()
                        : _TvHeroInfo(
                            item: item,
                            onOpen: () => widget.onOpen(item),
                          ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    key: const PageStorageKey('orvix-tv-home-v3'),
                    padding: const EdgeInsets.only(top: 4, bottom: 40),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => rows[index],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _TvHeroInfo extends StatelessWidget {
  const _TvHeroInfo({required this.item, required this.onOpen});

  final MediaItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      item.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TvText.display,
    );
    final meta = [
      item.typeLabel,
      if (item.year != null) item.year!,
      if (item.rating != null) '★ ${item.rating!.toStringAsFixed(1)}',
      if (item.runtime != null) item.runtime!,
      ...item.genres.take(2),
    ].join('   •   ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TvMetrics.pageHorizontal, 26, TvMetrics.pageHorizontal, 10),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.logo?.trim().isNotEmpty == true)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340, maxHeight: 92),
                  child: TvNetworkImage(
                    url: item.logo,
                    cacheWidth: 680,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    placeholder: title,
                  ),
                )
              else
                title,
              const SizedBox(height: 10),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TvText.caption.copyWith(
                  color: const Color(0xFFD2DAD1),
                  fontSize: 13.5,
                ),
              ),
              if (item.description?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Flexible(
                  child: Text(
                    item.description!.trim(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.body.copyWith(
                      color: const Color(0xFFE0E6DF),
                      fontSize: 14.5,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TvButton(
                key: const ValueKey('tv-home-hero-open'),
                kind: TvButtonKind.primary,
                icon: Icons.play_arrow_rounded,
                label: 'View details',
                autofocus: true,
                preferred: true,
                onPressed: onOpen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvHomeSkeleton extends StatefulWidget {
  const _TvHomeSkeleton();

  @override
  State<_TvHomeSkeleton> createState() => _TvHomeSkeletonState();
}

class _TvHomeSkeletonState extends State<_TvHomeSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: .42,
      upperBound: .82,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _pulse,
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          FractionallySizedBox(
            alignment: Alignment.topLeft,
            heightFactor: null,
            child: Container(
              height: 230,
              color: const Color(0xFF111512),
            ),
          ),
          const SizedBox(height: 18),
          for (var row = 0; row < 3; row++) ...[
            Container(
              height: 18,
              width: 220,
              margin: const EdgeInsets.only(left: 42),
              decoration: BoxDecoration(
                color: const Color(0xFF1A201B),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 42),
                scrollDirection: Axis.horizontal,
                itemCount: 7,
                separatorBuilder: (_, __) => const SizedBox(width: 13),
                itemBuilder: (_, __) => Container(
                  width: 142,
                  decoration: BoxDecoration(
                    color: const Color(0xFF141915),
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}
