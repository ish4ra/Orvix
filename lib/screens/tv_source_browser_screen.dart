import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/free_p2p_live_probe_service.dart';
import '../services/source_ranking_diagnostics.dart';
import '../services/source_provider_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../utils/tv_keys.dart';

/// Android TV source picker.
///
/// Remote-first Android TV source picker.
///
/// Source modes share the same provider data and priority settings as mobile.
/// Free P2P adds reliability-oriented ordering and small, explicit hints; hold
/// OK opens the pin confirmation through a keyboard state machine rather than
/// relying on pointer long-press gestures.
class TvSourceBrowserScreen extends StatefulWidget {
  const TvSourceBrowserScreen({
    super.key,
    required this.sources,
    required this.item,
    required this.resultsFuture,
    this.episode,
    this.onPlaySource,
    this.preferFreeP2p = true,
    this.probeSession,
  });

  final SourceProviderService sources;
  final MediaItem item;
  final EpisodeItem? episode;
  final Future<List<SourceResult>> resultsFuture;
  final Future<void> Function(SourceResult source)? onPlaySource;
  final bool preferFreeP2p;

  /// Live-probe evidence already gathered by Normal Play. When provided, the
  /// browser shows and ranks with it instead of re-probing from scratch; the
  /// caller owns its release.
  final FreeP2pLiveProbeService? probeSession;

  @override
  State<TvSourceBrowserScreen> createState() => _TvSourceBrowserScreenState();
}

class _TvSourceBrowserScreenState extends State<TvSourceBrowserScreen> {
  List<SourceResult> _results = const [];
  bool _loading = true;
  String? _error;
  String? _openingResource;
  List<SourceSortCriterion> _priority = [
    ...SourceProviderService.defaultPriority,
  ];
  String? _pinnedIdentity;
  String? _providerFilter;
  bool _compatibilityOnly = false;
  late _TvSourceSort _sort;
  late final FreeP2pLiveProbeService _liveProbe;
  bool _liveProbeStarted = false;
  bool _probeHandedToPlayback = false;

  String get _pinKey =>
      widget.sources.sourceTargetKey(widget.item, episode: widget.episode);

  bool get _seriesWidePin => widget.item.kind == MediaKind.series;

