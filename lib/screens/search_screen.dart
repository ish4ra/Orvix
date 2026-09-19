import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/platform_profile.dart';
import '../widgets/media_card.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.active = true,
  });

  final CatalogService catalog;
  final ValueChanged<MediaItem> onOpen;
  final bool active;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode;
  final _firstResultFocusNode =
      FocusNode(debugLabel: 'search-first-result');
  Timer? _debounce;
  List<MediaItem> _results = const [];
  bool _loading = false;
  String? _error;
  int _generation = 0;
  MediaItem? _tvFocusedItem;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'search-field',
      onKeyEvent: _handleSearchFieldKey,
    );
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  void _focusFirstResult() {
    if (_results.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _results.isNotEmpty) {
        _firstResultFocusNode.requestFocus();
      }
    });
  }

  KeyEventResult _handleSearchFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowDown &&
        _results.isNotEmpty) {
      _focusFirstResult();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onQueryChanged(String raw) {
    _debounce?.cancel();
    final query = raw.trim();
    final generation = ++_generation;

    if (query.runes.length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    _debounce = Timer(
        Duration(milliseconds: PlatformProfile.isAndroidTv ? 320 : 220),
        () async {
      try {
        final results = await widget.catalog.search(query, limit: 30);
        if (!mounted || generation != _generation) return;
        setState(() {
          _results = results;
          _loading = false;
        });
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformProfile.isAndroidTv) {
      return _buildTvSearch(context);
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final mobile = screenWidth < 600;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        mobile ? 16 : 32,
        mobile ? 18 : 28,
        mobile ? 16 : 32,
        mobile ? 18 : 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Search',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              Text(
                'Movies + TV',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _focusFirstResult(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 17),
              decoration: InputDecoration(
                hintText:
                    'Start typing — suggestions appear after 2 characters…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                          setState(() {});
                          _focusNode.requestFocus();
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: _loading
                ? const LinearProgressIndicator(key: ValueKey('progress'))
                : const SizedBox(key: ValueKey('idle'), height: 4),
          ),
          const SizedBox(height: 18),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildTvSearch(BuildContext context) {
    final focused = _tvFocusedItem ??
        (_results.isNotEmpty ? _results.first : null);
    final backdrop = focused?.background;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop != null && backdrop.isNotEmpty)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: CachedNetworkImage(
              key: ValueKey(backdrop),
              imageUrl: backdrop,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              memCacheWidth: 1280,
              fadeInDuration: Duration.zero,
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFF050806)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF050806)),
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xCC050806),
                Color(0xEE050806),
                Color(0xFF050806),
              ],
              stops: [0, .36, .62],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 24, 30, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'Search',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.35,
                    ),
                  ),
                  const SizedBox(width: 22),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        onChanged: _onQueryChanged,
                        onSubmitted: (_) => _focusFirstResult(),
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Movies, series…',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _controller.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  onPressed: () {
                                    _controller.clear();
                                    _onQueryChanged('');
                                    setState(() {});
                                    _focusNode.requestFocus();
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (focused != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text(
                        [
                          focused.title,
                          if (focused.year != null) focused.year!,
                        ].join('  •  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          color: Color(0xFFB0BAB2),
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(child: _buildTvSearchBody(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTvSearchBody(BuildContext context) {
    final query = _controller.text.trim();
    if (query.runes.length < 2) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text(
            'Type at least two characters to search.',
            style: TextStyle(
              color: Color(0xFF97A299),
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          'Search failed: $_error',
          style: const TextStyle(color: Color(0xFFFFB4AB)),
        ),
      );
    }

    if (_loading && _results.isEmpty) {
      return const _TvSearchSkeleton();
    }

    if (!_loading && _results.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text(
          'No matching movies or TV series found.',
          style: TextStyle(color: Color(0xFF97A299)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 13.0;
        final width = constraints.maxWidth;
        final columns = width >= 1180
            ? 8
            : width >= 980
                ? 7
                : width >= 800
                    ? 6
                    : 5;
        final cardWidth =
            (width - spacing * (columns - 1)) / columns.toDouble();
        final cardHeight = cardWidth / .675 + 40;

        return Stack(
          children: [
            GridView.builder(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              cacheExtent: 1000,
              padding: const EdgeInsets.only(top: 4, bottom: 26),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: spacing,
                mainAxisSpacing: 15,
                mainAxisExtent: cardHeight,
              ),
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final item = _results[index];
                return RepaintBoundary(
                  child: MediaCard(
                    key: ValueKey('tv-search-result-$index'),
                    item: item,
                    width: double.infinity,
                    compact: true,
                    focusScale: 1.055,
                    focusNode: index == 0 ? _firstResultFocusNode : null,
                    onFocusChanged: (focused) {
                      if (!focused || !mounted) return;
                      if (_tvFocusedItem?.id != item.id) {
                        setState(() => _tvFocusedItem = item);
                      }
                    },
                    onTap: () => widget.onOpen(item),
                  ),
                );
              },
            ),
            if (_loading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    final query = _controller.text.trim();
    if (query.runes.length < 2) {
      return const Align(
        alignment: Alignment.topLeft,
        child: _SearchHint(),
      );
    }

    if (_error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('Search failed: $_error'),
      );
    }

    if (!_loading && _results.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text('No matching movies or TV series found.'),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final tv = PlatformProfile.isAndroidTv;
        final columns = tv
            ? width >= 1320
                ? 9
                : width >= 1120
                    ? 8
                    : width >= 920
                        ? 7
                        : width >= 760
                            ? 6
                            : 5
            : width >= 1400
                ? 7
                : width >= 1200
                    ? 6
                    : width >= 1000
                        ? 5
                        : width >= 840
                            ? 4
                            : 3;
        // Android TV commonly reports a much smaller logical width than its
        // physical 1080p/4K framebuffer. Treat TV as a compact poster surface
        // explicitly so a 1920x1080 television does not end up with tablet-size
        // cards after device-pixel-ratio scaling.
        final compactGrid =
            tv || MediaQuery.sizeOf(context).shortestSide < 600;
        final crossSpacing = tv ? 12.0 : compactGrid ? 10.0 : 16.0;
        final cardWidth =
            (width - crossSpacing * (columns - 1)) / columns.toDouble();
        final cardHeight = cardWidth / .675 + (compactGrid ? 44 : 64);

        return GridView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossSpacing,
            mainAxisSpacing: tv ? 16 : compactGrid ? 14 : 22,
            mainAxisExtent: cardHeight,
          ),
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final item = _results[index];
            return MediaCard(
              key: ValueKey('search-result-$index'),
              item: item,
              width: double.infinity,
              compact: compactGrid,
              focusNode: index == 0 ? _firstResultFocusNode : null,
              onTap: () => widget.onOpen(item),
            );
          },
        );
      },
    );
  }
}

class _TvSearchSkeleton extends StatefulWidget {
  const _TvSearchSkeleton();

  @override
  State<_TvSearchSkeleton> createState() => _TvSearchSkeletonState();
}

class _TvSearchSkeletonState extends State<_TvSearchSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
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
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          crossAxisSpacing: 13,
          mainAxisSpacing: 15,
          childAspectRatio: .62,
        ),
        itemCount: 14,
        itemBuilder: (_, __) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111812),
            borderRadius: BorderRadius.circular(11),
          ),
        ),
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 620),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0B100D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF232837)),
      ),
      child: const Row(
        children: [
          Icon(Icons.auto_awesome_outlined, size: 28),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Type two or more characters. Orvix searches movies and TV together and updates suggestions automatically as you type.',
              style: TextStyle(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
