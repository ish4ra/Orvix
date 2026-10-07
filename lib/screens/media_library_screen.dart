import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/media_state_service.dart';
import '../services/platform_profile.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../widgets/media_card.dart';

enum _LibraryFilter { all, movies, tv }

class MediaLibraryScreen extends StatefulWidget {
  const MediaLibraryScreen({
    super.key,
    required this.mediaState,
    required this.onOpen,
  });

  final MediaStateService mediaState;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends State<MediaLibraryScreen> {
  List<MediaItem> _items = const [];
  _LibraryFilter _filter = _LibraryFilter.all;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await widget.mediaState.library();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _remove(MediaItem item) async {
    if (await widget.mediaState.isInLibrary(item)) {
      await widget.mediaState.toggleLibrary(item);
    }
    await _reload();
  }

  List<MediaItem> get _visible {
    return _items.where((item) {
      switch (_filter) {
        case _LibraryFilter.all:
          return true;
        case _LibraryFilter.movies:
          return item.kind == MediaKind.movie;
        case _LibraryFilter.tv:
          return item.kind == MediaKind.series;
      }
    }).toList(growable: false);
  }

  Future<void> _confirmTvRemove(MediaItem item) async {
    final remove = await showTvOptionsDialog<bool>(
      context,
      title: 'Remove “${item.title}” from Library?',
      options: const [(false, 'Keep'), (true, 'Remove from Library')],
      selected: false,
    );
    if (remove == true && mounted) await _remove(item);
  }

  Widget _buildTv(BuildContext context) {
    final visible = _visible;
    const filters = [
      (_LibraryFilter.all, 'All', Icons.apps_rounded),
      (_LibraryFilter.movies, 'Movies', Icons.movie_outlined),
      (_LibraryFilter.tv, 'TV', Icons.tv_outlined),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TvMetrics.pageHorizontal,
        TvMetrics.pageTop,
        TvMetrics.pageHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvPageHeader(
            title: 'Library',
            subtitle:
                '${_items.length} saved title${_items.length == 1 ? '' : 's'} • hold OK on a title to remove it',
          ),
          const SizedBox(height: 18),
          TvTabGroup(
            child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (filter, label, icon) in filters)
                TvTab(
                  key: ValueKey('tv-library-filter-${filter.name}'),
                  label: label,
                  icon: icon,
                  selected: _filter == filter,
                  preferred: filter == _LibraryFilter.all,
                  onPressed: () => setState(() => _filter = filter),
                ),
              TvButton(
                key: const ValueKey('tv-library-refresh'),
                kind: TvButtonKind.quiet,
                icon: Icons.refresh_rounded,
                label: 'Refresh',
                onPressed: _reload,
              ),
            ],
          ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? TvMessage(
                        icon: _items.isNotEmpty
                            ? Icons.filter_alt_off_rounded
                            : Icons.video_library_outlined,
                        title: _items.isNotEmpty
                            ? 'Nothing in this filter'
                            : 'Your Library is empty',
                        message: _items.isNotEmpty
                            ? 'Try another filter.'
                            : 'Open a movie or series and choose Library to save it here.',
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          const spacing = 18.0;
                          const target = 140.0;
                          final columns = ((constraints.maxWidth + spacing) /
                                  (target + spacing))
                              .floor()
                              .clamp(4, 8);
                          final cardWidth = (constraints.maxWidth -
                                  spacing * (columns - 1)) /
                              columns;
                          return GridView.builder(
                            padding: const EdgeInsets.only(top: 14, bottom: 30),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: spacing,
                              mainAxisSpacing: 22,
                              mainAxisExtent: TvPosterCard.heightFor(
                                  cardWidth, MediaQuery.textScalerOf(context)),
                            ),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return TvPosterCard(
                                key: ValueKey(
                                    'tv-library-${item.kind.name}-${item.id}'),
                                item: item,
                                width: cardWidth,
                                onPressed: () => widget.onOpen(item),
                                onLongPress: () => _confirmTvRemove(item),
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) return _buildTv(context);
    final visible = _visible;
    final mobile = PlatformProfile.isAndroidMobile;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 32,
        mobile ? 20 : 30,
        mobile ? 16 : 32,
        mobile ? 24 : 40,
      ),
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
                      'Library',
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -.5,
                              ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_items.length} saved title${_items.length == 1 ? '' : 's'} • your local Orvix collection',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Refresh',
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 22),
          SegmentedButton<_LibraryFilter>(
            segments: const [
              ButtonSegment(value: _LibraryFilter.all, label: Text('All')),
              ButtonSegment(
                value: _LibraryFilter.movies,
                icon: Icon(Icons.movie_outlined),
                label: Text('Movies'),
              ),
              ButtonSegment(
                value: _LibraryFilter.tv,
                icon: Icon(Icons.tv_outlined),
                label: Text('TV'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (value) {
              if (value.isNotEmpty) setState(() => _filter = value.first);
            },
          ),
          const SizedBox(height: 22),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? _EmptyLibrary(hasItems: _items.isNotEmpty)
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final count = mobile
                              ? 3
                              : (constraints.maxWidth / 190)
                                  .floor()
                                  .clamp(2, 8);
                          return GridView.builder(
                            itemCount: visible.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: count,
                              crossAxisSpacing: mobile ? 12 : 18,
                              mainAxisSpacing: mobile ? 16 : 22,
                              childAspectRatio: mobile ? .56 : .50,
                            ),
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return Stack(
                                children: [
                                  Positioned.fill(
                                    child: MediaCard(
                                      item: item,
                                      width: double.infinity,
                                      compact: mobile,
                                      onTap: () => widget.onOpen(item),
                                    ),
                                  ),
                                  Positioned(
                                    top: 7,
                                    right: 7,
                                    child: IconButton.filledTonal(
                                      tooltip: 'Remove from Library',
                                      onPressed: () => _remove(item),
                                      style: mobile
                                          ? IconButton.styleFrom(
                                              minimumSize: const Size(30, 30),
                                              maximumSize: const Size(30, 30),
                                              padding: EdgeInsets.zero,
                                            )
                                          : null,
                                      icon: Icon(
                                        Icons.bookmark_remove_outlined,
                                        size: mobile ? 16 : 19,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.hasItems});
  final bool hasItems;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasItems
                ? Icons.filter_alt_off_rounded
                : Icons.video_library_outlined,
            size: 54,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(
            hasItems ? 'Nothing in this filter' : 'Your Library is empty',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          Text(
            hasItems
                ? 'Try another Library filter.'
                : 'Open a movie or series and choose Add to Library.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