  @override
  void initState() {
    super.initState();
    _liveProbe = widget.probeSession ??
        FreeP2pLiveProbeService(
          mediaDuration:
              FreeP2pLiveProbeService.parseMediaRuntime(widget.item.runtime),
        );
    _liveProbeStarted = _liveProbe.hasAnyResult;
    _sort =
        widget.preferFreeP2p ? _TvSourceSort.free : _TvSourceSort.best;
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      // Remove only the legacy TV pins created by the experimental long-press
      // browser. This runs once and leaves normal mobile/desktop behavior alone.
      await widget.sources.clearLegacyTvPinsOnce();

      final resultsFuture = refresh
          ? widget.sources.resolve(
              widget.item,
              episode: widget.episode,
              includeLowQuality: true,
              forceRefresh: true,
            )
          : widget.resultsFuture;

      final values = await Future.wait<dynamic>([
        resultsFuture,
        widget.sources.getPriorityOrder(),
        widget.sources.getPinnedSourceIdentity(_pinKey),
      ]);

      if (!mounted) return;
      setState(() {
        _results = values[0] as List<SourceResult>;
        _priority = values[1] as List<SourceSortCriterion>;
        _pinnedIdentity = values[2] as String?;
        _loading = false;
        _error = null;
        if (refresh) {
          _liveProbe.clear();
          _liveProbeStarted = false;
        }
      });
      // Sources are browsable and playable at once. No torrent is checked
      // automatically; "Re-check live" runs a check only when asked.
      _recordRanking();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _startLiveProbe() {
    if (_liveProbeStarted || _results.isEmpty) return;
    _liveProbeStarted = true;
    unawaited(
      _liveProbe
          .probeTopCandidates(
            _results,
            widget.sources,
            onUpdate: () {
              if (mounted) setState(() {});
            },
          )
          .catchError((_) {}),
    );
  }

  void _recordRanking() {
    final episode = widget.episode;
    final item = widget.item;
    SourceRankingSnapshot.record(
      SourceRankingSnapshot.capture(
        sources: widget.sources,
        target: episode == null
            ? '${item.kind.name}:${item.id}'
            : '${item.kind.name}:${item.id}:${episode.season}:${episode.episode}',
        resolved: _results,
        displayed: _visibleResults,
        mode: switch (_sort) {
          _TvSourceSort.free => 'freeP2p',
          _TvSourceSort.smooth => 'smooth',
          _TvSourceSort.best => 'priority',
        },
        priority: _priority,
        cloudConnected: !widget.preferFreeP2p,
        compatibilityOnly: _compatibilityOnly,
        isPinned: (source) => widget.sources.matchesPinned(
          source,
          _pinnedIdentity,
          seriesWide: _seriesWidePin,
        ),
        liveProbe: _liveProbe,
      ),
    );
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
      case _TvSourceSort.free:
        sorted = _liveProbe.rank(_results, widget.sources);
      case _TvSourceSort.smooth:
        sorted = widget.sources.sortForSmoothPlayback(_results);
      case _TvSourceSort.best:
        sorted = widget.sources.sortResults(_results, _priority);
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

    var ordered = [...sorted];
    if (_pinnedIdentity != null) {
      bool isPinned(SourceResult source) => widget.sources.matchesPinned(
            source,
            _pinnedIdentity,
            seriesWide: _seriesWidePin,
          );
      if (_sort == _TvSourceSort.free) {
        // Same pin rule as mobile/desktop: a pin confirmed unplayable does not
        // hold a confirmed-live torrent below it.
        ordered = _liveProbe.applyPinnedPreference(ordered, isPinned);
      } else {
        final pinnedIndex = ordered.indexWhere(isPinned);
        if (pinnedIndex > 0) {
          final pinned = ordered.removeAt(pinnedIndex);
          ordered.insert(0, pinned);
        }
      }
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
      builder: (dialogContext) => TvHeldKeyGuard(
        child: AlertDialog(
        backgroundColor: const Color(0xFF121613),
        title: Text(pinned ? 'Unpin this source?' : 'Pin this source?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            pinned
                ? 'Stop keeping this release at the top for this title.'
                : 'Keep this release at the top for this title'
                    '${_seriesWidePin ? ' and matching episodes' : ''}?\n\n'
                    '$release',
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFC7CEC8),
              height: 1.4,
            ),
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
      ),
    );

    if (confirmed == true && mounted) {
      await _togglePin(source);
    }
  }

  Future<void> _showPriorityEditor() async {
    final working = [..._priority];
    final saved = await showDialog<List<SourceSortCriterion>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF121613),
          title: const Text('Source priority'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This is the same priority used by Android/mobile. #1 wins first when Default mode is selected.',
                  style: TextStyle(
                    color: Color(0xFFB8C0BA),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView.separated(
                    itemCount: working.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final criterion = working[index];
                      return Container(
                        key: ValueKey(criterion.name),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF181D19),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF303832),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF232A24),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                criterion.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Move up',
                              onPressed: index == 0
                                  ? null
                                  : () {
                                      setDialogState(() {
                                        final item = working.removeAt(index);
                                        working.insert(index - 1, item);
                                      });
                                    },
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            ),
                            IconButton(
                              tooltip: 'Move down',
                              onPressed: index == working.length - 1
                                  ? null
                                  : () {
                                      setDialogState(() {
                                        final item = working.removeAt(index);
                                        working.insert(index + 1, item);
                                      });
                                    },
                              icon:
                                  const Icon(Icons.keyboard_arrow_down_rounded),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop([
                ...SourceProviderService.defaultPriority,
              ]),
              child: const Text('Reset'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(working),
              child: const Text('Save order'),
            ),
          ],
        ),
      ),
    );

    if (saved == null || !mounted) return;
    await widget.sources.setPriorityOrder(saved);
    if (!mounted) return;
    setState(() => _priority = saved);
  }

  Future<void> _showSourceModeHelp() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121613),
        title: const Text('Source modes'),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 620),
          child: Text(
            'Free P2P: ranks sources by what is playing right now. Torrents that delivered real media bytes in the live check come first, then unchecked ones, then torrents whose metadata did not resolve, then torrents with no usable data. Among live torrents: first-byte speed, real throughput against the file\'s bitrate, and live peers decide; quality only breaks ties. Provider seeder counts are a snapshot, not proof a torrent works.\n\n'
            'Smooth: favors TV-friendly formats, 1080p/720p, efficient codecs, healthy seeders and smaller files.\n\n'
            'Default: uses your normal Orvix source-priority settings.\n\n'
            'Compatible only: hides sources that look risky for a typical TV decoder, such as 8K, AV1, Hi10P/10-bit AVC, or Dolby Vision-only releases. It does not change the player or torrent engine.',
            style: TextStyle(
              color: Color(0xFFC7CEC8),
              height: 1.45,
            ),
          ),
        ),
        actions: [
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _play(SourceResult source) async {
    if (_openingResource != null) return;
    // Busy from the first OK, so a second press cannot open a second player.
    setState(() => _openingResource = source.resource);

    // Any source plays when chosen, checked or not. A running Re-check
    // stops here so its probes never compete with the chosen stream.
    await _liveProbe.prepareForPlayback(source);
    _probeHandedToPlayback = true;

    final callback = widget.onPlaySource;
    if (callback == null) {
      if (mounted) Navigator.of(context).pop(source);
      return;
    }

    try {
      await callback(source);
      // The player closed and this browser is shown again.
      _liveProbe.resumeAfterPlayback();
      _probeHandedToPlayback = false;
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Could not play this source: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } finally {
      if (mounted) setState(() => _openingResource = null);
    }
  }

  @override
  void dispose() {
    if (!_probeHandedToPlayback) {
      unawaited(_liveProbe.release());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final title = episode == null
        ? widget.item.title
        : '${widget.item.title} • ${episode.label}';
    final subtitle = episode == null
        ? [
            if ((widget.item.year ?? '').trim().isNotEmpty) widget.item.year!,
            if ((widget.item.runtime ?? '').trim().isNotEmpty)
              widget.item.runtime!,
          ].join(' • ')
        : episode.title.trim();
    final art = (widget.item.background ?? '').trim().isNotEmpty
        ? widget.item.background
        : widget.item.poster;
    final visibleCount =
        _loading || _error != null ? null : _visibleResults.length;

    return Scaffold(
      backgroundColor: TvColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Title artwork behind a fixed scrim: no live blur, so it costs
          // one decoded image and two gradients on low-end TV hardware.
          if ((art ?? '').trim().isNotEmpty)
            Positioned.fill(
              child: Opacity(
                opacity: .42,
                child: TvNetworkImage(
                  key: const ValueKey('tv-picker-backdrop'),
                  url: art,
                  cacheWidth: tvCacheWidth(context, 960, max: 1280),
                  alignment: Alignment.topRight,
                  placeholder: const SizedBox.shrink(),
                ),
              ),
            ),
          const Positioned.fill(child: _TvSourceScrim()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 22, 36, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _TvHeaderButton(
                        tooltip: 'Back',
                        icon: Icons.arrow_back_rounded,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Choose source',
                              style: TextStyle(
                                color: TvColors.primary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: TvColors.text,
                                fontSize: 25,
                                height: 1.15,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -.4,
                              ),
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: TvColors.textMuted,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      if (visibleCount != null)
                        _TvCountCapsule(
                          shown: visibleCount,
                          total: _results.length,
                        ),
                      const SizedBox(width: 12),
                      _TvHeaderButton(
                        tooltip: 'Refresh',
                        icon: Icons.refresh_rounded,
                        onPressed:
                            _loading ? null : () => _load(refresh: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _sourceControls(),
                  const SizedBox(height: 12),
                  Expanded(child: _body()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceControls() {
    final free = _sort == _TvSourceSort.free;
    final liveSummary =
        free && !_loading ? _liveProbe.summary(_results).text : null;
    // Rows of controls grow with the TV's text size instead of clipping it.
    final scaler = MediaQuery.textScalerOf(context);
    double rowHeight(double base) =>
        scaler.scale(base).clamp(base, base * 1.6).toDouble();
    int countFor(String? provider) => provider == null
        ? _results.length
        : _results.where((source) => source.provider == provider).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // How the list is ordered, and what it shows.
        SizedBox(
          height: rowHeight(42),
          child: ListView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            children: [
              _TvModeGroup(
                children: [
                  _TvFilterChip(
                    selected: _sort == _TvSourceSort.free,
                    segment: true,
                    label: 'Free P2P',
                    icon: Icons.bolt_rounded,
                    onPressed: () =>
                        setState(() => _sort = _TvSourceSort.free),
                  ),
                  _TvFilterChip(
                    selected: _sort == _TvSourceSort.smooth,
                    segment: true,
                    label: 'Smooth',
                    icon: Icons.speed_rounded,
                    onPressed: () =>
                        setState(() => _sort = _TvSourceSort.smooth),
                  ),
                  _TvFilterChip(
                    selected: _sort == _TvSourceSort.best,
                    segment: true,
                    label: 'Default',
                    icon: Icons.tune_rounded,
                    onPressed: () =>
                        setState(() => _sort = _TvSourceSort.best),
                  ),
                ],
              ),
              const _TvControlDivider(),
              _TvFilterChip(
                selected: _compatibilityOnly,
                toggle: true,
                label: 'Compatible only',
                icon: Icons.tv_rounded,
                onPressed: () => setState(
                  () => _compatibilityOnly = !_compatibilityOnly,
                ),
              ),
              const SizedBox(width: 6),
              _TvFilterChip(
                selected: false,
                label: 'Order',
                icon: Icons.swap_vert_rounded,
                onPressed: () => unawaited(_showPriorityEditor()),
              ),
              const SizedBox(width: 6),
              _TvFilterChip(
                selected: false,
                label: 'What are these?',
                icon: Icons.help_outline_rounded,
                onPressed: () => unawaited(_showSourceModeHelp()),
              ),
              if (free) ...[
                const SizedBox(width: 6),
                _TvFilterChip(
                  selected: false,
                  busy: _liveProbe.isRunning,
                  label: 'Re-check live',
                  icon: Icons.radar_rounded,
                  onPressed: _recheckLive,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Which provider's results are listed.
        SizedBox(
          height: rowHeight(34),
          child: ListView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            children: [
              _TvProviderTab(
                selected: _providerFilter == null,
                label: 'All',
                count: _loading ? null : countFor(null),
                onPressed: () => setState(() => _providerFilter = null),
              ),
              for (final provider in _providers) ...[
                const SizedBox(width: 4),
                _TvProviderTab(
                  selected: _providerFilter == provider,
                  label: provider,
                  count: countFor(provider),
                  onPressed: () =>
                      setState(() => _providerFilter = provider),
                ),
              ],
            ],
          ),
        ),
        if (free && liveSummary != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _liveProbe.isRunning
                    ? Icons.radar_rounded
                    : Icons.sensors_rounded,
                size: 15,
                color: _liveProbe.noLiveConfirmed
                    ? TvColors.textDim
                    : TvColors.primary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _liveProbe.noLiveConfirmed
                      ? '$liveSummary — no source delivered live data; choose one or re-check'
                      : liveSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.caption,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Live health replaces the static provider-metadata assessment once a
  /// source has been checked; unchecked sources keep the static hint.
  FreeSourceAssessment _freeAssessment(SourceResult source) {
    final health = _liveProbe.healthFor(source);
    if (health == null) return widget.sources.assessFreePlayback(source);
    final checking = health.state == FreeP2pHealthState.checking;
    return FreeSourceAssessment(
      label: health.label,
      detail: health.metrics ??
          (checking
              ? 'Checking whether this torrent delivers media right now.'
              : health.isLive
                  ? 'Delivered real media bytes in the live check.'
                  : 'Did not deliver usable media in the live check.'),
      recommended: health.isLive,
      warning: !health.isLive && !checking,
    );
  }

  void _recheckLive() {
    if (_liveProbe.isRunning || _results.isEmpty) return;
    setState(() {
      _liveProbe.clear();
      _liveProbeStarted = false;
    });
    _startLiveProbe();
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: _TvPickerMessage(
          key: ValueKey('tv-sources-loading'),
          busy: true,
          title: 'Finding sources…',
          message: 'Asking your source providers. This can take a few seconds.',
        ),
      );
    }

    final error = _error;
    if (error != null) {
      return Center(
        child: _TvPickerMessage(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load sources',
          message: error,
          action: FilledButton.icon(
            autofocus: true,
            onPressed: () => _load(refresh: true),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ),
      );
    }

    final visible = _visibleResults;

    if (visible.isEmpty) {
      final filtered = _providerFilter != null || _compatibilityOnly;
      return Center(
        child: _TvPickerMessage(
          icon: Icons.filter_alt_off_rounded,
          title: 'No sources match the current filters.',
          message: _results.isEmpty
              ? 'Your providers returned nothing for this title. Refresh, or '
                  'check your source providers in Settings.'
              : '${_results.length} sources are hidden by the filters.',
          action: filtered
              ? FilledButton.icon(
                  key: const ValueKey('tv-sources-clear-filters'),
                  autofocus: true,
                  onPressed: () => setState(() {
                    _providerFilter = null;
                    _compatibilityOnly = false;
                  }),
                  icon: const Icon(Icons.filter_alt_off_rounded),
                  label: const Text('Show all sources'),
                )
              : null,
        ),
      );
    }

    String rowKey(SourceResult source) =>
        'tv-source-${widget.sources.sourceIdentity(source, seriesWide: false)}';
    final indexByKey = <String, int>{
      for (var i = 0; i < visible.length; i++) rowKey(visible[i]): i,
    };

    // ListView.builder with findChildIndexCallback keeps each row's element,
    // and therefore its focus, attached to the same source when a live-check
    // checkpoint reorders the list. Focus follows the source instead of
    // jumping to whichever row now occupies the old index.
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 36),
      itemCount: visible.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? indexByKey[key.value] : null,
      itemBuilder: (context, index) {
        final source = visible[index];
        final pinned = widget.sources.matchesPinned(
          source,
          _pinnedIdentity,
          seriesWide: _seriesWidePin,
        );
        final free = _sort == _TvSourceSort.free;
        return Padding(
          key: ValueKey(rowKey(source)),
          padding: EdgeInsets.only(
            bottom: index == visible.length - 1 ? 0 : 8,
          ),
          child: _TvSourceRow(
            source: source,
            assessment: free ? _freeAssessment(source) : null,
            freeP2p: free,
            pinned: pinned,
            autofocus: index == 0,
            busy: _openingResource == source.resource,
            onPressed: () => unawaited(_play(source)),
            onPinRequest: () => unawaited(_confirmPin(source)),
          ),
        );
      },
    );
  }
}

/// The release line of a source title. Orvix puts a summary line in front
/// of the release name ("🎞 BluRay • 📺 1080P • 👥 72 seeders • 💾 4 GB");
/// on TV that summary is shown as structured facts instead, so it is not
/// repeated above the name.
@visibleForTesting
String tvSourceReleaseName(String title) {
  final lines = title
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length > 1 &&
      lines.first.contains('👥') &&
      lines.first.contains('💾')) {
    return lines.skip(1).join(' • ');
  }
  return lines.join(' • ');
}

/// The short resolution label of the quality tile: 4K, 1080p, 720p…
@visibleForTesting
String tvSourceQualityLabel(SourceResult source) {
  final raw = (source.quality ?? source.releaseQuality ?? '').trim();
  if (raw.isEmpty) return '—';
  final upper = raw.toUpperCase();
  if (upper.contains('2160') || upper.contains('4K')) return '4K';
  final p = RegExp(r'^(\d{3,4})P$').firstMatch(upper);
  if (p != null) return '${p.group(1)}p';
  return upper;
}

/// Dims the artwork towards the list side and the bottom so every line of
/// text stays readable on any picture.
class _TvSourceScrim extends StatelessWidget {
  const _TvSourceScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xF7050806), Color(0xE0050806), Color(0x9E050806)],
          stops: [0, .55, 1],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00050806), Color(0xFF050806)],
            stops: [.35, .92],
          ),
        ),
      ),
    );
  }
}

