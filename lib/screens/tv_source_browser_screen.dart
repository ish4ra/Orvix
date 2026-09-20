import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  bool _compatibilityOnly = false;
  String? _providerFilter;
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

  Future<void> _load({bool refresh = false}) async {
    if (refresh && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final resultsFuture = refresh
          ? widget.sources.resolve(widget.item, episode: widget.episode)
          : widget.resultsFuture;
      final values = await Future.wait<dynamic>([
        resultsFuture,
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

  List<String> get _providers {
    final providers = <String>[];
    for (final source in _results) {
      final name = source.provider.trim();
      if (name.isNotEmpty && !providers.contains(name)) providers.add(name);
    }
    return providers;
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

    if (_providerFilter != null) {
      sorted = sorted
          .where((source) => source.provider == _providerFilter)
          .toList(growable: false);
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

  Future<void> _confirmPin(SourceResult source) async {
    final pinned = widget.sources.matchesPinned(
      source,
      _pinnedIdentity,
      seriesWide: _seriesWidePin,
    );
    final release = source.fileNameHint?.trim().isNotEmpty == true
        ? source.fileNameHint!.trim()
        : source.title.split('\n').last.trim();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121613),
        title: Text(pinned ? 'Unpin this source?' : 'Pin this source?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            pinned
                ? 'Orvix will stop keeping this release at the top for this title.'
                : 'Keep this release at the top for this title' +
                    (_seriesWidePin ? ' and matching episodes' : '') +
                    '?\n\n' + release,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFC7CEC8), height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: Icon(
              pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            ),
            label: Text(pinned ? 'Unpin' : 'Pin source'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _togglePin(source);
    }
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

    final backdrop = widget.episode?.thumbnail ?? widget.item.background;

    return Scaffold(
      backgroundColor: const Color(0xFF080A09),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop != null && backdrop.isNotEmpty)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              memCacheWidth: 1280,
              fadeInDuration: Duration.zero,
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFF080A09)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF080A09)),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xE6080A09),
                  Color(0xF2080A09),
                  Color(0xFF080A09),
                ],
                stops: [0, .42, .76],
              ),
            ),
          ),
          SafeArea(
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
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _TvFilterPill(
                selected: false,
                icon: Icons.refresh_rounded,
                label: 'Refresh',
                onPressed: _loading ? null : () => _load(refresh: true),
              ),
              const SizedBox(width: 8),
              _TvFilterPill(
                selected: _providerFilter == null,
                icon: Icons.apps_rounded,
                label: 'All sources',
                onPressed: () => setState(() => _providerFilter = null),
              ),
              for (final provider in _providers) ...[
                const SizedBox(width: 8),
                _TvFilterPill(
                  selected: _providerFilter == provider,
                  icon: Icons.extension_rounded,
                  label: provider,
                  onPressed: () => setState(() => _providerFilter = provider),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, right: 10),
              child: Text(
                'ORDER',
                style: TextStyle(
                  color: Color(0xFF8F9991),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Expanded(
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _TvFilterPill(
                      selected: _sort == _TvSourceSort.free,
                      icon: Icons.bolt_rounded,
                      label: 'Free',
                      onPressed: () =>
                          setState(() => _sort = _TvSourceSort.free),
                    ),
                    const SizedBox(width: 8),
                    _TvFilterPill(
                      selected: _sort == _TvSourceSort.smooth,
                      icon: Icons.speed_rounded,
                      label: 'Smooth',
                      onPressed: () =>
                          setState(() => _sort = _TvSourceSort.smooth),
                    ),
                    const SizedBox(width: 8),
                    _TvFilterPill(
                      selected: _sort == _TvSourceSort.best,
                      icon: Icons.auto_awesome_rounded,
                      label: 'Best',
                      onPressed: () =>
                          setState(() => _sort = _TvSourceSort.best),
                    ),
                    const SizedBox(width: 16),
                    _TvFilterPill(
                      selected: _compatibilityOnly,
                      icon: Icons.tv_rounded,
                      label: 'TV safe only',
                      onPressed: () => setState(
                        () => _compatibilityOnly = !_compatibilityOnly,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
          height: 132,
          decoration: BoxDecoration(
            color: const Color(0xFF101611),
            borderRadius: BorderRadius.circular(18),
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
          'No sources match the current filters.',
          style: TextStyle(
            color: Color(0xFFB1B7B2),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return ListView.separated(
      key: const ValueKey('tv-source-results'),
      cacheExtent: 1400,
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 34),
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 9),
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
            onPinRequest: () => _confirmPin(source),
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
    required this.onPinRequest,
    this.autofocus = false,
  });

  final SourceResult source;
  final bool pinned;
  final VoidCallback onPlay;
  final VoidCallback onPinRequest;
  final bool autofocus;

  @override
  State<_TvSourceTile> createState() => _TvSourceTileState();
}

class _TvSourceTileState extends State<_TvSourceTile> {
  final FocusNode _focusNode = FocusNode();
  Timer? _holdTimer;
  bool _holdTriggered = false;
  bool _focused = false;

  bool _isActivateKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.space;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_isActivateKey(event.logicalKey)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      if (_holdTimer == null && !_holdTriggered) {
        _holdTimer = Timer(const Duration(milliseconds: 650), () {
          _holdTimer = null;
          if (!mounted || !_focusNode.hasFocus) return;
          _holdTriggered = true;
          widget.onPinRequest();
        });
      }
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      final wasLongPress = _holdTriggered;
      _holdTimer?.cancel();
      _holdTimer = null;
      _holdTriggered = false;
      if (!wasLongPress) widget.onPlay();
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  void _onFocusChange(bool value) {
    if (!value) {
      _holdTimer?.cancel();
      _holdTimer = null;
      _holdTriggered = false;
    }
    if (mounted) setState(() => _focused = value);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final focus = Theme.of(context).colorScheme.primary;
    final combined =
        '${source.title} ${source.fileNameHint ?? ''}'.toLowerCase();
    final fileName = source.fileNameHint?.trim().isNotEmpty == true
        ? source.fileNameHint!.trim()
        : source.title.split('\n').last.trim();

    String? codec;
    if (RegExp(r'\b(?:x265|h[ ._-]?265|hevc)\b').hasMatch(combined)) {
      codec = 'HEVC';
    } else if (RegExp(r'\b(?:x264|h[ ._-]?264|avc)\b').hasMatch(combined)) {
      codec = 'AVC';
    } else if (RegExp(r'\b(?:av1|av01)\b').hasMatch(combined)) {
      codec = 'AV1';
    }

    String? audio;
    if (RegExp(r'\bdts(?:-hd)?\b').hasMatch(combined)) {
      audio = 'DTS';
    } else if (RegExp(r'\btruehd\b').hasMatch(combined)) {
      audio = 'TRUEHD';
    } else if (RegExp(r'\b(?:ddp|eac3)\b').hasMatch(combined)) {
      audio = 'DD+';
    } else if (RegExp(r'\bac3\b').hasMatch(combined)) {
      audio = 'AC3';
    } else if (RegExp(r'\baac\b').hasMatch(combined)) {
      audio = 'AAC';
    }

    final hdr = <String>[];
    if (RegExp(r'\b(?:dovi|dolby[ ._-]?vision|dv)\b').hasMatch(combined)) {
      hdr.add('DV');
    }
    if (RegExp(r'\bhdr10\+?\b|\bhdr\b').hasMatch(combined)) {
      hdr.add('HDR');
    }

    final heading = [
      source.provider,
      source.quality ?? source.releaseQuality ?? 'Source',
    ].join('  •  ');

    final statsLine = [
      if (source.releaseQuality != null) source.releaseQuality!,
      if (codec != null) codec,
      ...hdr,
      if (audio != null) audio,
      if (source.sizeLabel != null) source.sizeLabel!,
      if (source.seeders != null) '${source.seeders} seeders',
      source.isMagnet ? 'P2P' : 'Direct',
    ].join('  •  ');

    final badges = <String>[
      if (widget.pinned) 'PINNED',
      if (source.cached) 'CACHED',
      if (source.compatibilityFriendly) 'TV SAFE',
      if (source.quality != null) source.quality!.toUpperCase(),
      if (source.releaseQuality != null) source.releaseQuality!.toUpperCase(),
    ].toSet().take(4).toList(growable: false);

    return AnimatedScale(
      scale: _focused ? 1.008 : 1,
      duration: const Duration(milliseconds: 90),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        constraints: const BoxConstraints(minHeight: 112),
        decoration: BoxDecoration(
          color: _focused ? const Color(0xFF292E2A) : const Color(0xFF181D19),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused ? Colors.white : const Color(0xFF343B35),
            width: _focused ? 2.5 : 1,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .36),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ]
              : const [],
        ),
        child: Focus(
          autofocus: widget.autofocus,
          focusNode: _focusNode,
          onFocusChange: _onFocusChange,
          onKeyEvent: _onKey,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(16),
            focusColor: Colors.transparent,
            onTap: widget.onPlay,
            onLongPress: widget.onPinRequest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(17, 13, 16, 13),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                heading,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFF2F4F2),
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            if (badges.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              for (final badge in badges) ...[
                                _TvSourceBadge(
                                  text: badge,
                                  emphasized: badge == 'PINNED' || badge == 'TV SAFE',
                                ),
                                const SizedBox(width: 6),
                              ],
                            ],
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          statsLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFB6BDB7),
                            fontSize: 12.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF929B94),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.play_circle_fill_rounded,
                        size: 39,
                        color: _focused ? focus : const Color(0xFF89928B),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        widget.pinned ? 'Pinned' : 'Hold OK to pin',
                        style: TextStyle(
                          color: widget.pinned ? focus : const Color(0xFF89928B),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
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

class _TvSourceBadge extends StatelessWidget {
  const _TvSourceBadge({required this.text, required this.emphasized});

  final String text;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: emphasized
            ? primary.withValues(alpha: .12)
            : const Color(0xFF111512),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: emphasized
              ? primary.withValues(alpha: .6)
              : const Color(0xFF39423B),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: emphasized ? primary : const Color(0xFFC8CEC9),
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
class _TvFilterPill extends StatefulWidget {
  const _TvFilterPill({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_TvFilterPill> createState() => _TvFilterPillState();
}

class _TvFilterPillState extends State<_TvFilterPill> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final selected = widget.selected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      decoration: BoxDecoration(
        color: selected ? primary : const Color(0xFF111512),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: _focused
              ? Colors.white
              : selected
                  ? primary
                  : const Color(0xFF36413A),
          width: _focused ? 2.5 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: widget.onPressed != null,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : widget.icon,
                  size: 18,
                  color: selected
                      ? const Color(0xFF11160F)
                      : const Color(0xFFD2D9D3),
                ),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF11160F)
                        : const Color(0xFFE2E7E3),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
