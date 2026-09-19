import 'dart:async';

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

    _debounce = Timer(const Duration(milliseconds: 220), () async {
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