class _TvCountCapsule extends StatelessWidget {
  const _TvCountCapsule({required this.shown, required this.total});

  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    final filtered = shown != total;
    return Container(
      key: const ValueKey('tv-sources-count'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: filtered ? '$shown' : '$total',
            style: const TextStyle(
              color: TvColors.text,
              fontWeight: FontWeight.w900,
            ),
          ),
          TextSpan(text: filtered ? ' of $total sources' : ' sources'),
        ]),
        style: const TextStyle(
          color: TvColors.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Loading, error and empty states of the list area.
class _TvPickerMessage extends StatelessWidget {
  const _TvPickerMessage({
    super.key,
    this.icon,
    this.busy = false,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData? icon;
  final bool busy;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: TvColors.primary,
                    ),
                  )
                : Icon(icon, size: 40, color: TvColors.textMuted),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TvText.section,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TvText.body,
          ),
          if (action != null) ...[
            const SizedBox(height: 18),
            action!,
          ],
        ],
      ),
    );
  }
}

class _TvSourceRow extends StatefulWidget {
  const _TvSourceRow({
    required this.source,
    required this.assessment,
    required this.freeP2p,
    required this.pinned,
    required this.autofocus,
    required this.busy,
    required this.onPressed,
    required this.onPinRequest,
  });

