import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/home_preferences_service.dart';
import '../services/media_state_service.dart';
import '../services/platform_profile.dart';
import '../services/source_provider_service.dart';
import '../widgets/media_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.sources,
    required this.mediaState,
    required this.onOpen,
  });

  final CatalogService catalog;
  final SourceProviderService sources;
  final MediaStateService mediaState;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _preferences = HomePreferencesService();
  final Set<String> _warmingTitles = <String>{};
  late Future<_HomeData> _homeFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _homeFuture = _loadHome();

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
      loadMedia(HomeSectionId.popularMovies, () => widget.catalog.popularMovies(limit: 30)),
      loadMedia(HomeSectionId.popularTv, () => widget.catalog.popularSeries(limit: 30)),
      loadMedia(HomeSectionId.topRatedMovies, () => widget.catalog.topRatedMovies(limit: 30)),
      loadMedia(HomeSectionId.topRatedTv, () => widget.catalog.topRatedSeries(limit: 30)),
      loadMedia(HomeSectionId.imdbTopMovies, () => widget.catalog.imdbTopMovies(limit: 36)),
      loadMedia(HomeSectionId.imdbTopTv, () => widget.catalog.imdbTopSeries(limit: 36)),
    ]);

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

    return _HomeData(
      sections: sections,
      media: media,
      continueWatching: continueWatching,
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
        final hero = data.hero;

        if (PlatformProfile.isAndroidTv) {
          return _TvHomeView(
            data: data,
            onOpen: _openItem,
            onPrefetch: _prefetchItem,
          );
        }

        if (Platform.isWindows && MediaQuery.sizeOf(context).width >= 900) {
          return _DesktopHomeView(
            data: data,
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
                _Hero(item: hero, onOpen: () => _openItem(hero)),
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
                      onOpen: (entry) => widget.onOpen(entry.item),
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
    required this.onOpen,
    required this.onPrefetch,
    required this.onCustomize,
  });

  final _HomeData data;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPrefetch;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context) {
    final hero = data.hero;
    return ColoredBox(
      color: const Color(0xFF060807),
      child: ListView(
        key: const PageStorageKey('orvix-windows-home-v1'),
        cacheExtent: 1900,
        padding: const EdgeInsets.only(bottom: 72),
        children: [
          if (hero != null)
            _DesktopFeaturedHero(
              item: hero,
              onOpen: () => onOpen(hero),
              onPreview: () => onPrefetch(hero),
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.35,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF8F9891),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 315,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: 46,
                vertical: 7,
              ),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1800,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 15),
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
          SizedBox(
            height: 212,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 6),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final entry = items[index];
                return _DesktopContinueCard(
                  entry: entry,
                  onTap: () => onOpen(entry),
                  onPreview: () => onPrefetch(entry),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopContinueCard extends StatefulWidget {
  const _DesktopContinueCard({
    required this.entry,
    required this.onTap,
    required this.onPreview,
  });

  final ContinueWatchingEntry entry;
  final VoidCallback onTap;
  final VoidCallback onPreview;

  @override
  State<_DesktopContinueCard> createState() => _DesktopContinueCardState();
}

class _DesktopContinueCardState extends State<_DesktopContinueCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final active = _hovered || _focused;
    final item = widget.entry.item;
    final art = item.background ?? item.poster;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onPreview();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.025 : 1,
        duration: const Duration(milliseconds: 120),
        child: SizedBox(
          width: 300,
          child: Material(
            color: const Color(0xFF0C100E),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onFocusChange: (value) {
                setState(() => _focused = value);
                if (value) widget.onPreview();
              },
              onTap: widget.onTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: active
                        ? lime.withValues(alpha: .78)
                        : Colors.white.withValues(alpha: .10),
                    width: active ? 1.6 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (art?.trim().isNotEmpty == true)
                      CachedNetworkImage(
                        imageUrl: art!,
                        fit: BoxFit.cover,
                        memCacheWidth: 700,
                        fadeInDuration: Duration.zero,
                      )
                    else
                      const ColoredBox(color: Color(0xFF141815)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x10000000),
                            Color(0x7A000000),
                            Color(0xF20A0C0B),
                          ],
                          stops: [0, .56, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 7),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 4,
                              value: widget.entry.progress,
                              backgroundColor: Colors.white.withValues(alpha: .14),
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(lime),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            [
                              if (widget.entry.episode != null)
                                widget.entry.episode!.label,
                              '${(widget.entry.progress * 100).round()}% watched',
                            ].join(' • '),
                            style: const TextStyle(
                              color: Color(0xFFBDC5BF),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
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

class _Hero extends StatelessWidget {
  const _Hero({required this.item, required this.onOpen});
  final MediaItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tv = PlatformProfile.isAndroidTv;
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
              tv ? 28 : 40,
              tv ? 40 : 70,
              tv ? 28 : 40,
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
                const SizedBox(width: 10),
                Text(
                  '${items.length}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: PlatformProfile.isAndroidTv ? 270 : 330,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: PlatformProfile.isAndroidTv ? 24 : 32,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final entry = items[index];
                final tv = PlatformProfile.isAndroidTv;
                return SizedBox(
                  width: tv ? 138 : 170,
                  child: Column(
                    children: [
                      Expanded(
                        child: MediaCard(
                          item: entry.item,
                          width: tv ? 138 : 170,
                          onTap: () => onOpen(entry),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 5,
                          value: entry.progress,
                          backgroundColor: const Color(0xFF1C202B),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          [
                            if (entry.episode != null) entry.episode!.label,
                            '${(entry.progress * 100).round()}% watched',
                          ].join(' • '),
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
  });

  factory _HomeData.empty() => const _HomeData(
        sections: <HomeSectionId>[],
        media: <HomeSectionId, List<MediaItem>>{},
        continueWatching: <ContinueWatchingEntry>[],
      );

  final List<HomeSectionId> sections;
  final Map<HomeSectionId, List<MediaItem>> media;
  final List<ContinueWatchingEntry> continueWatching;

  List<MediaItem> items(HomeSectionId section) => media[section] ?? const [];

  MediaItem? get hero {
    for (final section in sections) {
      if (section == HomeSectionId.continueWatching) continue;
      final values = items(section);
      if (values.isNotEmpty) return values.first;
    }
    if (continueWatching.isNotEmpty) return continueWatching.first.item;
    return null;
  }
}


class _TvHomeView extends StatelessWidget {
  const _TvHomeView({
    required this.data,
    required this.onOpen,
    required this.onPrefetch,
  });

  final _HomeData data;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPrefetch;

  @override
  Widget build(BuildContext context) {
    final hero = data.hero;
    return ColoredBox(
      color: const Color(0xFF080A09),
      child: ListView(
        key: const PageStorageKey('orvix-tv-home-v2'),
        cacheExtent: 1500,
        padding: const EdgeInsets.only(bottom: 54),
        children: [
          if (hero != null)
            _TvFeaturedHero(
              item: hero,
              onOpen: () => onOpen(hero),
            ),
          if (data.continueWatching.isNotEmpty)
            _TvContinueLandscapeRail(
              items: data.continueWatching,
              onOpen: (entry) => onOpen(entry.item),
            ),
          for (final section in data.sections)
            if (section != HomeSectionId.continueWatching)
              _TvPosterShelf(
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

class _TvFeaturedHero extends StatelessWidget {
  const _TvFeaturedHero({
    required this.item,
    required this.onOpen,
  });

  final MediaItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final backdrop = item.background;
    return SizedBox(
      height: 390,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null && backdrop.isNotEmpty)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              alignment: Alignment.centerRight,
              memCacheWidth: 1280,
              fadeInDuration: Duration.zero,
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFF0B0E0C)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF0B0E0C)),
            )
          else
            const ColoredBox(color: Color(0xFF0B0E0C)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xFF080A09),
                  Color(0xF5080A09),
                  Color(0x88080A09),
                  Color(0x08080A09),
                ],
                stops: [0, .28, .60, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x10000000),
                  Color(0x22000000),
                  Color(0xFF080A09),
                ],
                stops: [0, .70, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(42, 44, 42, 36),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 570),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.logo?.trim().isNotEmpty == true)
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 360,
                          maxHeight: 115,
                        ),
                        child: CachedNetworkImage(
                          imageUrl: item.logo!,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) => Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 40,
                              height: 1,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1,
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
                          fontSize: 40,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1,
                        ),
                      ),
                    const SizedBox(height: 13),
                    Text(
                      [
                        item.typeLabel,
                        if (item.year != null) item.year!,
                        if (item.rating != null)
                          '★ ${item.rating!.toStringAsFixed(1)}',
                        if (item.runtime != null) item.runtime!,
                        ...item.genres.take(2),
                      ].join('   •   '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFC8CECA),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.description?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 13),
                      Text(
                        item.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE0E4E1),
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      autofocus: true,
                      onPressed: onOpen,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Open'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 15,
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
    );
  }
}

class _TvPosterShelf extends StatelessWidget {
  const _TvPosterShelf({
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
      padding: const EdgeInsets.only(top: 8, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 42),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.2,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF8E9690),
                  size: 24,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 252,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: 42,
                vertical: 8,
              ),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1500,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 13),
              itemBuilder: (context, index) {
                final item = items[index];
                return RepaintBoundary(
                  child: MediaCard(
                    item: item,
                    width: 142,
                    compact: true,
                    focusScale: 1.055,
                    autofocus: false,
                    onFocusChanged: (focused) {
                      if (focused) onPrefetch(item);
                    },
                    onTap: () => onOpen(item),
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

class _TvContinueLandscapeRail extends StatelessWidget {
  const _TvContinueLandscapeRail({
    required this.items,
    required this.onOpen,
  });

  final List<ContinueWatchingEntry> items;
  final ValueChanged<ContinueWatchingEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 42),
            child: Text(
              'Continue Watching',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: -.2,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 174,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: 42,
                vertical: 6,
              ),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1200,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 13),
              itemBuilder: (context, index) {
                final entry = items[index];
                return RepaintBoundary(
                  child: _TvContinueCard(
                    entry: entry,
                    onTap: () => onOpen(entry),
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

class _TvContinueCard extends StatefulWidget {
  const _TvContinueCard({
    required this.entry,
    required this.onTap,
  });

  final ContinueWatchingEntry entry;
  final VoidCallback onTap;

  @override
  State<_TvContinueCard> createState() => _TvContinueCardState();
}

class _TvContinueCardState extends State<_TvContinueCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final item = entry.item;
    final image = item.background ?? item.poster;
    final primary = Theme.of(context).colorScheme.primary;

    return AnimatedScale(
      scale: _focused ? 1.025 : 1,
      duration: const Duration(milliseconds: 110),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        width: 270,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused
                ? Colors.white.withValues(alpha: .92)
                : const Color(0xFF2A302C),
            width: _focused ? 2.2 : 1,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .35),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Material(
            color: const Color(0xFF141815),
            child: InkWell(
              focusColor: Colors.transparent,
              onFocusChange: (value) => setState(() => _focused = value),
              onTap: widget.onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image != null && image.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: image,
                      fit: BoxFit.cover,
                      memCacheWidth: 600,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, __) =>
                          const ColoredBox(color: Color(0xFF151A16)),
                      errorWidget: (_, __, ___) =>
                          const ColoredBox(color: Color(0xFF151A16)),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00000000),
                          Color(0x33000000),
                          Color(0xE6000000),
                        ],
                        stops: [0, .55, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 14,
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 7,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: entry.progress,
                        backgroundColor: Colors.white.withValues(alpha: .18),
                        color: _focused ? primary : const Color(0xFFB9FF45),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
          Container(
            height: 380,
            color: const Color(0xFF111512),
          ),
          const SizedBox(height: 18),
          for (var row = 0; row < 3; row++) ...[
            Container(
              height: 18,
              margin: const EdgeInsets.only(left: 42, right: 920),
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
