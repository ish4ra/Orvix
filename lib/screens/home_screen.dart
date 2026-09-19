import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/home_preferences_service.dart';
import '../services/media_state_service.dart';
import '../services/platform_profile.dart';
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
  final _preferences = HomePreferencesService();
  late Future<_HomeData> _homeFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _homeFuture = _loadHome();

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
            onOpen: widget.onOpen,
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
              if (hero != null) _Hero(item: hero, onOpen: () => widget.onOpen(hero)),
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
                    onOpen: widget.onOpen,
                  ),
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
  const _MediaRail({required this.title, required this.items, required this.onOpen});

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


class _TvHomeView extends StatefulWidget {
  const _TvHomeView({
    required this.data,
    required this.onOpen,
  });

  final _HomeData data;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<_TvHomeView> createState() => _TvHomeViewState();
}

class _TvHomeViewState extends State<_TvHomeView> {
  MediaItem? _spotlight;

  MediaItem? get spotlight => _spotlight ?? widget.data.hero;

  void _focus(MediaItem item, bool focused) {
    if (!focused || identical(_spotlight, item)) return;
    setState(() => _spotlight = item);
  }

  @override
  Widget build(BuildContext context) {
    final item = spotlight;
    return Stack(
      fit: StackFit.expand,
      children: [
        _TvBackdrop(item: item),
        ListView(
          key: const PageStorageKey('orvix-tv-home'),
          padding: const EdgeInsets.only(bottom: 46),
          cacheExtent: 1200,
          children: [
            SizedBox(
              height: 292,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(34, 34, 34, 12),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: _TvSpotlightInfo(
                    item: item,
                    onOpen: item == null ? null : () => widget.onOpen(item),
                  ),
                ),
              ),
            ),
            if (widget.data.continueWatching.isNotEmpty)
              _TvContinueRail(
                items: widget.data.continueWatching,
                onOpen: (entry) => widget.onOpen(entry.item),
                onFocus: (entry, focused) => _focus(entry.item, focused),
              ),
            for (final section in widget.data.sections)
              if (section != HomeSectionId.continueWatching)
                _TvMediaRail(
                  title: section.label,
                  items: widget.data.items(section),
                  onOpen: widget.onOpen,
                  onFocus: _focus,
                ),
          ],
        ),
      ],
    );
  }
}

class _TvBackdrop extends StatelessWidget {
  const _TvBackdrop({required this.item});

  final MediaItem? item;

  @override
  Widget build(BuildContext context) {
    final url = item?.background;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: url == null || url.isEmpty
              ? const ColoredBox(
                  key: ValueKey('tv-backdrop-empty'),
                  color: Color(0xFF050806),
                )
              : CachedNetworkImage(
                  key: ValueKey(url),
                  imageUrl: url,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  fadeInDuration: Duration.zero,
                  memCacheWidth: 1280,
                  placeholder: (_, __) =>
                      const ColoredBox(color: Color(0xFF080D09)),
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: Color(0xFF080D09)),
                ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x22000000),
                Color(0x99050806),
                Color(0xFF050806),
              ],
              stops: [0, .46, .74],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0xE6050806),
                Color(0x77050806),
                Color(0x00050806),
              ],
              stops: [0, .46, .82],
            ),
          ),
        ),
      ],
    );
  }
}

class _TvSpotlightInfo extends StatelessWidget {
  const _TvSpotlightInfo({
    required this.item,
    required this.onOpen,
  });

  final MediaItem? item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final current = item;
    if (current == null) return const SizedBox.shrink();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: SizedBox(
        key: ValueKey(current.id),
        width: 570,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 31,
                height: 1.05,
                fontWeight: FontWeight.w900,
                letterSpacing: -.7,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              [
                current.typeLabel,
                if (current.year != null) current.year!,
                if (current.rating != null)
                  '★ ${current.rating!.toStringAsFixed(1)}',
                if (current.runtime != null) current.runtime!,
              ].join('   •   '),
              style: const TextStyle(
                color: Color(0xFFB7C1B9),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (current.description != null &&
                current.description!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                current.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFD5DBD6),
                  height: 1.4,
                  fontSize: 13.5,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              autofocus: false,
              onPressed: onOpen,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('View & Play'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvMediaRail extends StatelessWidget {
  const _TvMediaRail({
    required this.title,
    required this.items,
    required this.onOpen,
    required this.onFocus,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final void Function(MediaItem item, bool focused) onFocus;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 34),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -.15,
              ),
            ),
          ),
          const SizedBox(height: 11),
          SizedBox(
            height: 230,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 7),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1400,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return RepaintBoundary(
                  child: MediaCard(
                    item: item,
                    width: 126,
                    compact: true,
                    focusScale: 1.065,
                    onFocusChanged: (focused) => onFocus(item, focused),
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

class _TvContinueRail extends StatelessWidget {
  const _TvContinueRail({
    required this.items,
    required this.onOpen,
    required this.onFocus,
  });

  final List<ContinueWatchingEntry> items;
  final ValueChanged<ContinueWatchingEntry> onOpen;
  final void Function(ContinueWatchingEntry entry, bool focused) onFocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 34),
            child: Text(
              'Continue Watching',
              style: TextStyle(
                fontSize: 18.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -.15,
              ),
            ),
          ),
          const SizedBox(height: 11),
          SizedBox(
            height: 244,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 7),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1100,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final entry = items[index];
                return SizedBox(
                  width: 126,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MediaCard(
                        item: entry.item,
                        width: 126,
                        compact: true,
                        focusScale: 1.065,
                        onFocusChanged: (focused) => onFocus(entry, focused),
                        onTap: () => onOpen(entry),
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: entry.progress,
                          backgroundColor: const Color(0xFF1B241C),
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
      upperBound: .86,
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
        padding: const EdgeInsets.fromLTRB(34, 42, 0, 28),
        children: [
          Container(
            width: 430,
            height: 28,
            margin: const EdgeInsets.only(right: 440),
            decoration: BoxDecoration(
              color: const Color(0xFF182019),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            height: 14,
            margin: const EdgeInsets.only(right: 610),
            decoration: BoxDecoration(
              color: const Color(0xFF131A14),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 128),
          for (var row = 0; row < 3; row++) ...[
            Container(
              width: 170,
              height: 16,
              margin: const EdgeInsets.only(right: 680),
              decoration: BoxDecoration(
                color: const Color(0xFF171F18),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 194,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                scrollDirection: Axis.horizontal,
                itemCount: 7,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, __) => Container(
                  width: 126,
                  decoration: BoxDecoration(
                    color: const Color(0xFF111812),
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}