  final SourceResult source;
  final FreeSourceAssessment? assessment;

  /// Free P2P mode: provider seed/peer counts are labelled as reported
  /// snapshots so they are not read as live evidence.
  final bool freeP2p;
  final bool pinned;
  final bool autofocus;
  final bool busy;
  final VoidCallback onPressed;
  final VoidCallback onPinRequest;

  @override
  State<_TvSourceRow> createState() => _TvSourceRowState();
}

class _TvSourceRowState extends State<_TvSourceRow> {
  bool _focused = false;
  late final TvHoldOk _holdOk;

  @override
  void initState() {
    super.initState();
    _holdOk = TvHoldOk(
      onTap: () {
        if (!widget.busy) widget.onPressed();
      },
      onHold: () {
        if (!widget.busy) widget.onPinRequest();
      },
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (widget.busy) return KeyEventResult.handled;
    return _holdOk.handle(event);
  }

  @override
  void dispose() {
    _holdOk.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final focused = _focused;
    final reported = widget.freeP2p ? ' reported' : '';
    final assessment = widget.assessment;
    final facts = <(IconData, String)>[
      (Icons.extension_rounded, source.provider),
      if (source.sizeLabel != null) (Icons.sd_storage_rounded, source.sizeLabel!),
      if (source.seeders != null)
        (Icons.arrow_upward_rounded, '${source.seeders} seeders$reported'),
      if (source.peers != null)
        (Icons.people_alt_rounded, '${source.peers} peers$reported'),
      if (source.cached) (Icons.bolt_rounded, 'Cached'),
      (source.isMagnet ? Icons.hub_rounded : Icons.link_rounded,
          source.isMagnet ? 'P2P' : 'Direct'),
      if (source.preferredGroup) (Icons.star_rounded, 'Preferred group'),
    ];
    final recommended = assessment?.recommended ?? false;
    final warning = assessment?.warning ?? false;

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        if (!value) {
          _holdOk.reset();
        }
        setState(() => _focused = value);
        if (value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _focused) tvReveal(context, margin: 24);
          });
        }
      },
      onKeyEvent: _handleKey,
      child: AnimatedContainer(
        duration: TvMetrics.focusDuration,
        decoration: BoxDecoration(
          color: focused ? const Color(0xF2162017) : const Color(0x8C0D120E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused ? TvColors.primary : const Color(0x14FFFFFF),
            width: focused ? 2 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            onTap: widget.busy ? null : widget.onPressed,
            onLongPress: widget.busy ? null : widget.onPinRequest,
            borderRadius: BorderRadius.circular(14),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Recommended (live or reliable) sources carry a lime edge.
                  AnimatedContainer(
                    duration: TvMetrics.focusDuration,
                    width: 4,
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: recommended
                          ? TvColors.primary
                          : warning
                              ? const Color(0xFF9B5A5A)
                              : Colors.transparent,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(4),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                      child: Row(
                        children: [
                          _TvQualityTile(source: source, focused: focused),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  tvSourceReleaseName(source.title),
                                  // The full name when focused, one tidy
                                  // line otherwise.
                                  maxLines: focused ? 2 : 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: focused
                                        ? TvColors.text
                                        : const Color(0xFFD9E0D7),
                                    fontSize: 15,
                                    height: 1.3,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Wrap(
                                  spacing: 14,
                                  runSpacing: 4,
                                  children: [
                                    for (final (icon, label) in facts)
                                      _TvSourceFact(
                                        icon: icon,
                                        label: label,
                                        focused: focused,
                                      ),
                                  ],
                                ),
                                if (assessment != null) ...[
                                  const SizedBox(height: 8),
                                  _TvAssessmentLine(assessment: assessment),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          _TvPlayAffordance(
                            focused: focused,
                            busy: widget.busy,
                            pinned: widget.pinned,
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
    );
  }
}

/// Resolution, large, with the release type under it. 4K is filled, 1080p
/// outlined in lime, everything else neutral.
class _TvQualityTile extends StatelessWidget {
  const _TvQualityTile({required this.source, required this.focused});

  final SourceResult source;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final label = tvSourceQualityLabel(source);
    final top = label == '4K';
    final hd = top || label == '1080p';
    final kind = source.quality != null ? source.releaseQuality : null;
    return Container(
      width: 72,
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: top
            ? TvColors.primary
            : hd
                ? const Color(0x1AB9FF45)
                : const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: top
              ? TvColors.primary
              : hd
                  ? TvColors.primary.withValues(alpha: .7)
                  : const Color(0x26FFFFFF),
          width: hd ? 1.4 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: top
                  ? TvColors.onPrimary
                  : hd
                      ? TvColors.lime
                      : TvColors.text,
              fontSize: 17,
              height: 1.1,
              fontWeight: FontWeight.w900,
              letterSpacing: -.2,
            ),
          ),
          if (kind != null) ...[
            const SizedBox(height: 2),
            Text(
              kind,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                color: top
                    ? TvColors.onPrimary.withValues(alpha: .75)
                    : TvColors.textMuted,
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TvSourceFact extends StatelessWidget {
  const _TvSourceFact({
    required this.icon,
    required this.label,
    required this.focused,
  });

  final IconData icon;
  final String label;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 14, color: focused ? TvColors.primary : TvColors.textDim),
        const SizedBox(width: 5),
        Text(
          label,
          style: TvText.caption.copyWith(
            color: focused ? const Color(0xFFD3DBD2) : TvColors.textMuted,
          ),
        ),
      ],
    );
  }
}

/// The Free P2P status: a small label (RECOMMENDED, LIVE, STALLED…) and the
/// reason in one line.
class _TvAssessmentLine extends StatelessWidget {
  const _TvAssessmentLine({required this.assessment});

  final FreeSourceAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color edge, Color text) = assessment.warning
        ? (const Color(0x332D1111), const Color(0xFF9B5A5A),
            const Color(0xFFE3AAAA))
        : assessment.recommended
            ? (const Color(0x33223815), const Color(0xFF86B84B),
                const Color(0xFFC9EAA5))
            : (const Color(0x33191E1A), const Color(0xFF4C554E),
                const Color(0xFFB2BBB4));
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: edge),
          ),
          child: Text(
            assessment.label,
            style: TextStyle(
              color: text,
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              letterSpacing: .45,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            assessment.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TvText.caption.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// Play on OK; the hint under it tells that holding OK pins the source.
class _TvPlayAffordance extends StatelessWidget {
  const _TvPlayAffordance({
    required this.focused,
    required this.busy,
    required this.pinned,
  });

  final bool focused;
  final bool busy;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: TvColors.primary,
          ),
        ),
      );
    }
    final hintColor = pinned
        ? TvColors.primary
        : focused
            ? TvColors.textMuted
            : TvColors.textDim;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: TvMetrics.focusDuration,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: focused ? TvColors.primary : const Color(0x14FFFFFF),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.play_arrow_rounded,
              size: 26,
              color: focused ? TvColors.onPrimary : TvColors.textMuted,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 11,
                color: hintColor,
              ),
              const SizedBox(width: 3),
              Text(
                pinned ? 'Pinned' : 'Hold OK',
                style: TextStyle(
                  color: hintColor,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _TvSourceSort { free, smooth, best }

/// The three ordering modes as one segmented capsule.
class _TvModeGroup extends StatelessWidget {
  const _TvModeGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _TvControlDivider extends StatelessWidget {
  const _TvControlDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: VerticalDivider(width: 1, thickness: 1, color: Color(0x26FFFFFF)),
    );
  }
}

/// A picker control: a mode segment, a toggle, or a quiet action.
///
/// Focus is a light fill (white with dark text), selection is lime, so the
/// two never look alike.
class _TvFilterChip extends StatefulWidget {
  const _TvFilterChip({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.segment = false,
    this.toggle = false,
    this.busy = false,
  });

  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// One of the mode segments: selected is a lime fill.
  final bool segment;

  /// An on/off option: on shows a check and a lime tint.
  final bool toggle;

  /// A running action (Re-check live): the icon turns into a spinner.
  final bool busy;

  @override
  State<_TvFilterChip> createState() => _TvFilterChipState();
}

class _TvFilterChipState extends State<_TvFilterChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final focused = _focused;
    final Color fill;
    final Color foreground;
    if (focused) {
      fill = selected && widget.segment ? TvColors.primary : TvColors.text;
      foreground = TvColors.onPrimary;
    } else if (selected && widget.segment) {
      fill = TvColors.primary;
      foreground = TvColors.onPrimary;
    } else if (selected) {
      fill = const Color(0x24B9FF45);
      foreground = TvColors.lime;
    } else {
      fill = widget.segment ? Colors.transparent : const Color(0x0FFFFFFF);
      foreground = const Color(0xFFDCE2DC);
    }
    final icon = selected && widget.toggle ? Icons.check_rounded : widget.icon;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: TvMetrics.focusDuration,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: focused && selected && widget.segment
                ? TvColors.text
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            onFocusChange: (value) {
              setState(() => _focused = value);
              if (value) tvReveal(context, margin: 24);
            },
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.busy)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: foreground,
                      ),
                    )
                  else
                    Icon(icon, size: 17, color: foreground),
                  const SizedBox(width: 7),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
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

