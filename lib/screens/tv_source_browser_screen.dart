import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/free_p2p_live_probe_service.dart';
import '../services/source_provider_service.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
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
    this.liveEvidence,
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

  /// Live-check results of earlier visits to this title, used when no
  /// [probeSession] is given so reopening the browser does not probe the
  /// same torrents again.
  final FreeP2pLiveEvidence? liveEvidence;

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
  SourceDisplayMode _mode = SourceDisplayMode.myPriority;
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
          evidence: widget.liveEvidence,
        );
    // Reopened after playback: keep the list the user chose from while its
    // evidence is fresh. Otherwise the open browser continues the bounded
    // check in the background.
    _liveProbeStarted = _liveProbe.isFrozen && _liveProbe.hasAnyResult;
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
        widget.sources.getDisplayMode(liveCheck: widget.preferFreeP2p),
      ]);

      if (!mounted) return;
      setState(() {
        _results = values[0] as List<SourceResult>;
        _priority = values[1] as List<SourceSortCriterion>;
        _liveProbe.setPriority(_priority);
        _pinnedIdentity = values[2] as String?;
        _mode = values[3] as SourceDisplayMode;
        _liveProbe.setDisplayMode(_mode);
        _loading = false;
        _error = null;
        if (refresh) {
          _liveProbe.clear();
          _liveProbeStarted = false;
        }
      });
      // The live check runs whatever the display mode.
      _startLiveProbe();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _startLiveProbe() {
    // Live probing belongs to the Free P2P playback path only; with a
    // cloud/debrid connection (preferFreeP2p false) playback never uses it.
    if (!widget.preferFreeP2p || _liveProbeStarted || _results.isEmpty) {
      return;
    }
    _liveProbeStarted = true;
    // A new check owns new probes and warm sessions, so leaving the browser
    // must release them again even after an earlier source was played.
    _probeHandedToPlayback = false;
    unawaited(
      _liveProbe
          .probeTopCandidates(
            _results,
            widget.sources,
            continueInBackground: true,
            // An unchecked pin is checked in the first batch.
            preferred: _results.where(_isPinned).firstOrNull,
            onUpdate: () {
              if (mounted) setState(() {});
            },
          )
          .catchError((_) {}),
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

  bool _isPinned(SourceResult source) => widget.sources.matchesPinned(
        source,
        _pinnedIdentity,
        seriesWide: _seriesWidePin,
      );

  List<SourceResult> get _visibleResults {
    // Free P2P: every display mode keeps the live-health groups.
    var sorted = widget.preferFreeP2p
        ? _liveProbe.rank(_results, widget.sources)
        : switch (_mode) {
            SourceDisplayMode.recommended =>
              widget.sources.sortRecommended(_results),
            SourceDisplayMode.myPriority =>
              widget.sources.sortResults(_results, _priority),
            SourceDisplayMode.smooth =>
              widget.sources.sortForSmoothPlayback(_results),
          };

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
      if (widget.preferFreeP2p) {
        // Same pin rule as mobile/desktop: a pin confirmed unplayable does not
        // hold a confirmed-live torrent below it.
        ordered = _liveProbe.applyPinnedPreference(ordered, _isPinned);
      } else {
        final pinnedIndex = ordered.indexWhere(_isPinned);
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
                  'This is the same priority used by Android/mobile. #1 wins first when My Priority is selected; saving selects it.',
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
    // Saving an Order is a request to sort by it: rows reorder at once under
    // My Priority, and the background check also follows it.
    await widget.sources.setDisplayMode(SourceDisplayMode.myPriority);
    if (!mounted) return;
    setState(() {
      _priority = saved;
      _liveProbe.setPriority(saved);
      _mode = SourceDisplayMode.myPriority;
      _liveProbe.setDisplayMode(_mode);
    });
  }

  void _selectMode(SourceDisplayMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _liveProbe.setDisplayMode(mode);
    });
    unawaited(widget.sources.setDisplayMode(mode));
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
            'Without a cloud/debrid account, Orvix checks torrents live. Every mode keeps the same groups: direct links, then torrents that delivered real media bytes (ready now, live, then slow), then not checked yet, then metadata slow, then torrents that failed the check, at the bottom and still selectable. Provider seeder counts are a reported snapshot, not proof a torrent works.\n\n'
            'Recommended: inside each group, measured first byte, real speed and live peers, then the most playable files.\n\n'
            'My Priority: inside each group, your Order setting.\n\n'
            'Smooth: inside each group, TV-friendly formats, 1080p/720p, efficient codecs, healthy seeders and smaller files.\n\n'
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

    if (widget.preferFreeP2p) {
      await _liveProbe.prepareForPlayback(source);
      _probeHandedToPlayback = true;
    }

    final callback = widget.onPlaySource;
    if (callback == null) {
      Navigator.of(context).pop(source);
      return;
    }

    setState(() => _openingResource = source.resource);
    try {
      await callback(source);
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
    final title = widget.episode == null
        ? widget.item.title
        : '${widget.item.title} • ${widget.episode!.label}';

    return Scaffold(
      backgroundColor: const Color(0xFF080A09),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                      children: [
                        const Text(
                          'Choose source',
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
                    Text(
                      '${_results.length} sources',
                      style: const TextStyle(
                        color: Color(0xFFAEB6B0),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(width: 14),
                  _TvHeaderButton(
                    tooltip: 'Refresh',
                    icon: Icons.refresh_rounded,
                    onPressed: _loading ? null : () => _load(refresh: true),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _sourceControls(),
              const SizedBox(height: 14),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceControls() {
    final liveSummary = widget.preferFreeP2p && !_loading
        ? _liveProbe.summary(_results).text
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _TvFilterChip(
                selected: _providerFilter == null,
                label: 'All',
                icon: Icons.apps_rounded,
                onPressed: () => setState(() => _providerFilter = null),
              ),
              for (final provider in _providers) ...[
                const SizedBox(width: 8),
                _TvFilterChip(
                  selected: _providerFilter == provider,
                  label: provider,
                  icon: Icons.extension_rounded,
                  onPressed: () => setState(() => _providerFilter = provider),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final mode in SourceDisplayMode.values) ...[
                _TvFilterChip(
                  selected: _mode == mode,
                  label: mode.label,
                  icon: switch (mode) {
                    SourceDisplayMode.recommended => Icons.auto_awesome_rounded,
                    SourceDisplayMode.myPriority => Icons.tune_rounded,
                    SourceDisplayMode.smooth => Icons.speed_rounded,
                  },
                  onPressed: () => _selectMode(mode),
                ),
                const SizedBox(width: 8),
              ],
              _TvFilterChip(
                selected: false,
                label: 'Order',
                icon: Icons.swap_vert_rounded,
                onPressed: () => unawaited(_showPriorityEditor()),
              ),
              const SizedBox(width: 12),
              _TvFilterChip(
                selected: _compatibilityOnly,
                label: 'Compatible only',
                icon: Icons.tv_rounded,
                onPressed: () => setState(
                  () => _compatibilityOnly = !_compatibilityOnly,
                ),
              ),
              const SizedBox(width: 8),
              _TvFilterChip(
                selected: false,
                label: 'What are these?',
                icon: Icons.info_outline_rounded,
                onPressed: () => unawaited(_showSourceModeHelp()),
              ),
              if (widget.preferFreeP2p) ...[
                const SizedBox(width: 8),
                _TvFilterChip(
                  selected: false,
                  label: 'Re-check live',
                  icon: Icons.radar_rounded,
                  onPressed: _recheckLive,
                ),
                const SizedBox(width: 8),
                _TvFilterChip(
                  selected: false,
                  label: 'Live report',
                  icon: Icons.assignment_rounded,
                  onPressed: () => unawaited(_showLiveReport()),
                ),
              ],
            ],
          ),
        ),
        if (liveSummary != null) ...[
          const SizedBox(height: 8),
          Text(
            _liveProbe.noLiveConfirmed
                ? '$liveSummary — no source delivered live data; choose one or re-check'
                : liveSummary,
            style: const TextStyle(
              color: Color(0xFFAEB6B0),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  /// Live health replaces the static provider-metadata assessment once a
  /// source has been checked. An unchecked torrent reads NOT CHECKED and
  /// keeps the static hint as reported provider data, never as a failure.
  FreeSourceAssessment _freeAssessment(SourceResult source) {
    final health = _liveProbe.healthFor(source);
    if (health == null) {
      final reported = widget.sources.assessFreePlayback(source);
      if (!source.isMagnet) return reported;
      return FreeSourceAssessment(
        label: FreeP2pHealth.notChecked.label,
        detail: 'Not live-checked yet. Hint: ${reported.label} — '
            '${reported.detail}',
        recommended: false,
        warning: false,
      );
    }
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

  /// Shows the same live-check and playback report the mobile picker copies,
  /// so a TV failure can be read off the screen or copied.
  Future<void> _showLiveReport() async {
    final report = _liveProbe.diagnosticReport(_results);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121613),
        title: const Text('Live check and playback report'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 520),
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(
                color: Color(0xFFC7CEC8),
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => unawaited(
              Clipboard.setData(ClipboardData(text: report)),
            ),
            child: const Text('Copy'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Discards this browser's evidence (and any frozen order) and starts a
  /// fresh bounded check with the current Order setting.
  void _recheckLive() {
    if (!widget.preferFreeP2p || _results.isEmpty) return;
    setState(() {
      _liveProbe.clear();
      _liveProbeStarted = false;
    });
    _startLiveProbe();
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48),
              const SizedBox(height: 14),
              const Text(
                'Could not load sources',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFAAB2AC),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                autofocus: true,
                onPressed: () => _load(refresh: true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final visible = _visibleResults;

    if (visible.isEmpty) {
      return const Center(
        child: Text(
          'No sources match the current filters.',
          style: TextStyle(
            color: Color(0xFFB7BDB8),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    String rowKey(SourceResult source) =>
        'tv-source-${widget.sources.sourceIdentity(source, seriesWide: false)}';
    final indexByKey = <String, int>{
      for (var i = 0; i < visible.length; i++) rowKey(visible[i]): i,
    };
    final free = widget.preferFreeP2p;
    // Health-group labels; torrents that failed the live check sit together
    // at the bottom. Labels are not focusable and every row stays selectable.
    final groupHeaders = free
        ? _liveProbe.groupHeaders(visible, isPinned: _isPinned)
        : const <int, FreeP2pGroupHeader>{};

    // ListView.builder with findChildIndexCallback keeps each row's element,
    // and therefore its focus, attached to the same source when a live-check
    // checkpoint reorders the list. Focus follows the source instead of
    // jumping to whichever row now occupies the old index.
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 30),
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
        final row = _TvSourceRow(
          key: const ValueKey('tv-row-card'),
          source: source,
          assessment: free ? _freeAssessment(source) : null,
          freeP2p: free,
          pinned: pinned,
          autofocus: index == 0,
          busy: _openingResource == source.resource,
          onPressed: () => unawaited(_play(source)),
          onPinRequest: () => unawaited(_confirmPin(source)),
        );
        return Padding(
          key: ValueKey(rowKey(source)),
          padding: EdgeInsets.only(
            bottom: index == visible.length - 1 ? 0 : 10,
          ),
          // Same shape for every row, so a row that becomes the first failed
          // one keeps its element and therefore its focus.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (groupHeaders[index] case final header?)
                Padding(
                  key: ValueKey(header.group == FreeP2pGroup.failed
                      ? 'tv-free-p2p-failed-group'
                      : 'tv-free-p2p-group'),
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                  child: Text(
                    header.label,
                    style: TextStyle(
                      color: header.group == FreeP2pGroup.failed
                          ? const Color(0xFFFFB4A8)
                          : const Color(0xFFAEB6B0),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              row,
            ],
          ),
        );
      },
    );
  }
}

class _TvSourceRow extends StatefulWidget {
  const _TvSourceRow({
    super.key,
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
    final quality = (source.quality ?? source.releaseQuality ?? '—').toUpperCase();
    final top = quality.contains('2160') || quality.contains('4K');
    final hd = top || quality.contains('1080');
    final focused = _focused;
    final reported = widget.freeP2p ? ' reported' : '';
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
      child: AnimatedScale(
      scale: focused ? 1.01 : 1,
      duration: TvMetrics.focusDuration,
      child: AnimatedContainer(
      duration: TvMetrics.focusDuration,
      decoration: BoxDecoration(
        color: focused ? TvColors.cardFocused : TvColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: focused ? TvColors.primary : TvColors.border,
          width: focused ? TvMetrics.focusBorder : 1,
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
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 82,
                  height: 50,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: top ? TvColors.primary : TvColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: hd ? TvColors.primary : TvColors.borderStrong,
                      width: hd ? 1.6 : 1,
                    ),
                  ),
                  child: Text(
                    quality,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      color: top
                          ? TvColors.onPrimary
                          : hd
                              ? TvColors.lime
                              : TvColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused ? TvColors.text : const Color(0xFFDCE3DB),
                          fontSize: 14.5,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        children: [
                          for (final (icon, label) in facts)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon,
                                    size: 14,
                                    color: focused
                                        ? TvColors.primary
                                        : TvColors.textDim),
                                const SizedBox(width: 5),
                                Text(
                                  label,
                                  style: TvText.caption.copyWith(
                                    color: focused
                                        ? const Color(0xFFD3DBD2)
                                        : TvColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      if (widget.assessment != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: widget.assessment!.warning
                                    ? const Color(0x332D1111)
                                    : widget.assessment!.recommended
                                        ? const Color(0x33223815)
                                        : const Color(0x33191E1A),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: widget.assessment!.warning
                                      ? const Color(0xFF9B5A5A)
                                      : widget.assessment!.recommended
                                          ? const Color(0xFF86B84B)
                                          : const Color(0xFF4C554E),
                                ),
                              ),
                              child: Text(
                                widget.assessment!.label,
                                style: TextStyle(
                                  color: widget.assessment!.warning
                                      ? const Color(0xFFE3AAAA)
                                      : widget.assessment!.recommended
                                          ? const Color(0xFFC9EAA5)
                                          : const Color(0xFFB2BBB4),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: .45,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.assessment!.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TvText.caption.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                if (widget.busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: TvMetrics.focusDuration,
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: focused ? TvColors.primary : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 28,
                          color: focused ? TvColors.onPrimary : TvColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.pinned
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 12,
                            color: widget.pinned
                                ? TvColors.primary
                                : TvColors.textDim,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            widget.pinned ? 'Pinned' : 'Hold OK',
                            style: TextStyle(
                              color: widget.pinned
                                  ? TvColors.primary
                                  : TvColors.textDim,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
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


class _TvFilterChip extends StatefulWidget {
  const _TvFilterChip({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_TvFilterChip> createState() => _TvFilterChipState();
}

class _TvFilterChipState extends State<_TvFilterChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return AnimatedContainer(
      duration: TvMetrics.focusDuration,
      decoration: BoxDecoration(
        color: _focused
            ? TvColors.cardFocused
            : selected
                ? const Color(0xFF16220F)
                : TvColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused
              ? TvColors.primary
              : selected
                  ? TvColors.primary.withValues(alpha: .55)
                  : TvColors.border,
          width: _focused ? TvMetrics.focusBorder : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_rounded : widget.icon,
                  size: 18,
                  color: selected
                      ? const Color(0xFFB9FF45)
                      : const Color(0xFFCFD6D0),
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: selected
                        ? TvColors.lime
                        : const Color(0xFFE0E5E1),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
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
    return Material(
      color: _focused ? const Color(0xFF292E2A) : const Color(0xFF171B18),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        autofocus: widget.autofocus,
        canRequestFocus: widget.onPressed != null,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        onFocusChange: (value) => setState(() => _focused = value),
        onTap: widget.onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused ? TvColors.primary : const Color(0xFF303731),
              width: _focused ? TvMetrics.focusBorder : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 24),
        ),
      ),
    );
  }
}
