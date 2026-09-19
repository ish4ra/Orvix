import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/source_provider_service.dart';

class TvSourceBrowserScreen extends StatefulWidget {
  const TvSourceBrowserScreen({
    super.key,
    required this.sources,
    required this.item,
    required this.resultsFuture,
    this.episode,
  });

  final SourceProviderService sources;
  final MediaItem item;
  final EpisodeItem? episode;
  final Future<List<SourceResult>> resultsFuture;

  @override
  State<TvSourceBrowserScreen> createState() => _TvSourceBrowserScreenState();
}

class _TvSourceBrowserScreenState extends State<TvSourceBrowserScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  List<SourceResult> _results = const [];
  List<SourceSortCriterion> _priority = [
    ...SourceProviderService.defaultPriority,
  ];
  int _resultLimit = 0;
  String? _pinnedIdentity;
  bool _loading = true;
  String? _error;
  bool _compatibilityOnly = true;
  _TvSourceSort _sort = _TvSourceSort.free;

  String get _pinKey =>
      widget.sources.sourceTargetKey(widget.item, episode: widget.episode);

  bool get _seriesWidePin => widget.item.kind == MediaKind.series;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: .48,
      upperBound: .9,
    )..repeat(reverse: true);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        widget.resultsFuture,
        widget.sources.getPriorityOrder(),
        widget.sources.getResultLimit(),
        widget.sources.getPinnedSourceIdentity(_pinKey),
      ]);
      if (!mounted) return;
      setState(() {
        _results = values[0] as List<SourceResult>;
        _priority = values[1] as List<SourceSortCriterion>;
        _resultLimit = values[2] as int;
        _pinnedIdentity = values[3] as String?;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  List<SourceResult> get _visibleResults {
    List<SourceResult> sorted;
    switch (_sort) {
      case _TvSourceSort.best:
        sorted = widget.sources.sortResults(_results, _priority);
      case _TvSourceSort.free:
        sorted = widget.sources.sortForFreeStreaming(_results);
      case _TvSourceSort.smooth:
        sorted = widget.sources.sortForSmoothPlayback(_results);
    }

    if (_compatibilityOnly) {
      sorted = sorted
          .where((source) => source.compatibilityFriendly)
          .toList(growable: false);
    }

    final ordered = [...sorted];
    if (_pinnedIdentity != null) {
      final pinnedIndex = ordered.indexWhere(
        (source) => widget.sources.matchesPinned(
          source,
          _pinnedIdentity,
          seriesWide: _seriesWidePin,
        ),
      );
      if (pinnedIndex > 0) {
        final pinned = ordered.removeAt(pinnedIndex);
        ordered.insert(0, pinned);
      }
    }

    if (_resultLimit > 0 && ordered.length > _resultLimit) {
      return ordered.take(_resultLimit).toList(growable: false);
    }
    return ordered;
  }

  Future<void> _togglePin(SourceResult source) async {
    final pinned = widget.sources.matchesPinned(
      source,
      _pinnedIdentity,
      seriesWide: _seriesWidePin,
    );
    if (pinned) {
      await widget.sources.unpinSource(_pinKey);
      if (mounted) setState(() => _pinnedIdentity = null);
      return;
    }

    await widget.sources.pinSource(
      _pinKey,
      source,
      seriesWide: _seriesWidePin,
    );
    if (!mounted) return;
    setState(() {
      _pinnedIdentity = widget.sources.sourceIdentity(
        source,
        seriesWide: _seriesWidePin,
      );
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.episode == null
        ? widget.item.title
        : '${widget.item.title} • ${widget.episode!.label}';

    return Scaffold(
      backgroundColor: const Color(0xFF050806),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TvRoundButton(
                    tooltip: 'Back',
                    icon: Icons.arrow_back_rounded,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Choose a source',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.35,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9FAAA0),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!_loading && _error == null)
                    _CountPill(count: _visibleResults.length),
                ],
              ),
              const SizedBox(height: 20),
              _buildFilterBar(),
              const SizedBox(height: 18),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  child: _loading
                      ? _buildSkeleton()
                      : _error != null
                          ? _buildError()
                          : _buildResults(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Row(
      children: [
        _TvFilterPill(
          selected: _sort == _TvSourceSort.free,
          icon: Icons.bolt_rounded,
          label: 'Free',
          onPressed: () => setState(() => _sort = _TvSourceSort.free),
        ),
        const SizedBox(width: 10),
        _TvFilterPill(
          selected: _sort == _TvSourceSort.smooth,
          icon: Icons.speed_rounded,
          label: 'Smooth',
          onPressed: () => setState(() => _sort = _TvSourceSort.smooth),
        ),
        const SizedBox(width: 10),
        _TvFilterPill(
          selected: _sort == _TvSourceSort.best,
          icon: Icons.auto_awesome_rounded,
          label: 'Best',
          onPressed: () => setState(() => _sort = _TvSourceSort.best),
        ),
        const SizedBox(width: 10),
        _TvFilterPill(
          selected: _compatibilityOnly,
          icon: Icons.verified_rounded,
          label: 'TV safe',
          onPressed: () =>
              setState(() => _compatibilityOnly = !_compatibilityOnly),
        ),
        const Spacer(),
        const Text(
          'OK to play  •  ★ to pin',
          style: TextStyle(
            color: Color(0xFF7E8A80),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildSkeleton() {
    return FadeTransition(
      opacity: _pulse,
      child: ListView.separated(
        key: const ValueKey('tv-source-loading'),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 7,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, index) => Container(
          height: 76,
          decoration: BoxDecoration(
            color: const Color(0xFF101611),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF19221A)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Container(
                  width: 72,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B251C),
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Container(
                    height: 15,
                    decoration: BoxDecoration(
                      color: const Color(0xFF182019),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(width: 80),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      key: const ValueKey('tv-source-error'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 54),
            const SizedBox(height: 16),
            const Text(
              'Could not load sources',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Unknown source error.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9FAAA0), height: 1.4),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final results = _visibleResults;
    if (results.isEmpty) {
      return const Center(
        key: ValueKey('tv-source-empty'),
        child: Text(
          'No sources match the current TV-safe filters.',
          style: TextStyle(color: Color(0xFF9FAAA0)),
        ),
      );
    }

    return ListView.separated(
      key: const ValueKey('tv-source-results'),
      cacheExtent: 900,
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final source = results[index];
        final pinned = widget.sources.matchesPinned(
          source,
          _pinnedIdentity,
          seriesWide: _seriesWidePin,
        );
        return RepaintBoundary(
          child: _TvSourceTile(
            source: source,
            pinned: pinned,
            autofocus: index == 0,
            onPlay: () => Navigator.of(context).pop(source),
            onPin: () => _togglePin(source),
          ),
        );
      },
    );
  }
}

enum _TvSourceSort { free, smooth, best }

class _TvSourceTile extends StatefulWidget {
  const _TvSourceTile({
    required this.source,
    required this.pinned,
    required this.onPlay,
    required this.onPin,
    this.autofocus = false,
  });

  final SourceResult source;
  final bool pinned;
  final VoidCallback onPlay;
  final VoidCallback onPin;
  final bool autofocus;

  @override
  State<_TvSourceTile> createState() => _TvSourceTileState();
}

class _TvSourceTileState extends State<_TvSourceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final titleParts = source.title.split('\n');
    final release = titleParts.isEmpty ? source.title : titleParts.last.trim();
    final focus = Theme.of(context).colorScheme.primary;

    return AnimatedScale(
      scale: _focused ? 1.012 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        height: 78,
        decoration: BoxDecoration(
          color: _focused ? const Color(0xFF151E16) : const Color(0xFF0C120D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused ? focus : const Color(0xFF1B271D),
            width: _focused ? 2 : 1,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: focus.withValues(alpha: .18),
                    blurRadius: 20,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(16),
          focusColor: Colors.transparent,
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.onPlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 86,
                  child: Text(
                    source.quality ?? source.releaseQuality ?? 'SOURCE',
                    style: TextStyle(
                      color: source.compatibilityFriendly
                          ? focus
                          : const Color(0xFFFFC56B),
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        release,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        [
                          source.provider,
                          if (source.releaseQuality != null)
                            source.releaseQuality!,
                          if (source.cached) 'Cached',
                          source.isMagnet ? 'P2P' : 'Direct',
                        ].join('  •  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF8E9A90),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _MiniStat(
                  icon: Icons.people_alt_outlined,
                  text: source.seeders?.toString() ?? '—',
                ),
                const SizedBox(width: 18),
                _MiniStat(
                  icon: Icons.storage_rounded,
                  text: _formatBytes(source.sizeBytes),
                ),
                const SizedBox(width: 14),
                IconButton(
                  tooltip: widget.pinned ? 'Unpin release' : 'Pin release',
                  onPressed: widget.onPin,
                  icon: Icon(
                    widget.pinned
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: widget.pinned ? focus : null,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: _focused ? focus : const Color(0xFF6E786F),
                  size: 30,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF79837B)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFADB6AF),
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvFilterPill extends StatelessWidget {
  const _TvFilterPill({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(
          selected ? primary.withValues(alpha: .16) : const Color(0xFF0D130E),
        ),
        foregroundColor:
            WidgetStatePropertyAll(selected ? primary : const Color(0xFFD9E0DA)),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? Colors.white
                : selected
                    ? primary.withValues(alpha: .55)
                    : const Color(0xFF253027),
            width: states.contains(WidgetState.focused) ? 2 : 1,
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      icon: Icon(icon, size: 19),
      label: Text(label),
    );
  }
}

class _TvRoundButton extends StatelessWidget {
  const _TvRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: tooltip,
      onPressed: onPressed,
      style: ButtonStyle(
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? const BorderSide(color: Colors.white, width: 2)
              : BorderSide.none,
        ),
      ),
      icon: Icon(icon),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF111812),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF263128)),
      ),
      child: Text(
        '$count sources',
        style: const TextStyle(
          color: Color(0xFFABB5AD),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
