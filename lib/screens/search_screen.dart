import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/platform_profile.dart';
import '../services/source_provider_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../widgets/media_card.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.catalog,
    this.sources,
    required this.onOpen,
    this.active = true,
  });

  final CatalogService catalog;
  final SourceProviderService? sources;
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
  /// The TV result being looked at, for the preview line and backdrop. A
  /// notifier, so moving focus does not rebuild the whole results grid.
  final _tvPreview = ValueNotifier<MediaItem?>(null);
  final _tvBackdrop = ValueNotifier<String?>(null);
  Timer? _tvBackdropDebounce;
  final Set<String> _warmingTitles = <String>{};

  /// Desktop keeps keyboard-first Search: the field takes focus whenever
  /// Search opens. On a phone or tablet a focused field raises the software
  /// keyboard, so there the field is focused only when the user taps it. On
  /// TV the shell moves focus into Search; the TV field is read-only until
  /// the user presses OK.
  static bool get _focusFieldOnOpen {
    if (PlatformProfile.isAndroidTv) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia =>
        false,
    };
  }

  /// Touch platforms where focusing the field opens the software keyboard.
  static bool get _softKeyboard =>
      !PlatformProfile.isAndroidTv && !_focusFieldOnOpen;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'search-field',
      onKeyEvent: _handleSearchFieldKey,
    );
    if (widget.active && _focusFieldOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && _focusFieldOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    // Leaving Search on a phone closes its keyboard; coming back does not
    // reopen it.
    if (!widget.active && oldWidget.active && _softKeyboard) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tvBackdropDebounce?.cancel();
    _tvPreview.dispose();
    _tvBackdrop.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  void _prefetchItem(MediaItem item) {
    final key = '${item.kind.name}:${item.id}';
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
        final sources = widget.sources;
        if (sources != null) {
          await sources.prefetch(rich, episode: episode);
        }
      } catch (_) {
        // Search suggestions remain usable even if a background warm-up fails.
      } finally {
        _warmingTitles.remove(key);
      }
    }());
  }

  void _openItem(MediaItem item) {
    _prefetchItem(item);
    // A route remembers its focused field and refocuses it when the next
    // route pops. On a phone that would reopen the keyboard on the way back
    // from Details, so the field lets go of focus first.
    if (_softKeyboard) _focusNode.unfocus();
    widget.onOpen(widget.catalog.peekDetails(item) ?? item);
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
              // Flutter keeps a touch field focused on an outside tap; on a
              // phone, tapping elsewhere closes the keyboard instead.
              onTapOutside: _softKeyboard ? (_) => _focusNode.unfocus() : null,
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
                          // Desktop goes straight back to typing. On a phone
                          // clearing does not open the keyboard by itself.
                          if (!_softKeyboard) _focusNode.requestFocus();
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

  void _previewTvItem(MediaItem item) {
    _prefetchItem(item);
    _tvPreview.value = item;
    // Swap the backdrop only once focus rests, not on every step of a held
    // DPAD key.
    _tvBackdropDebounce?.cancel();
    _tvBackdropDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _tvBackdrop.value = item.background;
    });
  }

  Widget _buildTvSearch(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: _tvBackdrop,
          builder: (context, backdrop, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: backdrop == null || backdrop.isEmpty
                ? const SizedBox.expand(key: ValueKey('no-backdrop'))
                : Align(
                    key: ValueKey(backdrop),
                    alignment: Alignment.topRight,
                    child: FractionallySizedBox(
                      widthFactor: .72,
                      heightFactor: .62,
                      child: TvNetworkImage(
                        url: backdrop,
                        cacheWidth: 1280,
                        alignment: Alignment.topCenter,
                      ),
                    ),
                  ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xFF050806), Color(0xE6050806), Color(0x80050806)],
              stops: [.18, .5, 1],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66050806), Color(0xF2050806), Color(0xFF050806)],
              stops: [0, .42, .62],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TvMetrics.pageHorizontal,
            TvMetrics.pageTop,
            TvMetrics.pageHorizontal,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Search', style: TvText.title),
                  const SizedBox(width: 28),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: TvTextField(
                          key: const ValueKey('tv-search-field'),
                          controller: _controller,
                          focusNode: _focusNode,
                          nextFocusNode: _firstResultFocusNode,
                          preferred: true,
                          icon: Icons.search_rounded,
                          hint: 'Movies, series…',
                          textInputAction: TextInputAction.search,
                          onChanged: (value) {
                            _onQueryChanged(value);
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 22,
                child: ValueListenableBuilder<MediaItem?>(
                  valueListenable: _tvPreview,
                  builder: (context, item, _) => item == null
                      ? const SizedBox.shrink()
                      : Text(
                          [
                            item.title,
                            item.typeLabel,
                            if (item.year != null) item.year!,
                            if (item.rating != null)
                              '★ ${item.rating!.toStringAsFixed(1)}',
                          ].join('   •   '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TvText.caption.copyWith(
                            color: TvColors.lime,
                            fontSize: 14,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
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
          padding: EdgeInsets.only(top: 18),
          child: Text(
            'Press OK on the search box and type at least two characters. Results appear as you type.',
            style: TvText.body,
          ),
        ),
      );
    }

    if (_error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Text(
            'Search failed. Check the connection and try again.',
            style: TvText.body.copyWith(color: TvColors.danger),
          ),
        ),
      );
    }

    if (_loading && _results.isEmpty) {
      return const _TvSearchSkeleton();
    }

    if (!_loading && _results.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(top: 18),
          child: Text(
            'No matching movies or TV series found.',
            style: TvText.body,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 18.0;
        const target = 140.0;
        final width = constraints.maxWidth;
        final columns =
            ((width + spacing) / (target + spacing)).floor().clamp(4, 8);
        final cardWidth =
            (width - spacing * (columns - 1)) / columns.toDouble();

        return Stack(
          children: [
            GridView.builder(
              padding: const EdgeInsets.only(top: 12, bottom: 30),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: spacing,
                mainAxisSpacing: 22,
                mainAxisExtent: TvPosterCard.heightFor(
                                  cardWidth, MediaQuery.textScalerOf(context)),
              ),
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final item = _results[index];
                return TvPosterCard(
                  key: ValueKey('tv-search-result-$index'),
                  item: item,
                  width: cardWidth,
                  focusNode: index == 0 ? _firstResultFocusNode : null,
                  onFocusChange: (focused) {
                    if (focused && mounted) _previewTvItem(item);
                  },
                  onPressed: () => _openItem(item),
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
              onFocusChanged: (focused) {
                if (focused) _prefetchItem(item);
              },
              onPreview: () => _prefetchItem(item),
              onTap: () => _openItem(item),
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