/// A provider filter: text with a count; the selected one is lime and
/// underlined, the focused one gets a light pill.
class _TvProviderTab extends StatefulWidget {
  const _TvProviderTab({
    required this.selected,
    required this.label,
    required this.count,
    required this.onPressed,
  });

  final bool selected;
  final String label;
  final int? count;
  final VoidCallback onPressed;

  @override
  State<_TvProviderTab> createState() => _TvProviderTabState();
}

class _TvProviderTabState extends State<_TvProviderTab> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final focused = _focused;
    final color = focused
        ? TvColors.onPrimary
        : selected
            ? TvColors.lime
            : TvColors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: TvMetrics.focusDuration,
        decoration: BoxDecoration(
          color: focused ? TvColors.text : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            onFocusChange: (value) {
              setState(() => _focused = value);
              if (value) tvReveal(context, margin: 24);
            },
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 12, 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.label != 'All') ...[
                        Icon(Icons.extension_rounded, size: 14, color: color),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: color,
                          fontSize: 13.5,
                          fontWeight:
                              selected ? FontWeight.w900 : FontWeight.w700,
                        ),
                      ),
                      if (widget.count != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${widget.count}',
                          style: TextStyle(
                            color: color.withValues(alpha: .7),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  AnimatedContainer(
                    duration: TvMetrics.focusDuration,
                    height: 2.5,
                    width: selected && !focused ? 22 : 0,
                    decoration: BoxDecoration(
                      color: TvColors.primary,
                      borderRadius: BorderRadius.circular(2),
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

/// Back and Refresh: round, quiet until focused.
class _TvHeaderButton extends StatefulWidget {
  const _TvHeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.autofocus = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  State<_TvHeaderButton> createState() => _TvHeaderButtonState();
}

class _TvHeaderButtonState extends State<_TvHeaderButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.tooltip,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: TvMetrics.focusDuration,
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: _focused ? TvColors.text : const Color(0x1AFFFFFF),
          shape: BoxShape.circle,
          border: Border.all(
            color: _focused ? TvColors.text : const Color(0x1FFFFFFF),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            autofocus: widget.autofocus,
            canRequestFocus: enabled,
            customBorder: const CircleBorder(),
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            onFocusChange: (value) => setState(() => _focused = value),
            onTap: widget.onPressed,
            child: Center(
              child: Icon(
                widget.icon,
                size: 24,
                color: _focused
                    ? TvColors.onPrimary
                    : enabled
                        ? TvColors.text
                        : TvColors.textDim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
