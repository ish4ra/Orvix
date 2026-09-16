import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/media_state_service.dart';
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

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 30, 32, 40),
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
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.5,
                          ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_items.length} saved title${_items.length == 1 ? '' : 's'} • your local Pikora collection',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                          final count = (constraints.maxWidth / 190).floor().clamp(2, 8);
                          return GridView.builder(
                            itemCount: visible.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: count,
                              crossAxisSpacing: 18,
                              mainAxisSpacing: 22,
                              childAspectRatio: .55,
                            ),
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return Stack(
                                children: [
                                  Positioned.fill(
                                    child: MediaCard(
                                      item: item,
                                      width: double.infinity,
                                      onTap: () => widget.onOpen(item),
                                    ),
                                  ),
                                  Positioned(
                                    top: 7,
                                    right: 7,
                                    child: IconButton.filledTonal(
                                      tooltip: 'Remove from Library',
                                      onPressed: () => _remove(item),
                                      icon: const Icon(Icons.bookmark_remove_outlined, size: 19),
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
            hasItems ? Icons.filter_alt_off_rounded : Icons.video_library_outlined,
            size: 54,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(
            hasItems ? 'Nothing in this filter' : 'Your Library is empty',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          Text(
            hasItems
                ? 'Try another Library filter.'
                : 'Open a movie or series and choose Add to Library.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
