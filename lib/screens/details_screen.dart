import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/media_item.dart';
import '../services/ai_sinhala_preferences_service.dart';
import '../services/ai_sinhala_subtitle_service.dart';
import '../services/ai_sinhala_trace_service.dart';
import '../services/catalog_service.dart';
import '../services/cloud_preferences_service.dart';
import '../services/free_p2p_auto_play.dart';
import '../services/free_p2p_live_probe_service.dart';
import '../services/free_p2p_playback_trace.dart';
import '../services/local_media_bridge_service.dart';
import '../services/local_torrent_service.dart';
import '../services/media_state_service.dart';
import '../services/orvix_media_engine_service.dart';
import '../services/online_subtitle_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/platform_profile.dart';
import '../services/playback_preparation.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/source_provider_service.dart';
import '../services/torbox_service.dart';
import '../services/real_debrid_service.dart';
import '../services/premiumize_service.dart';
import 'android_exo_player_screen.dart';
import 'player_screen.dart';
import 'sources_screen.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../widgets/horizontal_scroll_rail.dart';
import 'tv_source_browser_screen.dart';

class DetailsScreen extends StatefulWidget {
  const DetailsScreen({
    super.key,
    required this.item,
    required this.catalog,
    required this.pikpak,
    required this.transfer,
    required this.sources,
    required this.torbox,
    required this.cloudPreferences,
    required this.playback,
    required this.mediaState,
  });

  final MediaItem item;
  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final TorBoxService torbox;
  final CloudPreferencesService cloudPreferences;
  final PlaybackService playback;
  final MediaStateService mediaState;

  @override
  State<DetailsScreen> createState() => DetailsScreenState();
}

/// The MPV player route the details screen opens, as tests see it: they
/// replace the route with [DetailsScreenState.debugPlayerLauncher] and call
/// these callbacks the way the player does.
@visibleForTesting
class DebugPlayerLaunch {
  const DebugPlayerLaunch({
    required this.url,
    required this.source,
    required this.onPlaybackStarted,
    required this.onStartupFailed,
    required this.onStartupFallback,
  });

  final String url;
  final SourceResult? source;
  final VoidCallback? onPlaybackStarted;
  final ValueChanged<String>? onStartupFailed;
  final Future<void> Function(String message)? onStartupFallback;
}

class DetailsScreenState extends State<DetailsScreen> {
  /// Replaces the MPV player route in tests. Always null in the app.
  @visibleForTesting
  static Future<void> Function(DebugPlayerLaunch launch)? debugPlayerLauncher;

  /// Replaces the ExoPlayer route in tests. Always null in the app.
  @visibleForTesting
  static Future<AndroidExoPlayerResult?> Function(String url)? debugExoLauncher;

  static const _videoExtensions = <String>{
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'm4v',
    'webm',
    'ts',
    'm2ts',
    'mpg',
    'mpeg',
    'flv',
  };

  static const _weakTitleWords = <String>{
    'a',
    'an',
    'the',
    'of',
    'and',
    'or',
    'to',
    'in',
    'on',
    'for',
    'with',
  };

  late final Future<MediaItem> _detailsFuture;
  bool _resolving = false;
  bool _watchlisted = false;
  bool _inLibrary = false;
  String _status = '';
  double? _resolveProgress;
  int? _selectedSeason;

  // Source list -> chosen source -> player. The source sheet is closed while a
  // source is prepared, so the title screen is the top route during that time;
  // Back must cancel the preparation and return to the same source list
  // instead of leaving the title.
  final PlaybackPreparationController _preparation =
      PlaybackPreparationController();
  SourceResult? _preparingSource;

  // Legacy complete-file pre-player AI is intentionally disabled while the
  // progressive native-cue architecture is validated. Keep this as a runtime
  // getter so the old recovery code can remain compiled without becoming an
  // analyzer-level dead branch.
  bool get _legacyCompleteFileAiPreflightEnabled => true;

  @override
  void initState() {
    super.initState();

    // Use the warmed in-memory state before the first frame whenever possible.
    // This prevents the TV details page from briefly showing "Library" and then
    // changing to "In Library" only after remote metadata finishes loading.
    _watchlisted =
        widget.mediaState.peekWatchlisted(widget.item) ?? _watchlisted;
    _inLibrary = widget.mediaState.peekInLibrary(widget.item) ?? _inLibrary;
    unawaited(_loadMembership(widget.item));

    _detailsFuture = _loadDetails();
    if (widget.item.kind == MediaKind.movie) {
      unawaited(widget.sources.prefetch(widget.item));
    }
  }

  Future<void> _loadMembership(MediaItem item) async {
    final values = await Future.wait<bool>([
      widget.mediaState.isWatchlisted(item),
      widget.mediaState.isInLibrary(item),
    ]);
    if (!mounted) return;
    final watchlisted = values[0];
    final inLibrary = values[1];
    if (watchlisted == _watchlisted && inLibrary == _inLibrary) return;
    setState(() {
      _watchlisted = watchlisted;
      _inLibrary = inLibrary;
    });
  }

  Future<MediaItem> _loadDetails() async {
    final item = await widget.catalog.details(widget.item) ?? widget.item;
    EpisodeItem? firstEpisode;
    if (item.episodes.isNotEmpty) {
      final seasons = item.episodes.map((e) => e.season).toList()..sort();
      _selectedSeason = seasons.first;
      final ordered = item.episodes
          .where((episode) => episode.season == seasons.first)
          .toList()
        ..sort((a, b) => a.episode.compareTo(b.episode));
      firstEpisode = ordered.isEmpty ? null : ordered.first;
    }

    // Warm the source cache while metadata is already on screen.
    unawaited(widget.sources.prefetch(item, episode: firstEpisode));

    // Membership lookup is intentionally independent from network metadata.
    // If the richer catalog item has a different object instance, refresh from
    // the same local cache without blocking the screen.
    unawaited(_loadMembership(item));
    return item;
  }

  void _selectSeason(MediaItem item, int season) {
    setState(() => _selectedSeason = season);
    final episodes = item.episodes.where((e) => e.season == season).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));
    if (episodes.isNotEmpty) {
      unawaited(widget.sources.prefetch(item, episode: episodes.first));
    }
  }

  Future<void> _toggleLibrary(MediaItem item) async {
    final added = await widget.mediaState.toggleLibrary(item);
    if (!mounted) return;
    setState(() => _inLibrary = added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? 'Added to Library.' : 'Removed from Library.'),
      ),
    );
  }

  Future<void> _toggleWatchlist(MediaItem item) async {
    final added = await widget.mediaState.toggleWatchlist(item);
    if (!mounted) return;
    setState(() => _watchlisted = added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added ? 'Added to My Watchlist.' : 'Removed from My Watchlist.',
        ),
      ),
    );
  }

  void _onPreparationChanged() {
    if (mounted) setState(() {});
  }

  /// Back while a chosen source is still being prepared: abandon it. The
  /// source loop then shows the same source list again.
  void _cancelPreparation() {
    if (!_preparation.cancelActive()) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
      _status = '';
    });
  }

  /// Detach a local torrent whose resolve finished after its preparation was
  /// cancelled, unless the user has since chosen the same torrent again.
  Future<void> _releaseAbandonedLocalStream(SourceResult source) async {
    final newer = _preparation.isPreparing ? _preparingSource : null;
    if (newer != null && LocalTorrentService.sameTorrent(newer, source)) {
      return;
    }
    await LocalTorrentService.instance.releaseAbandonedStream(source);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_preparation.isPreparing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelPreparation();
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050806),
      body: FutureBuilder<MediaItem>(
        future: _detailsFuture,
        builder: (context, snapshot) {
          final item = snapshot.data ?? widget.item;
          if (PlatformProfile.isAndroidTv) {
            return FocusTraversalGroup(
              policy: TvTraversalPolicy(),
              child: _tvDetailsLayout(item),
            );
          }
          if (Platform.isWindows && MediaQuery.sizeOf(context).width >= 900) {
            return _desktopDetailsLayout(item);
          }
          return Stack(
            children: [
              CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _hero(item)),
                  SliverToBoxAdapter(child: _metadataSection(item)),
                  if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
                    SliverToBoxAdapter(child: _episodeSection(item)),
                  if (item.kind == MediaKind.series && item.episodes.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(40, 10, 40, 50),
                        child: Text(
                          'Episode metadata is not available for this title yet.',
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 70)),
                ],
              ),
              Positioned(
                top: 18,
                left: 18,
                child: SafeArea(
                  child: IconButton.filledTonal(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
              ),
              if (_resolving) _busyOverlay(item),
            ],
          );
        },
      ),
    );
  }

  Widget _desktopDetailsLayout(MediaItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF060807)),
        CustomScrollView(
          key: PageStorageKey('orvix-windows-details-${item.kind.name}-${item.id}'),
          cacheExtent: 1500,
          slivers: [
            SliverToBoxAdapter(child: _desktopHero(item)),
            SliverToBoxAdapter(child: _metadataSection(item)),
            if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
              SliverToBoxAdapter(child: _desktopSeriesRail(item)),
            if (item.kind == MediaKind.series && item.episodes.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(46, 12, 46, 54),
                  child: Text(
                    'Episode metadata is still warming up…',
                    style: TextStyle(
                      color: Color(0xFF98A19A),
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 78)),
          ],
        ),
        Positioned(
          top: 18,
          left: 18,
          child: SafeArea(
            child: IconButton.filled(
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xC9141816),
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: .10),
                ),
              ),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          ),
        ),
        if (_resolving) _busyOverlay(item),
      ],
    );
  }

  Widget _desktopHero(MediaItem item) {
    const lime = Color(0xFFB9FF45);
    final backdrop = item.background ?? item.poster;
    return SizedBox(
      height: 585,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop?.trim().isNotEmpty == true)
            CachedNetworkImage(
              imageUrl: backdrop!,
              fit: BoxFit.cover,
              alignment: Alignment.centerRight,
              memCacheWidth: 1900,
              fadeInDuration: Duration.zero,
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFF090C0A)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF090C0A)),
            )
          else
            const ColoredBox(color: Color(0xFF090C0A)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xFF060807),
                  Color(0xFA060807),
                  Color(0xC0060807),
                  Color(0x40060807),
                  Color(0x00060807),
                ],
                stops: [0, .22, .48, .77, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x12000000),
                  Color(0x00000000),
                  Color(0x24000000),
                  Color(0xFF060807),
                ],
                stops: [0, .36, .72, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(54, 82, 54, 52),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.logo?.trim().isNotEmpty == true)
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 430,
                          maxHeight: 135,
                        ),
                        child: CachedNetworkImage(
                          imageUrl: item.logo!,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) => Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 44,
                              height: 1.02,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1.1,
                            ),
                          ),
                        ),
                      )
                    else
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 44,
                          height: 1.02,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.1,
                        ),
                      ),
                    const SizedBox(height: 15),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MetaPill(item.typeLabel),
                        if (item.year != null) _MetaPill(item.year!),
                        if (item.runtime != null) _MetaPill(item.runtime!),
                        if (item.rating != null)
                          _MetaPill('★ ${item.rating!.toStringAsFixed(1)}'),
                        ...item.genres.take(3).map(_MetaPill.new),
                      ],
                    ),
                    if (item.description?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 17),
                      Text(
                        item.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE0E5E1),
                          fontSize: 15,
                          height: 1.52,
                        ),
                      ),
                    ],
                    const SizedBox(height: 23),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (item.kind == MediaKind.movie)
                          FilledButton.icon(
                            onPressed: _resolving ? null : () => _play(item),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play'),
                            style: FilledButton.styleFrom(
                              backgroundColor: lime,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 15,
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          )
                        else
                          FilledButton.tonalIcon(
                            onPressed: null,
                            icon: const Icon(Icons.video_library_outlined),
                            label: const Text('Choose an episode below'),
                          ),
                        if (item.kind == MediaKind.movie)
                          OutlinedButton.icon(
                            onPressed: _resolving
                                ? null
                                : () => _findSourcesAndPlay(item),
                            icon: const Icon(Icons.travel_explore_rounded),
                            label: const Text('Sources'),
                            style: _desktopSecondaryButtonStyle(),
                          ),
                        FilledButton.tonalIcon(
                          onPressed: () => _toggleLibrary(item),
                          icon: Icon(
                            _inLibrary
                                ? Icons.video_library_rounded
                                : Icons.library_add_outlined,
                          ),
                          label: Text(
                            _inLibrary ? 'In Library' : 'Add to Library',
                          ),
                          style: _desktopSecondaryButtonStyle(
                            selected: _inLibrary,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _toggleWatchlist(item),
                          icon: Icon(
                            _watchlisted
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_add_outlined,
                          ),
                          label: Text(
                            _watchlisted ? 'Watchlisted' : 'Watchlist',
                          ),
                          style: _desktopSecondaryButtonStyle(),
                        ),
                      ],
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

  ButtonStyle _desktopSecondaryButtonStyle({bool selected = false}) {
    const lime = Color(0xFFB9FF45);
    return ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(
        selected ? Colors.black : Colors.white,
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (selected) return lime;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return const Color(0xFF1A2119);
        }
        return const Color(0xC7111513);
      }),
      side: WidgetStateProperty.resolveWith((states) {
        if (selected) {
          return const BorderSide(color: lime, width: 1.6);
        }
        final active = states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused);
        return BorderSide(
          color: active
              ? lime.withValues(alpha: .72)
              : Colors.white.withValues(alpha: .13),
          width: active ? 1.5 : 1,
        );
      }),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _desktopSeriesRail(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    if (seasons.isEmpty) return const SizedBox.shrink();
    final selected = _selectedSeason ?? seasons.first;
    final episodes = item.episodes.where((e) => e.season == selected).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));

    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 46),
            child: Text(
              'Seasons',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w900,
                letterSpacing: -.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          HorizontalScrollRail(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 5),
            separatorWidth: 10,
            scrollStep: 440,
            showArrows: seasons.length > 7,
            itemCount: seasons.length,
            itemBuilder: (context, index) {
              final season = seasons[index];
              return _MobileSeasonTile(
                season: season,
                selected: season == selected,
                onTap: () => _selectSeason(item, season),
              );
            },
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 46),
            child: Text(
              selected == 0 ? 'Specials' : 'Season $selected',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: -.2,
              ),
            ),
          ),
          const SizedBox(height: 12),
          HorizontalScrollRail(
            height: 208,
            padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 6),
            separatorWidth: 14,
            scrollStep: 720,
            showArrows: true,
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              return _DesktopEpisodeCard(
                episode: episode,
                onTap: _resolving
                    ? null
                    : () => _findSourcesAndPlay(item, episode: episode),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Android TV details: a cinematic backdrop with the title, its actions,
  /// then seasons and episodes for series. Playback and source logic are the
  /// same as on other platforms; Back pops this route as usual.
  Widget _tvDetailsLayout(MediaItem item) {
    final series = item.kind == MediaKind.series;
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    final selectedSeason = _selectedSeason ??
        (seasons.isEmpty ? null : seasons.first);
    final episodes = selectedSeason == null
        ? const <EpisodeItem>[]
        : (item.episodes.where((e) => e.season == selectedSeason).toList()
          ..sort((a, b) => a.episode.compareTo(b.episode)));
    final firstEpisode = episodes.isEmpty ? null : episodes.first;

    final meta = [
      item.typeLabel,
      if (item.year != null) item.year!,
      if (item.runtime != null) item.runtime!,
      if (item.rating != null) '★ ${item.rating!.toStringAsFixed(1)}',
      if (item.certification?.trim().isNotEmpty == true)
        item.certification!.trim(),
    ].join('   •   ');
    final title = Text(
      item.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TvText.display.copyWith(fontSize: 38),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final heroHeight = (constraints.maxHeight * .64).clamp(300.0, 640.0);
        final episodeWidth =
            ((constraints.maxWidth - TvMetrics.pageHorizontal * 2) / 3.4)
                .clamp(240.0, 340.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: TvColors.background),
            Positioned(
              top: 0,
              right: 0,
              width: constraints.maxWidth * .78,
              height: heroHeight + 80,
              child: TvNetworkImage(
                url: item.background ?? item.poster,
                cacheWidth: 1280,
                alignment: Alignment.topCenter,
                placeholder: const SizedBox.shrink(),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              width: constraints.maxWidth * .78,
              height: heroHeight + 82,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF050806), Color(0xA6050806), Color(0x1A050806)],
                    stops: [0, .42, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: heroHeight + 82,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00050806), Color(0x40050806), Color(0xFF050806)],
                    stops: [0, .62, 1],
                  ),
                ),
              ),
            ),
            CustomScrollView(
              key: PageStorageKey('orvix-tv-details-${item.kind.name}-${item.id}'),
              slivers: [
                SliverToBoxAdapter(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: heroHeight),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TvMetrics.pageHorizontal + 8,
                        40,
                        TvMetrics.pageHorizontal,
                        20,
                      ),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              if (item.logo?.trim().isNotEmpty == true)
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      maxWidth: 380, maxHeight: 110),
                                  child: TvNetworkImage(
                                    url: item.logo,
                                    cacheWidth: 760,
                                    fit: BoxFit.contain,
                                    alignment: Alignment.centerLeft,
                                    placeholder: title,
                                  ),
                                )
                              else
                                title,
                              const SizedBox(height: 12),
                              Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TvText.caption.copyWith(
                                  color: const Color(0xFFD6DED5),
                                  fontSize: 14,
                                ),
                              ),
                              if (item.genres.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    for (final genre in item.genres.take(4))
                                      TvBadge(genre, color: TvColors.textMuted),
                                  ],
                                ),
                              ],
                              if (item.description?.trim().isNotEmpty == true) ...[
                                const SizedBox(height: 14),
                                Text(
                                  item.description!.trim(),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: TvText.body.copyWith(
                                    color: const Color(0xFFE1E7E0),
                                  ),
                                ),
                              ],
                                ],
                              ),
                            ),
                              const SizedBox(height: 22),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  if (!series || firstEpisode != null)
                                    TvButton(
                                      key: const ValueKey('tv-details-play'),
                                      kind: TvButtonKind.primary,
                                      icon: Icons.play_arrow_rounded,
                                      label: series
                                          ? 'Play S${firstEpisode!.season} · E${firstEpisode.episode}'
                                          : 'Play',
                                      autofocus: true,
                                      busy: _resolving,
                                      onPressed: () => _playTv(
                                        item,
                                        episode: series ? firstEpisode : null,
                                      ),
                                    ),
                                  if (!series || firstEpisode != null)
                                    TvButton(
                                      key: const ValueKey('tv-details-sources'),
                                      icon: Icons.travel_explore_rounded,
                                      label: 'Sources',
                                      onPressed: _resolving
                                          ? null
                                          : () => _findSourcesAndPlay(
                                                item,
                                                episode: series
                                                    ? firstEpisode
                                                    : null,
                                              ),
                                    ),
                                  TvButton(
                                    key: const ValueKey('tv-details-library'),
                                    icon: _inLibrary
                                        ? Icons.video_library_rounded
                                        : Icons.library_add_outlined,
                                    label: _inLibrary ? 'In Library' : 'Library',
                                    selected: _inLibrary,
                                    autofocus: series && firstEpisode == null,
                                    onPressed: () => _toggleLibrary(item),
                                  ),
                                  TvButton(
                                    key: const ValueKey('tv-details-watchlist'),
                                    icon: _watchlisted
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_add_outlined,
                                    label: _watchlisted ? 'Watchlisted' : 'Watchlist',
                                    selected: _watchlisted,
                                    onPressed: () => _toggleWatchlist(item),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (series && seasons.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _tvSeasonSection(
                      item,
                      seasons: seasons,
                      selected: selectedSeason!,
                      episodes: episodes,
                      episodeWidth: episodeWidth,
                    ),
                  ),
                if (series && seasons.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          TvMetrics.pageHorizontal + 8, 8, TvMetrics.pageHorizontal, 24),
                      child: Text(
                        'Episode metadata is not available for this title yet.',
                        style: TvText.body,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: _tvFactsSection(item)),
                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ),
            if (_resolving) _busyOverlay(item),
          ],
        );
      },
    );
  }

  Widget _tvSeasonSection(
    MediaItem item, {
    required List<int> seasons,
    required int selected,
    required List<EpisodeItem> episodes,
    required double episodeWidth,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TvSectionHeader(
            'Seasons',
            padding: EdgeInsets.symmetric(horizontal: TvMetrics.pageHorizontal + 8),
          ),
          SizedBox(
            height: 50 + TvRow.verticalPadding * 2,
            child: TvTabGroup(child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: TvMetrics.pageHorizontal + 8,
                vertical: TvRow.verticalPadding,
              ),
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return TvTab(
                  key: ValueKey('tv-season-$season'),
                  label: season == 0 ? 'Specials' : 'Season $season',
                  selected: season == selected,
                  onPressed: () => _selectSeason(item, season),
                );
              },
            )),
          ),
          const SizedBox(height: 6),
          TvRow(
            key: ValueKey('tv-episodes-$selected'),
            title: selected == 0 ? 'Specials' : 'Season $selected',
            trailing: '${episodes.length} episode${episodes.length == 1 ? '' : 's'}'
                '  •  hold OK to choose a source',
            horizontalPadding: TvMetrics.pageHorizontal + 8,
            itemCount: episodes.length,
            itemWidth: episodeWidth,
            itemHeight: TvLandscapeCard.heightFor(episodeWidth),
            itemBuilder: (context, index, node) {
              final episode = episodes[index];
              final details = <String>[
                if (episode.releaseDate != null)
                  '${episode.releaseDate!.year}-${episode.releaseDate!.month.toString().padLeft(2, '0')}-${episode.releaseDate!.day.toString().padLeft(2, '0')}',
                if (episode.rating != null) '★ ${episode.rating!.toStringAsFixed(1)}',
                if (episode.isUpcoming) 'Upcoming',
              ];
              return TvLandscapeCard(
                key: ValueKey('tv-episode-${episode.season}-${episode.episode}'),
                focusNode: node,
                width: episodeWidth,
                imageUrl: episode.thumbnail ?? item.background,
                placeholderIcon: Icons.tv_rounded,
                badge: 'EPISODE ${episode.episode}',
                title: episode.title.trim().isEmpty
                    ? 'Episode ${episode.episode}'
                    : episode.title.trim(),
                subtitle: details.join('  •  '),
                enabled: !_resolving,
                onPressed: () => _playTv(item, episode: episode),
                // The episode's source browser, for a manual choice.
                onLongPress: () => _findSourcesAndPlay(item, episode: episode),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tvFactsSection(MediaItem item) {
    final hasCredits = item.directors.isNotEmpty ||
        item.cast.isNotEmpty ||
        item.castMembers.isNotEmpty;
    final hasFacts = item.country?.trim().isNotEmpty == true ||
        item.certification?.trim().isNotEmpty == true;
    if (!hasCredits && !hasFacts) return const SizedBox.shrink();

    // One focus stop for the whole block, so the remote can scroll to it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TvMetrics.pageHorizontal + 8, 18, TvMetrics.pageHorizontal, 0),
      child: TvFocusable(
        key: const ValueKey('tv-details-facts'),
        semanticLabel: 'Details',
        builder: (context, focused) => AnimatedContainer(
          duration: TvMetrics.focusDuration,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: focused ? TvColors.cardFocused : TvColors.surface,
            borderRadius: BorderRadius.circular(TvMetrics.radius),
            border: Border.all(
              color: focused ? TvColors.primary : TvColors.border,
              width: focused ? TvMetrics.focusBorder : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Details', style: TvText.section),
              const SizedBox(height: 10),
              if (item.directors.isNotEmpty)
                Text(
                  'Director${item.directors.length > 1 ? 's' : ''}: ${item.directors.join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.body,
                ),
              if (hasFacts) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    if (item.country?.trim().isNotEmpty == true)
                      item.country!.trim(),
                    if (item.certification?.trim().isNotEmpty == true)
                      'Rated ${item.certification!.trim()}',
                  ].join('  •  '),
                  style: TvText.caption,
                ),
              ],
              if (item.castMembers.isNotEmpty) ...[
                const SizedBox(height: 16),
                _CastRail(
                  members: item.castMembers.take(14).toList(growable: false),
                  tv: true,
                ),
              ] else if (item.cast.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Cast: ${item.cast.take(12).join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.body,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero(MediaItem item) {
    final tv = PlatformProfile.isAndroidTv;
    // On a narrow desktop window the title, pills and actions wrap onto extra
    // lines, so the hero grows past its usual height instead of clipping the
    // action buttons. Android Mobile and Android TV keep their fixed height.
    final growable = !Platform.isAndroid;
    final layers = <Widget>[
      if (item.background != null)
        CachedNetworkImage(
          imageUrl: item.background!,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => const SizedBox.shrink(),
        ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x2207090E), Color(0xFF050806)],
            stops: [.16, 1],
          ),
        ),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color(0xFA07090E),
              Color(0xB807090E),
              Color(0x0007090E),
            ],
            stops: [0, .48, .92],
          ),
        ),
      ),
    ];
    final content = Padding(
        padding: EdgeInsets.fromLTRB(
          tv ? 30 : 42,
          tv ? 64 : 100,
          tv ? 30 : 42,
          tv ? 34 : 52,
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.logo?.trim().isNotEmpty == true)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 360,
                      maxHeight: 115,
                    ),
                    child: CachedNetworkImage(
                      imageUrl: item.logo!,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      fadeInDuration: Duration.zero,
                      errorWidget: (_, __, ___) => Text(
                        item.title,
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -.9,
                            ),
                      ),
                    ),
                  )
                else
                  Text(
                    item.title,
                    style:
                        Theme.of(context).textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -.9,
                            ),
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 9,
                  runSpacing: 8,
                  children: [
                    _MetaPill(item.typeLabel),
                    if (item.year != null) _MetaPill(item.year!),
                    if (item.runtime != null) _MetaPill(item.runtime!),
                    if (item.rating != null)
                      _MetaPill('★ ${item.rating!.toStringAsFixed(1)}'),
                    ...item.genres.take(4).map(_MetaPill.new),
                  ],
                ),
                if (item.description?.isNotEmpty == true) ...[
                  const SizedBox(height: 18),
                  Text(
                    item.description!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, height: 1.55),
                  ),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    if (item.kind == MediaKind.movie)
                      FilledButton.icon(
                        onPressed: _resolving ? null : () => _play(item),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                      )
                    else
                      FilledButton.tonalIcon(
                        onPressed: null,
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('Choose an episode below'),
                      ),
                    if (item.kind == MediaKind.movie)
                      OutlinedButton.icon(
                        onPressed: _resolving
                            ? null
                            : () => _findSourcesAndPlay(item),
                        icon: const Icon(Icons.travel_explore_rounded),
                        label: const Text('Find Sources'),
                      ),
                    FilledButton.tonalIcon(
                      onPressed: () => _toggleLibrary(item),
                      icon: Icon(
                        _inLibrary
                            ? Icons.video_library_rounded
                            : Icons.library_add_outlined,
                      ),
                      label: Text(
                        _inLibrary ? 'In Library' : 'Add to Library',
                      ),
                      style: _inLibrary
                          ? FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFB9FF45),
                              foregroundColor: Colors.black,
                            )
                          : null,
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _toggleWatchlist(item),
                      icon: Icon(
                        _watchlisted
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_add_outlined,
                      ),
                      label: Text(
                        _watchlisted ? 'In Watchlist' : 'Watchlist',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    if (growable) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 560),
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            for (final layer in layers) Positioned.fill(child: layer),
            content,
          ],
        ),
      );
    }
    return SizedBox(
      height: tv ? 400 : 560,
      child: Stack(
        fit: StackFit.expand,
        children: [...layers, content],
      ),
    );
  }

  Widget _metadataSection(MediaItem item) {
    final hasCredits = item.cast.isNotEmpty || item.directors.isNotEmpty;
    final hasFacts = item.country?.trim().isNotEmpty == true ||
        item.certification?.trim().isNotEmpty == true ||
        item.genres.isNotEmpty;
    final pinKey = widget.sources.sourceTargetKey(item);

    return FutureBuilder<PinnedSourcePreference?>(
      future: widget.sources.getPinnedSourcePreference(pinKey),
      builder: (context, snapshot) {
        final pinned = snapshot.data;
        if (!hasCredits && !hasFacts && pinned == null) {
          return const SizedBox.shrink();
        }

        final compact = MediaQuery.sizeOf(context).width < 700;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 40,
            18,
            compact ? 18 : 40,
            20,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pinned != null) ...[
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        final episode = item.kind == MediaKind.series
                            ? _episodeForPinnedRelease(item, pinned)
                            : null;
                        _playPinnedRelease(item, episode: episode);
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 15,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D150F),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2D492F)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin_rounded),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.kind == MediaKind.series
                                        ? 'Pinned release family'
                                        : 'Pinned release',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    pinned.label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    item.kind == MediaKind.movie
                                        ? '${pinned.provider} • Click to play this exact pinned release'
                                        : '${pinned.provider} • Click to play this pinned release family',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.play_arrow_rounded),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (hasCredits || hasFacts) ...[
                  Text(
                    'Details',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  if (item.directors.isNotEmpty)
                    Text(
                      'Director${item.directors.length > 1 ? 's' : ''}  •  ${item.directors.join(', ')}',
                      style: const TextStyle(fontSize: 15, height: 1.5),
                    ),
                  if (item.country?.trim().isNotEmpty == true ||
                      item.certification?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (item.country?.trim().isNotEmpty == true)
                          item.country!.trim(),
                        if (item.certification?.trim().isNotEmpty == true)
                          'Rated ${item.certification!.trim()}',
                      ].join('  •  '),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (item.castMembers.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _CastRail(
                      members:
                          item.castMembers.take(16).toList(growable: false),
                      tv: false,
                    ),
                  ] else if (item.cast.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Cast',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: item.cast
                          .take(24)
                          .map((name) => Chip(label: Text(name)))
                          .toList(growable: false),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _episodeSection(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    final selected = _selectedSeason ?? seasons.first;
    final episodes = item.episodes.where((e) => e.season == selected).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));
    final compact = MediaQuery.sizeOf(context).width < 700;
    final horizontalPadding = compact ? 18.0 : 40.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        18,
        horizontalPadding,
        18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seasons',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          HorizontalScrollRail(
            height: compact ? 46 : 58,
            showArrows: false,
            separatorWidth: compact ? 8 : 10,
            scrollStep: 420,
            itemCount: seasons.length,
            itemBuilder: (context, index) {
              final season = seasons[index];
              return _MobileSeasonTile(
                season: season,
                selected: season == selected,
                onTap: () => _selectSeason(item, season),
              );
            },
          ),
          const SizedBox(height: 18),
          Text(
            'Season $selected',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          if (compact)
            ...episodes.map((episode) => _episodeTile(item, episode))
          else
            HorizontalScrollRail(
              height: 190,
              separatorWidth: 14,
              scrollStep: 690,
              itemCount: episodes.length,
              itemBuilder: (context, index) =>
                  _desktopEpisodeCard(item, episodes[index]),
            ),
        ],
      ),
    );
  }

  Widget _desktopEpisodeCard(MediaItem item, EpisodeItem episode) {
    final image = episode.thumbnail ?? item.background ?? item.poster;
    return SizedBox(
      width: 285,
      height: 178,
      child: Material(
        color: const Color(0xFF0D120F),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _resolving ? null : () => _play(item, episode: episode),
          hoverColor: Colors.white.withValues(alpha: .035),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image?.trim().isNotEmpty == true)
                CachedNetworkImage(
                  imageUrl: image!,
                  fit: BoxFit.cover,
                  memCacheWidth: 650,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, __) =>
                      const ColoredBox(color: Color(0xFF141A16)),
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: Color(0xFF141A16)),
                )
              else
                const ColoredBox(color: Color(0xFF141A16)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x18000000),
                      Color(0x10000000),
                      Color(0xE9000000),
                    ],
                    stops: [0, .42, 1],
                  ),
                ),
              ),
              Positioned(
                top: 9,
                left: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xC9171C18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    episode.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 7,
                right: 7,
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Sources',
                      onPressed: _resolving
                          ? null
                          : () => _findSourcesAndPlay(
                                item,
                                episode: episode,
                              ),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xCC151A17),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(34, 34),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(
                        Icons.travel_explore_rounded,
                        size: 17,
                      ),
                    ),
                    const SizedBox(width: 5),
                    IconButton.filled(
                      tooltip: 'Play',
                      onPressed:
                          _resolving ? null : () => _play(item, episode: episode),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xE6B9FF45),
                        foregroundColor: Colors.black,
                        minimumSize: const Size(34, 34),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.title.trim().isEmpty
                          ? episode.label
                          : episode.title.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (episode.overview?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        episode.overview!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFC5CEC8),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _episodeTile(MediaItem item, EpisodeItem episode) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;

        final thumbnail = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: episode.thumbnail == null
              ? Container(
                  color: const Color(0xFF121A13),
                  child: const Center(child: Icon(Icons.movie_outlined)),
                )
              : CachedNetworkImage(
                  imageUrl: episode.thumbnail!,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      const Center(child: Icon(Icons.movie_outlined)),
                ),
        );

        final title = Text(
          '${episode.label}  ${episode.title}',
          maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        );

        final overview = episode.overview == null
            ? null
            : Text(
                episode.overview!,
                maxLines: compact ? 3 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              );

        final sourcesButton = OutlinedButton.icon(
          onPressed: _resolving
              ? null
              : () => _findSourcesAndPlay(item, episode: episode),
          icon: const Icon(Icons.travel_explore_rounded),
          label: const Text('Sources'),
        );

        final playButton = FilledButton.icon(
          onPressed: _resolving ? null : () => _play(item, episode: episode),
          style: compact && PlatformProfile.isAndroidMobile
              ? FilledButton.styleFrom(
                  // Mobile-only secondary lime: stays inside Orvix's green
                  // family without competing with the selected season chip.
                  backgroundColor: const Color(0xFFCBFF75),
                  foregroundColor: const Color(0xFF050806),
                )
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Play'),
        );

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.all(compact ? 14 : 0),
          decoration: BoxDecoration(
            color: const Color(0xFF0B100D),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: const Color(0xFF1D2A20)),
          ),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 112, height: 72, child: thumbnail),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              title,
                              if (overview != null) ...[
                                const SizedBox(height: 6),
                                overview,
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: sourcesButton),
                        const SizedBox(width: 10),
                        Expanded(child: playButton),
                      ],
                    ),
                  ],
                )
              : ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  leading: SizedBox(width: 104, height: 68, child: thumbnail),
                  title: title,
                  subtitle: overview,
                  trailing: Wrap(
                    spacing: 8,
                    children: [sourcesButton, playButton],
                  ),
                ),
        );
      },
    );
  }

  Widget _busyOverlay(MediaItem item) {
    if (PlatformProfile.isAndroidMobile) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            decoration: const BoxDecoration(
              color: Color(0xF20B0F0C),
              border: Border(top: BorderSide(color: Color(0xFF263827))),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _status.isEmpty ? 'Preparing playback…' : _status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE6ECE7),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_resolveProgress != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        '${(_resolveProgress! * 100).round()}%',
                        style: const TextStyle(
                          color: Color(0xFFB9FF45),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 9),
                _resolveProgress == null
                    ? const LinearProgressIndicator(minHeight: 3)
                    : LinearProgressIndicator(
                        value: _resolveProgress,
                        minHeight: 3,
                      ),
              ],
            ),
          ),
        ),
      );
    }

    final backdrop = item.background ?? item.poster;
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF050806),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdrop?.trim().isNotEmpty == true)
              CachedNetworkImage(
                imageUrl: backdrop!,
                fit: BoxFit.cover,
                memCacheWidth: PlatformProfile.isAndroidTv ? 1280 : 900,
                fadeInDuration: Duration.zero,
                errorWidget: (_, __, ___) =>
                    const ColoredBox(color: Color(0xFF050806)),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x99000000),
                    Color(0xCC050806),
                    Color(0xFF050806),
                  ],
                  stops: [0, .55, 1],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Color(0xD9050806), Color(0x33050806)],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: PlatformProfile.isAndroidTv ? 64 : 28,
                  vertical: PlatformProfile.isAndroidTv ? 44 : 30,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (item.logo?.trim().isNotEmpty == true)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: PlatformProfile.isAndroidTv ? 380 : 270,
                          maxHeight: PlatformProfile.isAndroidTv ? 140 : 100,
                        ),
                        child: CachedNetworkImage(
                          imageUrl: item.logo!,
                          fit: BoxFit.contain,
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) => Text(
                            item.title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize:
                                  PlatformProfile.isAndroidTv ? 34 : 27,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      )
                    else
                      Text(
                        item.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: PlatformProfile.isAndroidTv ? 34 : 27,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -.5,
                        ),
                      ),
                    const SizedBox(height: 30),
                    SizedBox(
                      width: PlatformProfile.isAndroidTv ? 320 : 250,
                      child: _resolveProgress == null
                          ? const LinearProgressIndicator(minHeight: 3)
                          : LinearProgressIndicator(
                              value: _resolveProgress,
                              minHeight: 3,
                            ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status.isEmpty ? 'Preparing playback…' : _status,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFD7DDD8),
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    if (_resolveProgress != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        '${(_resolveProgress! * 100).round()}%',
                        style: const TextStyle(
                          color: Color(0xFFA9B2AB),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              top: 18,
              left: 18,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _play(MediaItem item, {EpisodeItem? episode}) async {
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = 'Checking connected libraries and playable sources…';
    });

    try {
      final preferred = await widget.cloudPreferences.getPreferred();
      if (preferred == CloudProvider.torbox &&
          await widget.torbox.isConnected) {
        final existingTorBox = await _findInTorBox(item, episode: episode);
        if (existingTorBox != null) {
          await _openTorBoxItem(existingTorBox, item, episode);
          return;
        }
      }
      final existing = await _findInPikPak(item, episode: episode);
      if (existing != null) {
        if (mounted) {
          setState(() => _status = 'Matched in PikPak: ${existing.name}');
        }
        await _openPikPakFile(existing, item, episode);
        return;
      }

      // Free P2P is one-click on every platform. Android TV with a
      // cloud/debrid account keeps its manual source browser, so no legacy
      // series-wide pin chooses a cloud source the user did not select.
      final oneClick =
          !PlatformProfile.isAndroidTv || !await _hasCloudConnection();
      if (PlatformProfile.isAndroidTv && oneClick) {
        await widget.sources.clearLegacyTvPinsOnce();
      }

      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveProgress = null;
      });
      await _findSourcesAndPlay(
        item,
        episode: episode,
        autoUsePinned: oneClick,
      );
    } catch (e) {
      _showPlayError(e);
    }
  }

  /// Android TV Play (title or episode): Free P2P one-click playback. With
  /// a cloud/debrid account it opens the source browser exactly as before.
  /// The browser stays one remote press away (Sources, or hold OK on an
  /// episode) for a manual choice.
  Future<void> _playTv(MediaItem item, {EpisodeItem? episode}) async {
    if (_resolving) return;
    if (await _hasCloudConnection()) {
      await _findSourcesAndPlay(item, episode: episode);
      return;
    }
    await _play(item, episode: episode);
  }

  Future<void> resumeContinueWatching(
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    final rich = await widget.catalog.details(item) ?? item;
    EpisodeItem? target = episode;
    if (episode != null && rich.kind == MediaKind.series) {
      final resumeSeason = episode.season;
      final resumeEpisode = episode.episode;
      for (final candidate in rich.episodes) {
        if (candidate.season == resumeSeason &&
            candidate.episode == resumeEpisode) {
          target = candidate;
          break;
        }
      }
    }
    if (!mounted) return;
    await _findSourcesAndPlay(rich, episode: target, autoUsePinned: true);
  }

  Future<void> _findSourcesAndPlay(
    MediaItem item, {
    EpisodeItem? episode,
    bool autoUsePinned = false,
    bool forceRefresh = false,
  }) async {
    if (!mounted) return;

    if (PlatformProfile.isAndroidTv && !autoUsePinned) {
      setState(() {
        _resolving = false;
        _resolveProgress = null;
        _status = '';
      });

      final resultsFuture = widget.sources.resolve(
        item,
        episode: episode,
        // TV should expose the complete provider response. Do not silently
        // remove a smaller 480p/low-bitrate source just because an HD source
        // also exists.
        includeLowQuality: true,
      );
      final hasCloudConnection = await _hasCloudConnection();
      await Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 140),
          pageBuilder: (_, animation, __) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: TvSourceBrowserScreen(
              sources: widget.sources,
              item: item,
              episode: episode,
              resultsFuture: resultsFuture,
              preferFreeP2p: !hasCloudConnection,
              onPlaySource: (chosen) async {
                await _playSourceResult(
                  chosen,
                  item,
                  episode,
                  hasCloudConnection: await _hasCloudConnection(),
                );
              },
            ),
          ),
        ),
      );
      return;
    }

    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = episode == null
          ? 'Finding sources for ${item.title}…'
          : 'Finding sources for ${item.title} ${episode.label}…';
    });

    try {
      final results = await widget.sources.resolve(
        item,
        episode: episode,
        // Lower-resolution releases stay visible because they may be the most
        // portable source on real Android/TV hardware.
        includeLowQuality: true,
        // "Try Again" must ask the providers again, not replay the answer
        // that just came back empty.
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() => _resolving = false);

      if (results.isEmpty) {
        await _showNoSourcesDialog(item, episode: episode);
        return;
      }

      final hasCloudConnection = await _hasCloudConnection();

      SourceResult? pinnedResult;
      String? pinnedIdentity;
      if (autoUsePinned) {
        final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
        final pinned = await widget.sources.getPinnedSourceIdentity(pinKey);
        if (pinned != null && pinned.isNotEmpty) {
          for (final result in results) {
            if (widget.sources.matchesPinned(
              result,
              pinned,
              seriesWide: item.kind == MediaKind.series,
            )) {
              pinnedResult = result;
              pinnedIdentity = pinned;
              break;
            }
          }
        }
      }

      // Free P2P (no cloud/debrid route): one press of Play finds the best
      // source the bounded live check verified, plays it and, when it does
      // not start, moves to the next verified source. A pin is a
      // preference, never a bypass of that check.
      if (autoUsePinned && !hasCloudConnection) {
        await _playFreeP2pOneClick(
          results,
          item,
          episode,
          pinnedResult: pinnedResult,
          pinnedIdentity: pinnedIdentity,
        );
        return;
      }

      // Cloud/debrid route, unchanged: a pin plays directly through the
      // cloud path, otherwise the source picker opens. No live probe, local
      // engine or Free P2P fallback is involved.
      final chosen = pinnedResult;
      if (chosen == null) {
        await _runSourcePicker(
          results,
          item,
          episode,
          hasCloudConnection: hasCloudConnection,
        );
        return;
      }

      if (!mounted) return;
      await _playSourceResult(
        chosen,
        item,
        episode,
        hasCloudConnection: hasCloudConnection,
      );
    } catch (e) {
      _showPlayError(e);
    }
  }

  /// The source picker loop: pick, prepare and play, and come back to the
  /// same list when the player closes or Back cancels the preparation. Reuses
  /// [probeSession]'s live evidence (for example Normal Play's) instead of
  /// probing from scratch, and releases it when the loop ends.
  Future<void> _runSourcePicker(
    List<SourceResult> results,
    MediaItem item,
    EpisodeItem? episode, {
    required bool hasCloudConnection,
    FreeP2pLiveProbeService? probeSession,
  }) async {
    // A modal sheet cannot safely stay above/below a player route across
    // nested Navigators. Close it before playback, then reopen it from the
    // same in-memory result/probe session when the player returns. To the
    // user this is still one-step navigation:
    // player -> source list -> title, with no provider re-fetch.
    final session = probeSession ??
        FreeP2pLiveProbeService(
          mediaDuration: FreeP2pLiveProbeService.parseMediaRuntime(item.runtime),
          priority: await widget.sources.getPriorityOrder(),
        );
    try {
      // Player returned, or Back cancelled the preparation: the loop
      // reopens the source picker using the same
      // already-resolved results and cached live-probe ranking.
      await runSourcePlaybackLoop<SourceResult>(
        controller: _preparation,
        isActive: () => mounted,
        chooseSource: () => _chooseSource(
          results,
          item,
          episode,
          probeSession: session,
        ),
        prepareAndPlay: (selected) async {
          _preparingSource = selected;
          await _playSourceResult(
            selected,
            item,
            episode,
            hasCloudConnection: hasCloudConnection,
          );
        },
        onError: _showPlayError,
        onPreparationChanged: _onPreparationChanged,
      );
    } finally {
      await session.release();
    }
  }

  /// Free P2P one-click playback; see [FreeP2pAutoPlay] for the selection
  /// rules and budgets. When nothing verified starts, the source picker
  /// opens with the same live evidence and an honest reason.
  Future<void> _playFreeP2pOneClick(
    List<SourceResult> results,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? pinnedResult,
    String? pinnedIdentity,
  }) async {
    final probeSession = FreeP2pLiveProbeService(
      mediaDuration: FreeP2pLiveProbeService.parseMediaRuntime(item.runtime),
      priority: await widget.sources.getPriorityOrder(),
    );
    final autoPlay = FreeP2pAutoPlay(
      probe: probeSession,
      sources: widget.sources,
    );
    void status(String message) {
      if (!mounted) return;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = message;
      });
    }

    FreeP2pAutoPlayResult outcome;
    try {
      outcome = await autoPlay.run(
        results,
        preferred: pinnedResult,
        isPinned: pinnedIdentity == null
            ? null
            : (source) => widget.sources.matchesPinned(
                  source,
                  pinnedIdentity,
                  seriesWide: item.kind == MediaKind.series,
                ),
        onStatus: status,
        onProbeProgress: (completed, total) =>
            status('Checking live P2P sources… $completed/$total'),
        attempt: (source, {required fallbackAvailable}) => _runOneClickAttempt(
          source,
          item,
          episode,
          fallbackAvailable: fallbackAvailable,
        ),
      );
    } catch (_) {
      await probeSession.release();
      rethrow;
    }

    if (mounted) {
      setState(() {
        _resolving = false;
        _resolveProgress = null;
        _status = '';
      });
    }
    if (!mounted ||
        outcome.stop == FreeP2pAutoPlayStop.started ||
        outcome.stop == FreeP2pAutoPlayStop.stoppedByUser) {
      await probeSession.release();
      return;
    }

    _showOneClickStop(outcome);
    await _runSourcePicker(
      results,
      item,
      episode,
      hasCloudConnection: false,
      probeSession: probeSession,
    );
  }

  /// Players may leave by themselves for a source fallback only on Android
  /// (mobile and TV): on Windows and macOS that exit path does not restore
  /// fullscreen, so a player startup failure there stays on screen as
  /// before and only resolve-stage failures fall back.
  bool get _playerSourceFallbackSupported => _androidPlayback;

  /// Android playback (mobile and TV). Always equal to Platform.isAndroid in
  /// the app; the Android TV test override also selects it on a test host.
  bool get _androidPlayback =>
      Platform.isAndroid || PlatformProfile.isAndroidTv;

  /// Set while a one-click attempt may let MPV leave on a startup failure.
  bool _sourceFallbackArmed = false;

  /// Set when the player reported a startup failure and left for the next
  /// source.
  bool _sourceFallbackRequested = false;

  /// One automatic attempt, run as a cancellable preparation so Back stops
  /// it (and every later fallback).
  Future<FreeP2pAttemptEnd> _runOneClickAttempt(
    SourceResult source,
    MediaItem item,
    EpisodeItem? episode, {
    required bool fallbackAvailable,
  }) async {
    if (!mounted) return FreeP2pAttemptEnd.stoppedByUser;
    _sourceFallbackArmed = fallbackAvailable && _playerSourceFallbackSupported;
    _sourceFallbackRequested = false;
    FreeP2pPlaybackAttempt? traced;
    Object? failure;
    var completed = false;
    try {
      completed = await _preparation.run(
        () async {
          _preparingSource = source;
          traced = await _playSourceResult(
            source,
            item,
            episode,
            hasCloudConnection: false,
          );
        },
        onChanged: _onPreparationChanged,
      );
    } catch (error) {
      failure = error;
      completed = true;
    } finally {
      _sourceFallbackArmed = false;
    }
    if (!completed || !mounted) return FreeP2pAttemptEnd.stoppedByUser;
    final attempt = traced ?? FreeP2pPlaybackTrace.instance.latest(source);
    final end = classifyFreeP2pAttempt(
      attempt?.outcome,
      playerLeftForFallback: _sourceFallbackRequested,
    );
    _sourceFallbackRequested = false;
    if (end == FreeP2pAttemptEnd.stoppedByUser && failure != null) {
      // An error no stage explains: show it rather than hide it.
      _showPlayError(failure);
    }
    return end;
  }

  /// Why one-click playback did not start, said once above the source
  /// picker that opens next.
  void _showOneClickStop(FreeP2pAutoPlayResult outcome) {
    // The stage that ended the last attempt, in plain words.
    final last = switch (FreeP2pPlaybackTrace.instance.attempts.firstOrNull
        ?.outcome) {
      FreeP2pPlaybackOutcome.metadataTimeout =>
        ' Last one: its metadata did not arrive in time.',
      FreeP2pPlaybackOutcome.sourceError =>
        ' Last one: the torrent engine rejected it.',
      FreeP2pPlaybackOutcome.playerFailure =>
        ' Last one: the player could not start it.',
      FreeP2pPlaybackOutcome.failed => ' Last one: it could not be opened.',
      _ => '',
    };
    final message = switch (outcome.stop) {
      FreeP2pAutoPlayStop.engineFailure =>
        'The local P2P engine is not responding. Choose a direct source or try again.',
      FreeP2pAutoPlayStop.exhausted => outcome.tried == 1
          ? 'The verified source did not start.$last Choose another source or re-check.'
          : 'None of the ${outcome.tried} verified sources started.$last Choose another source or re-check.',
      _ =>
        'No source was verified as playable right now. Choose one or re-check.',
    };
    final tv = PlatformProfile.isAndroidTv;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        // A focusable action would pull the TV remote's focus away from the
        // source browser; TV shows the same report from its Live report chip.
        action: tv
            ? null
            : SnackBarAction(
                label: 'Copy report',
                onPressed: () => unawaited(
                  Clipboard.setData(
                    ClipboardData(
                      text: FreeP2pPlaybackTrace.instance.report(),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// One cloud/debrid eligibility check for the whole details flow. Any
  /// connected PikPak, TorBox, Real-Debrid or Premiumize account is a cloud
  /// path: playback sends torrents there, so Free P2P live probing/ranking is
  /// only the automatic choice when none of them is connected.
  Future<bool> _hasCloudConnection() async =>
      (await widget.pikpak.isSignedIn) ||
      (await widget.torbox.isConnected) ||
      (await RealDebridService.instance.isConnected) ||
      (await PremiumizeService.instance.isConnected);

  /// Runs the player handoff of a traced Free P2P attempt and records a
  /// cancellation or an error that ended it before the player answered.
  Future<void> _traced(
    FreeP2pPlaybackAttempt? trace,
    Future<void> Function() handoff,
  ) async {
    try {
      await handoff();
      // Returned before any player was chosen (for example a fail-closed
      // preflight): no player event will ever end this attempt.
      if (trace != null &&
          trace.isOpen &&
          !trace.stages.any((stage) => stage['stage'] == 'player')) {
        trace.finish(
          FreeP2pPlaybackOutcome.failed,
          detail: 'no player was opened',
        );
      }
    } on PlaybackPreparationCancelled {
      trace?.finish(FreeP2pPlaybackOutcome.cancelled);
      rethrow;
    } catch (error) {
      trace?.finish(FreeP2pPlaybackOutcome.failed, detail: error.toString());
      rethrow;
    }
  }

  /// The player reported a start: record it and, for a local P2P stream,
  /// what the engine measured at that moment. A start after a reported
  /// startup failure (MPV keeps trying) turns that attempt into a playing
  /// one.
  Future<void> _tracePlayerStarted(SourceResult source, String url) async {
    var trace = FreeP2pPlaybackTrace.instance.active(source);
    if (trace != null) {
      trace.stage('playerStart', 'started');
      trace.finish(FreeP2pPlaybackOutcome.playing);
    } else {
      trace = FreeP2pPlaybackTrace.instance.latest(source);
      if (trace?.outcome != FreeP2pPlaybackOutcome.playerFailure) return;
      trace!.markRecovered();
    }
    if (!source.isMagnet) return;
    _traceEngineStats(
      trace,
      await LocalTorrentService.instance.healthForStreamUrl(url),
    );
  }

  /// What the engine measured for the stream when the player answered.
  void _traceEngineStats(
    FreeP2pPlaybackAttempt? trace,
    LocalTorrentHealth? health,
  ) {
    trace?.stage(
      'engineStats',
      health == null ? 'unavailable' : 'sampled',
      detail: health == null
          ? const <String, Object?>{}
          : <String, Object?>{
              'livePeers': health.peers,
              'liveConnections': health.connections,
              'speedBps': health.downloadSpeedBytesPerSecond.round(),
            },
    );
  }

  /// The player gave up on [source]. [last] is false when another player
  /// is tried next, so the attempt stays open for it. [sourceFallback]
  /// records that the player left for the next verified source.
  FreeP2pPlaybackAttempt? _tracePlayerFailed(
    SourceResult source,
    String? message, {
    bool last = true,
    bool sourceFallback = false,
  }) {
    final trace = FreeP2pPlaybackTrace.instance.active(source);
    if (trace == null) return null;
    trace.stage('playerStart', 'failed');
    if (sourceFallback) trace.stage('sourceFallback', 'playerLeft');
    if (last) {
      trace.finish(FreeP2pPlaybackOutcome.playerFailure, detail: message);
    }
    return trace;
  }

  /// The player route closed. An attempt still open was neither started nor
  /// reported as failed: the user left while it was still loading.
  void _tracePlayerClosed(SourceResult? source) {
    if (source == null) return;
    final trace = FreeP2pPlaybackTrace.instance.active(source);
    if (trace == null) return;
    trace.stage('playerClosed', 'beforeStart');
    trace.finish(FreeP2pPlaybackOutcome.closedBeforeStart);
  }

  String _sourceReleaseHint(SourceResult source) {
    final fileName = source.fileNameHint?.trim();
    if (fileName != null && fileName.isNotEmpty) return fileName;
    return source.title.split('\n').last.trim();
  }

  /// Plays [chosen]. Returns the Free P2P playback attempt it traced, or
  /// null for a cloud/debrid route (never traced).
  Future<FreeP2pPlaybackAttempt?> _playSourceResult(
    SourceResult chosen,
    MediaItem item,
    EpisodeItem? episode, {
    bool? hasCloudConnection,
  }) async {
    final cloudConnected = hasCloudConnection ?? await _hasCloudConnection();
    final releaseHint = _sourceReleaseHint(chosen);

    if (!chosen.isMagnet) {
      if (!mounted) return null;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Opening direct stream…';
      });
      // Free P2P report only; cloud/debrid playback is not traced.
      final trace = cloudConnected
          ? null
          : (FreeP2pPlaybackTrace.instance.attemptFor(chosen)
            ..stage('route', 'directHttp'));
      await _traced(
        trace,
        () => _openPlayerUrl(
          chosen.resource,
          item,
          episode,
          source: chosen,
          releaseHint: releaseHint,
          expectedSizeBytes: chosen.sizeBytes,
          expectedVideoHash: chosen.videoHash,
        ),
      );
      return trace;
    }

    if (!cloudConnected) {
      if (!mounted) return null;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Starting local P2P torrent stream…';
      });
      final preparation = PlaybackPreparation.current;
      final trace = FreeP2pPlaybackTrace.instance.attemptFor(chosen)
        ..stage('route', 'localP2p');
      late final String localUrl;
      try {
        localUrl = await LocalTorrentService.instance.resolve(
          chosen,
          onProgress: (message) {
            if (mounted && preparation?.isCancelled != true) {
              setState(() => _status = message);
            }
          },
          trace: trace,
        );
      } catch (error) {
        if (preparation?.isCancelled == true) {
          trace.finish(FreeP2pPlaybackOutcome.cancelled);
          throw const PlaybackPreparationCancelled();
        }
        trace.finish(FreeP2pPlaybackOutcome.failed, detail: error.toString());
        unawaited(
          widget.sources.recordPlaybackOutcome(
            chosen,
            success: false,
            reason: error.toString(),
          ),
        );
        rethrow;
      }
      if (preparation?.isCancelled == true) {
        // Back was pressed while the torrent was resolving. Do not open the
        // player for it, and do not leave its torrent attached.
        trace.finish(FreeP2pPlaybackOutcome.cancelled);
        await _releaseAbandonedLocalStream(chosen);
        throw const PlaybackPreparationCancelled();
      }
      if (!mounted) return null;
      setState(() => _status = 'P2P stream ready — opening player…');
      await _traced(
        trace,
        () => _openPlayerUrl(
          localUrl,
          item,
          episode,
          source: chosen,
          releaseHint: releaseHint,
          expectedSizeBytes: chosen.sizeBytes,
          expectedVideoHash: chosen.videoHash,
        ),
      );
      return trace;
    }

    final cloud = await _chooseCloudProvider();
    if (cloud == null || !mounted) return null;
    PlaybackPreparation.throwIfCurrentCancelled();
    if (cloud == CloudProvider.torbox) {
      await _sendSourceToTorBox(chosen, item, episode);
    } else if (cloud == CloudProvider.realDebrid) {
      await _sendSourceToRealDebrid(chosen, item, episode);
    } else if (cloud == CloudProvider.premiumize) {
      await _sendSourceToPremiumize(chosen, item, episode);
    } else {
      await _sendSourceToPikPak(chosen, item, episode);
    }
    return null;
  }

  EpisodeItem? _episodeForPinnedRelease(
    MediaItem item,
    PinnedSourcePreference pinned,
  ) {
    if (item.kind != MediaKind.series || item.episodes.isEmpty) return null;
    final match = RegExp(r's(\d{1,2})e(\d{1,3})', caseSensitive: false)
        .firstMatch(pinned.label);
    if (match != null) {
      final season = int.tryParse(match.group(1)!);
      final number = int.tryParse(match.group(2)!);
      for (final episode in item.episodes) {
        if (episode.season == season && episode.episode == number) {
          return episode;
        }
      }
    }
    final selected = _selectedSeason;
    final episodes = item.episodes
        .where((episode) => selected == null || episode.season == selected)
        .toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));
    return episodes.isNotEmpty ? episodes.first : item.episodes.first;
  }

  Future<void> _playPinnedRelease(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    if (_resolving || !mounted) return;
    if (item.kind == MediaKind.series && episode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No episode is available for this series.')),
      );
      return;
    }
    final pinKey = widget.sources.sourceTargetKey(item);
    final pinned = await widget.sources.getPinnedSourcePreference(pinKey);
    if (pinned == null || !mounted) return;
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = 'Finding pinned release: ${pinned.label}…';
    });
    try {
      final results = await widget.sources.resolve(item, episode: episode);
      if (!mounted) return;
      SourceResult? match;
      for (final result in results) {
        if (widget.sources.matchesPinned(
          result,
          pinned.identity,
          seriesWide: item.kind == MediaKind.series,
        )) {
          match = result;
          break;
        }
      }
      if (match == null) {
        setState(() {
          _resolving = false;
          _resolveProgress = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Pinned release is not being returned by the current source providers right now: ${pinned.label}',
            ),
          ),
        );
        return;
      }
      await _playSourceResult(match, item, episode);
    } catch (error) {
      _showPlayError(error);
    }
  }

  Future<void> _showNoSourcesDialog(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    final configured = await widget.sources.getAddonUrls();
    final providersFailed = widget.sources.lastResolveHadProviderFailures(
      item,
      episode: episode,
    );
    if (!mounted) return;

    final openSources = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          configured.isEmpty
              ? 'No source providers configured'
              : providersFailed
                  ? 'Source providers did not respond'
                  : 'No sources found',
        ),
        content: Text(
          configured.isEmpty
              ? 'Configure a Stremio-compatible source provider. Direct HTTP streams play immediately, and torrent/magnet sources can use Orvix built-in local P2P engine on Windows, Android, Android TV and macOS. PikPak/TorBox are optional cloud paths.'
              : providersFailed
                  ? 'One or more source providers timed out or returned an error. This is usually temporary, so try again in a moment.'
                  : 'Your configured providers did not return a source for this title. You can manage providers or try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          if (configured.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
                _findSourcesAndPlay(
                  item,
                  episode: episode,
                  forceRefresh: true,
                );
              },
              child: const Text('Try Again'),
            ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.extension_outlined),
            label: const Text('Configure Sources'),
          ),
        ],
      ),
    );

    if (openSources == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: const Color(0xFF050806),
            appBar: AppBar(title: const Text('Source Providers')),
            body: SourcesScreen(sources: widget.sources),
          ),
        ),
      );
    }
  }

  Future<CloudProvider?> _chooseCloudProvider() async {
    final preferred = await widget.cloudPreferences.getPreferred();
    final connected = <CloudProvider>[];
    if (await widget.pikpak.isSignedIn) connected.add(CloudProvider.pikpak);
    if (await widget.torbox.isConnected) connected.add(CloudProvider.torbox);
    if (await RealDebridService.instance.isConnected) connected.add(CloudProvider.realDebrid);
    if (await PremiumizeService.instance.isConnected) connected.add(CloudProvider.premiumize);
    if (connected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connect PikPak, TorBox, Real-Debrid or Premiumize first. Direct / Free sources play without a debrid account.')),
        );
      }
      return null;
    }
    if (connected.length == 1) return connected.first;
    if (!mounted) return connected.contains(preferred) ? preferred : connected.first;
    final chosen = await showDialog<CloudProvider>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send source to'),
        content: const Text('Choose the connected cloud/debrid service Orvix should use for this source.'),
        actions: [
          for (final provider in connected)
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, provider),
              icon: Icon(provider == CloudProvider.torbox ? Icons.bolt_rounded : Icons.cloud_outlined),
              label: Text(provider.label),
            ),
        ],
      ),
    );
    if (chosen != null) await widget.cloudPreferences.setPreferred(chosen);
    return chosen;
  }

  Future<void> _sendSourceToRealDebrid(SourceResult chosen, MediaItem item, EpisodeItem? episode) async {
    if (!mounted) return;
    setState(() { _resolving=true; _resolveProgress=null; _status='Preparing source with Real-Debrid…'; });
    final url=await RealDebridService.instance.resolveMagnet(chosen.resource,fileIndex:chosen.torrentFileIndex,fileNameHint:chosen.fileNameHint);
    if (!mounted) return;
    await _openPlayerUrl(url,item,episode,source:chosen,releaseHint:_sourceReleaseHint(chosen),expectedSizeBytes:chosen.sizeBytes,expectedVideoHash:chosen.videoHash,useLocalMediaBridge:true);
  }

  Future<void> _sendSourceToPremiumize(SourceResult chosen, MediaItem item, EpisodeItem? episode) async {
    if (!mounted) return;
    setState(() { _resolving=true; _resolveProgress=null; _status='Preparing source with Premiumize…'; });
    final url=await PremiumizeService.instance.resolveMagnet(chosen.resource,fileIndex:chosen.torrentFileIndex,fileNameHint:chosen.fileNameHint);
    if (!mounted) return;
    await _openPlayerUrl(url,item,episode,source:chosen,releaseHint:_sourceReleaseHint(chosen),expectedSizeBytes:chosen.sizeBytes,expectedVideoHash:chosen.videoHash,useLocalMediaBridge:true);
  }

  Future<void> _sendSourceToTorBox(
    SourceResult chosen,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _resolveProgress = .02;
      _status = 'Sending ${chosen.quality ?? 'source'} to TorBox…';
    });
    final taskName =
        episode == null ? item.title : '${item.title} ${episode.label}';
    final added = await widget.torbox.addResource(
      chosen.resource,
      name: taskName,
    );
    for (var attempt = 0; attempt < 90; attempt++) {
      if (!mounted) return;
      PlaybackPreparation.throwIfCurrentCancelled();
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
      PlaybackPreparation.throwIfCurrentCancelled();
      final cloudItem = await widget.torbox.getItem(
        added.kind,
        added.id,
        fresh: true,
      );
      if (cloudItem == null) continue;
      setState(() {
        _resolveProgress =
            (cloudItem.progress / 100).clamp(0.0, 1.0).toDouble();
        _status = cloudItem.isReady
            ? 'TorBox is ready — opening player…'
            : 'TorBox • ${cloudItem.progress.toStringAsFixed(0)}%${cloudItem.state.isEmpty ? '' : ' • ${cloudItem.state}'}';
      });
      if (cloudItem.isError)
        throw TorBoxException('TorBox: ${cloudItem.state}');
      if (!cloudItem.isReady) continue;
      final file = widget.torbox.choosePlayableFile(
        cloudItem,
        fileNameHint: chosen.fileNameHint,
        fileIndex: chosen.torrentFileIndex,
      );
      if (file == null)
        throw const TorBoxException(
          'TorBox finished, but no playable video file was found.',
        );
      final url = await widget.torbox.requestDownloadUrl(cloudItem, file);
      await _openPlayerUrl(
        url,
        item,
        episode,
        source: chosen,
        releaseHint: file.identityPath,
        expectedSizeBytes: file.size,
        expectedVideoHash: chosen.videoHash,
        useLocalMediaBridge: true,
        torBoxItem: cloudItem,
        torBoxVideoFile: file,
      );
      return;
    }
    throw const TorBoxException(
      'TorBox is still preparing this source. Open Clouds to check its progress.',
    );
  }

  Future<void> _sendSourceToPikPak(
    SourceResult chosen,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _resolveProgress = .02;
      _status = 'Sending ${chosen.quality ?? 'source'} to PikPak…';
    });

    final taskName = episode == null
        ? '${item.title}${item.year == null ? '' : ' (${_extractYear(item.year!) ?? item.year!})'}'
        : '${item.title} ${episode.label}';
    final added = await widget.transfer.addResource(
      chosen.resource,
      name: taskName,
    );

    if (added.taskId != null) {
      await _waitForTask(
        added.taskId!,
        initialFileId: added.fileId,
        item: item,
        episode: episode,
        source: chosen,
      );
      return;
    }

    if (added.fileId != null &&
        await _tryOpenFileId(
          added.fileId!,
          item,
          episode,
          source: chosen,
        )) {
      return;
    }

    await _waitForLibraryMatch(
      item,
      episode: episode,
      source: chosen,
    );
  }

  Future<void> _waitForTask(
    String taskId, {
    required MediaItem item,
    EpisodeItem? episode,
    String? initialFileId,
    SourceResult? source,
  }) async {
    var fileId = initialFileId;
    for (var attempt = 0; attempt < 45; attempt++) {
      if (!mounted) return;
      PlaybackPreparation.throwIfCurrentCancelled();
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      PlaybackPreparation.throwIfCurrentCancelled();

      final status = await widget.transfer.getTaskStatus(taskId);
      fileId = status.fileId ?? fileId;
      final progress = (status.progress / 100).clamp(0.0, 1.0).toDouble();
      setState(() {
        _resolveProgress = progress;
        _status = status.isComplete
            ? 'PikPak finished preparing the cloud item…'
            : 'PikPak cloud task • ${status.progress.round()}%';
      });

      if (status.isError) {
        throw PikPakTransferException(
          status.message?.trim().isNotEmpty == true
              ? status.message!
              : 'PikPak cloud task failed.',
        );
      }

      if (status.isComplete) {
        setState(() {
          _resolveProgress = 1;
          _status = 'Ready — opening player…';
        });
        if (fileId != null &&
            await _tryOpenFileId(
              fileId,
              item,
              episode,
              source: source,
            )) {
          return;
        }
        for (var scan = 0; scan < 5; scan++) {
          final match = await _findInPikPak(item, episode: episode);
          if (match != null) {
            await _openPikPakFile(
              match,
              item,
              episode,
              source: source,
            );
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        throw const PikPakTransferException(
          'PikPak completed the task but the playable video is not visible yet.',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'The PikPak task is still running. You can check it again shortly.',
        ),
      ),
    );
  }

  Future<void> _waitForLibraryMatch(
    MediaItem item, {
    EpisodeItem? episode,
    SourceResult? source,
  }) async {
    for (var attempt = 1; attempt <= 18; attempt++) {
      if (!mounted) return;
      PlaybackPreparation.throwIfCurrentCancelled();
      setState(() {
        _resolveProgress = (.05 + attempt / 20).clamp(0, .94).toDouble();
        _status = 'Waiting for the new PikPak file… ${attempt * 5}s';
      });
      await Future<void>.delayed(const Duration(seconds: 5));
      PlaybackPreparation.throwIfCurrentCancelled();
      final match = await _findInPikPak(item, episode: episode);
      if (match != null) {
        await _openPikPakFile(
          match,
          item,
          episode,
          source: source,
        );
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Added to PikPak. It is still preparing; check My PikPak shortly.',
        ),
      ),
    );
  }

  Future<SourceResult?> _chooseSource(
    List<SourceResult> results,
    MediaItem item,
    EpisodeItem? episode, {
    FreeP2pLiveProbeService? probeSession,
  }) async {
    // Same eligibility as Normal Play and playback: Free P2P ranking and live
    // probing apply only when no cloud/debrid provider is connected.
    final hasCloudConnection = await _hasCloudConnection();

    if (PlatformProfile.isAndroidTv) {
      if (!mounted) return null;
      return Navigator.of(context).push<SourceResult>(
        PageRouteBuilder<SourceResult>(
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 140),
          pageBuilder: (_, animation, __) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: TvSourceBrowserScreen(
              sources: widget.sources,
              item: item,
              episode: episode,
              resultsFuture: Future.value(results),
              preferFreeP2p: !hasCloudConnection,
              probeSession: probeSession,
            ),
          ),
        ),
      );
    }
    var priority = await widget.sources.getPriorityOrder();
    var resultLimit = await widget.sources.getResultLimit();
    var compatibilityOnly = false;
    // Live probing and its playback gate belong to the Free P2P playback
    // path only; with a cloud/debrid connection playback never uses these
    // torrent sessions. The display mode below never changes this.
    final liveCheckAllowed = !hasCloudConnection;
    var displayMode =
        await widget.sources.getDisplayMode(liveCheck: liveCheckAllowed);
    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
    final seriesWidePin = item.kind == MediaKind.series;
    var pinnedIdentity = await widget.sources.getPinnedSourceIdentity(pinKey);
    if (!mounted) return null;

    final liveProbe = probeSession ??
        FreeP2pLiveProbeService(
          mediaDuration: FreeP2pLiveProbeService.parseMediaRuntime(item.runtime),
        );
    final ownsProbeSession = probeSession == null;
    // The user's Source Priority (My Priority, Quick Play) and the chosen
    // display mode order rows inside each live-health group.
    liveProbe.setPriority(priority);
    liveProbe.setDisplayMode(displayMode);
    // Reopened after playback: keep the list the user chose from while its
    // evidence is fresh. Otherwise (first open, or after Normal Play) the
    // picker continues the bounded check in the background.
    var liveProbeStarted = liveProbe.isFrozen && liveProbe.hasAnyResult;

    Future<void> customizePriority(
      BuildContext dialogContext,
      StateSetter setSheetState,
    ) async {
      final working = [...priority];
      final saved = await showDialog<List<SourceSortCriterion>>(
        context: dialogContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Source priority'),
            content: SizedBox(
              width: (MediaQuery.sizeOf(dialogContext).width - 80)
                  .clamp(260.0, 430.0)
                  .toDouble(),
              height: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Drag criteria into the order you want. #1 has the highest priority.',
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ReorderableListView.builder(
                      itemCount: working.length,
                      onReorder: (oldIndex, newIndex) {
                        setDialogState(() {
                          if (newIndex > oldIndex) newIndex--;
                          final item = working.removeAt(oldIndex);
                          working.insert(newIndex, item);
                        });
                      },
                      itemBuilder: (context, index) {
                        final criterion = working[index];
                        return ListTile(
                          key: ValueKey(criterion.name),
                          leading: CircleAvatar(child: Text('${index + 1}')),
                          title: Text(
                            criterion.label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          trailing: const Icon(Icons.drag_indicator_rounded),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, [
                  ...SourceProviderService.defaultPriority,
                ]),
                child: const Text('Reset default'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, working),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
      if (saved != null) {
        await widget.sources.setPriorityOrder(saved);
        // Saving a priority is a request to sort by it: rows reorder at once
        // under My Priority, and the background check also follows it.
        await widget.sources.setDisplayMode(SourceDisplayMode.myPriority);
        setSheetState(() {
          priority = saved;
          liveProbe.setPriority(saved);
          displayMode = SourceDisplayMode.myPriority;
          liveProbe.setDisplayMode(displayMode);
        });
      }
    }

    void selectDisplayMode(SourceDisplayMode mode, StateSetter setSheetState) {
      if (mode == displayMode) return;
      setSheetState(() {
        displayMode = mode;
        liveProbe.setDisplayMode(mode);
      });
      unawaited(widget.sources.setDisplayMode(mode));
    }

    // How the sheet's result was chosen, for the playback report.
    var selectedVia = 'manual';

    bool isPinnedResult(SourceResult result) => widget.sources.matchesPinned(
          result,
          pinnedIdentity,
          seriesWide: seriesWidePin,
        );

    final selected = await showModalBottomSheet<SourceResult>(
      context: context,
      backgroundColor: const Color(0xFF090D0B),
      barrierColor: Colors.black.withValues(alpha: .68),
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: const BoxConstraints(maxWidth: 1080),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          // The live check runs whatever the display mode, so changing the
          // order can never skip or reset playback safety.
          if (liveCheckAllowed && !liveProbeStarted) {
            liveProbeStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(
                liveProbe
                    .probeTopCandidates(
                      results,
                      widget.sources,
                      // While the picker is open, keep classifying more rows
                      // in small bounded batches.
                      continueInBackground: true,
                      // An unchecked pin is checked in the first batch.
                      preferred: results.where(isPinnedResult).firstOrNull,
                      onUpdate: () {
                        if (sheetContext.mounted) {
                          setSheetState(() {});
                        }
                      },
                    )
                    .catchError((_) {}),
              );
            });
          }

          final sheetWidth = MediaQuery.sizeOf(context).width;
          final compactSheet = sheetWidth < 680;
          final desktopSheet = Platform.isWindows && sheetWidth >= 900;
          final ranked = liveCheckAllowed
              ? liveProbe.rank(results, widget.sources)
              : switch (displayMode) {
                  SourceDisplayMode.recommended =>
                    widget.sources.sortRecommended(results),
                  SourceDisplayMode.myPriority =>
                    widget.sources.sortResults(results, priority),
                  SourceDisplayMode.smooth =>
                    widget.sources.sortForSmoothPlayback(results),
                };
          final filtered = compatibilityOnly
              ? ranked
                  .where((result) => result.compatibilityFriendly)
                  .toList(growable: false)
              : [...ranked];
          final compatibilityHiddenCount = ranked.length - filtered.length;

          var ordered = [...filtered];
          if (pinnedIdentity != null) {
            if (liveCheckAllowed) {
              // A pin stays on top unless it was just confirmed unplayable
              // while another torrent is confirmed live.
              ordered = liveProbe.applyPinnedPreference(
                ordered,
                isPinnedResult,
              );
            } else {
              final pinnedIndex = ordered.indexWhere(isPinnedResult);
              if (pinnedIndex > 0) {
                final pinned = ordered.removeAt(pinnedIndex);
                ordered.insert(0, pinned);
              }
            }
          }

          final totalAfterFilter = ordered.length;
          // In Free P2P the limit never hides every confirmed-live torrent.
          final sorted = liveCheckAllowed
              ? liveProbe.applyResultLimit(ordered, resultLimit)
              : resultLimit > 0 && ordered.length > resultLimit
                  ? ordered.take(resultLimit).toList(growable: false)
                  : ordered;
          final limitHiddenCount = totalAfterFilter - sorted.length;
          final best = sorted.isEmpty ? null : sorted.first;
          // Quick Play must not depend on display order. In Free P2P it takes
          // the best eligible source (a confirmed-live pin first) from the
          // playback order, and never an unconfirmed or failed torrent.
          final quickPlaySource = liveCheckAllowed
              ? liveProbe.quickPlayCandidate(
                  filtered,
                  widget.sources,
                  isPinned: isPinnedResult,
                )
              : best;
          final color = Theme.of(context).colorScheme;
          // Health-group labels (Confirmed live, Not checked yet, Metadata
          // slow, Failed the live check). Failed torrents sit together at the
          // bottom and stay selectable for a manual choice.
          final groupHeaders = liveCheckAllowed
              ? liveProbe.groupHeaders(sorted, isPinned: isPinnedResult)
              : const <int, FreeP2pGroupHeader>{};

          // Same shape for every row, so a row that gains or loses a group
          // label keeps its element (and any keyboard focus).
          Widget withGroupHeader(int index, Widget row) {
            final header = groupHeaders[index];
            final failed = header?.group == FreeP2pGroup.failed;
            final headerColor = failed ? color.error : color.onSurfaceVariant;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header != null)
                  Padding(
                    key: ValueKey(
                      failed ? 'free-p2p-failed-group' : 'free-p2p-group',
                    ),
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
                    child: Row(
                      children: [
                        Icon(
                          switch (header.group) {
                            FreeP2pGroup.direct => Icons.link_rounded,
                            FreeP2pGroup.live => Icons.bolt_rounded,
                            FreeP2pGroup.notChecked =>
                              Icons.radio_button_unchecked_rounded,
                            FreeP2pGroup.metadataSlow =>
                              Icons.hourglass_bottom_rounded,
                            FreeP2pGroup.failed =>
                              Icons.report_gmailerrorred_rounded,
                          },
                          size: 16,
                          color: headerColor,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            header.label,
                            style: TextStyle(
                              color: headerColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                KeyedSubtree(key: const ValueKey('source-row'), child: row),
              ],
            );
          }
          final priorityText =
              priority.map((e) => e.label.toLowerCase()).join(' → ');
          const healthGroups =
              'live → not checked → metadata slow → failed check';
          final rankingText = switch (displayMode) {
            SourceDisplayMode.recommended => liveCheckAllowed
                ? 'Recommended: $healthGroups; live by ready now, first byte, real speed and live peers'
                : 'Recommended: cached → device compatibility, exact file, reported swarm, practical size',
            SourceDisplayMode.myPriority => liveCheckAllowed
                ? 'My Priority: $healthGroups; within each group: $priorityText'
                : 'My Priority: $priorityText',
            SourceDisplayMode.smooth => liveCheckAllowed
                ? 'Smooth: $healthGroups; within each group: compatibility → 1080/720 → efficient codec → seeders → smaller files'
                : 'Smooth: compatibility → 1080/720 → efficient codec → seeders → smaller files → cache',
          };
          final summaryParts = <String>[
            resultLimit > 0
                ? 'Showing ${sorted.length} of $totalAfterFilter results'
                : '${sorted.length} result${sorted.length == 1 ? '' : 's'} shown',
            if (liveCheckAllowed) 'Free P2P live check on',
            if (compatibilityHiddenCount > 0)
              '$compatibilityHiddenCount risky hidden',
            if (limitHiddenCount > 0) '$limitHiddenCount beyond limit',
          ];

          final liveSummary =
              liveCheckAllowed ? liveProbe.summary(results).text : null;

          Widget quickPlayButton(SourceResult source) {
            // Quick Play in Free P2P only launches a torrent that is confirmed
            // live, pinned or not. Every row stays selectable for a manual
            // choice, including an unconfirmed pin.
            final pinned = widget.sources.matchesPinned(source, pinnedIdentity);
            final waitingForProbe =
                liveCheckAllowed && !liveProbe.quickPlayAllowed(source);
            final checking = liveCheckAllowed && liveProbe.isRunning;
            return FilledButton.tonalIcon(
              onPressed: waitingForProbe
                  ? null
                  : () {
                      liveProbe.freezeRanking(results, widget.sources);
                      selectedVia = 'quickPlay';
                      Navigator.pop(sheetContext, source);
                    },
              icon: Icon(
                waitingForProbe
                    ? Icons.radar_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                waitingForProbe
                    ? checking
                        ? 'Checking live…'
                        : 'No live source'
                    : pinned
                        ? 'Play pinned'
                        : 'Quick Play ${source.quality ?? ''}'.trim(),
              ),
              style: FilledButton.styleFrom(
                padding: EdgeInsets.symmetric(
                  horizontal: compactSheet ? 14 : 18,
                  vertical: compactSheet ? 10 : 12,
                ),
              ),
            );
          }

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height *
                  (desktopSheet ? .88 : .84),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compactSheet ? 16 : 22,
                  4,
                  compactSheet ? 16 : 22,
                  24,
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
                                'Choose source',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -.35,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                episode == null
                                    ? item.title
                                    : '${item.title} • ${episode.label}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF98A19A),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (desktopSheet)
                          const Icon(
                            Icons.movie_filter_rounded,
                            color: Color(0xFFB9FF45),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      summaryParts.join(' • '),
                      style: TextStyle(color: color.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // One display mode at a time. Display only: the Free
                        // P2P live check and Quick Play gate stay the same.
                        for (final mode in SourceDisplayMode.values)
                          ChoiceChip(
                            showCheckmark: false,
                            selected: displayMode == mode,
                            avatar: Icon(
                              switch (mode) {
                                SourceDisplayMode.recommended =>
                                  Icons.auto_awesome_rounded,
                                SourceDisplayMode.myPriority =>
                                  Icons.format_list_numbered_rounded,
                                SourceDisplayMode.smooth => Icons.speed_rounded,
                              },
                              size: 18,
                            ),
                            label: Text(mode.label),
                            tooltip: switch (mode) {
                              SourceDisplayMode.recommended =>
                                'Orvix order: confirmed-live sources first, then the most playable ones.',
                              SourceDisplayMode.myPriority =>
                                'Your Source Priority (Sort), inside each live-health group.',
                              SourceDisplayMode.smooth =>
                                'Compatible, efficient 1080p/720p sources first, inside each live-health group.',
                            },
                            onSelected: (_) =>
                                selectDisplayMode(mode, setSheetState),
                          ),
                        FilterChip(
                          showCheckmark: false,
                          selected: compatibilityOnly,
                          avatar: Icon(
                            compatibilityOnly
                                ? Icons.verified_rounded
                                : Icons.verified_outlined,
                            size: 18,
                          ),
                          label: const Text('Compatibility'),
                          tooltip:
                              'Hide known-risk formats such as AV1, 8K, Hi10P and Dolby Vision-only releases.',
                          onSelected: (value) =>
                              setSheetState(() => compatibilityOnly = value),
                        ),
                        if (!PlatformProfile.isAndroidMobile)
                          OutlinedButton.icon(
                            onPressed: () =>
                                customizePriority(sheetContext, setSheetState),
                            icon: const Icon(Icons.tune_rounded),
                            label: const Text('Sort'),
                          ),
                      ],
                    ),
                    if (PlatformProfile.isAndroidMobile) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () =>
                                customizePriority(sheetContext, setSheetState),
                            icon: const Icon(Icons.tune_rounded),
                            label: const Text('Sort'),
                          ),
                          if (best != null) ...[
                            const SizedBox(width: 10),
                            Flexible(child: quickPlayButton(quickPlaySource ?? best)),
                          ],
                        ],
                      ),
                    ] else if (best != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: quickPlayButton(quickPlaySource ?? best),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: color.primaryContainer.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.sort_rounded,
                            size: 18,
                            color: color.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              rankingText,
                              style: TextStyle(
                                color: color.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (liveSummary != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              liveProbe.noLiveConfirmed
                                  ? '$liveSummary\nNo source delivered live data. Choose one manually or re-check.'
                                  : liveSummary,
                              style: TextStyle(
                                color: color.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy live-check report',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.content_copy_rounded,
                                size: 18),
                            onPressed: () => unawaited(
                              Clipboard.setData(
                                ClipboardData(
                                  text: liveProbe.diagnosticReport(results),
                                ),
                              ),
                            ),
                          ),
                          TextButton.icon(
                            // Discards this picker's evidence (and any frozen
                            // order) and starts a fresh bounded check with the
                            // current Source Priority.
                            onPressed: () => setSheetState(() {
                              liveProbe.clear();
                              liveProbeStarted = false;
                            }),
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Re-check'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: sorted.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => withGroupHeader(
                            index, Builder(builder: (context) {
                          final result = sorted[index];
                          final isPinned = widget.sources.matchesPinned(
                            result,
                            pinnedIdentity,
                            seriesWide: seriesWidePin,
                          );
                          final health = liveCheckAllowed
                              ? liveProbe.displayHealthFor(result)
                              : null;
                          final healthMetrics = health?.metrics;
                          final statusLabel = isPinned
                              ? health != null
                                  ? 'Pinned • ${health.label}'
                                  : 'Pinned'
                              : health != null
                                  ? health.label
                                  : index == 0 &&
                                          !liveCheckAllowed &&
                                          displayMode ==
                                              SourceDisplayMode.smooth
                                      ? 'Smooth'
                                      : null;
                          // Provider seeds are a snapshot from the addon, not
                          // proof the torrent is usable; live numbers come
                          // from the probe.
                          final providerText =
                              '${result.provider}${result.isMagnet ? ' • torrent / P2P' : ' • direct URL'}'
                              '${liveCheckAllowed && result.isMagnet && result.seeders != null ? ' • ${result.seeders} seeders reported' : ''}'
                              '${healthMetrics == null ? '' : ' • $healthMetrics'}'
                              '${result.compatibilityFriendly ? '' : ' • ⚠ compatibility risk'}';

                          if (compactSheet) {
                            return InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                liveProbe.freezeRanking(results, widget.sources);
                                Navigator.pop(sheetContext, result);
                              },
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 23,
                                      child: Text(
                                        result.quality?.replaceAll('P', '') ??
                                            '—',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            result.title,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(height: 1.35),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            providerText,
                                            style: TextStyle(
                                              color: color.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                          if (statusLabel != null) ...[
                                            const SizedBox(height: 6),
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: Chip(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                avatar: isPinned
                                                    ? const Icon(
                                                        Icons.push_pin_rounded,
                                                        size: 15,
                                                      )
                                                    : null,
                                                label: Text(statusLabel),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: isPinned
                                          ? 'Unpin source'
                                          : 'Pin source',
                                      icon: Icon(
                                        isPinned
                                            ? Icons.push_pin_rounded
                                            : Icons.push_pin_outlined,
                                      ),
                                      onPressed: () async {
                                        if (isPinned) {
                                          await widget.sources
                                              .unpinSource(pinKey);
                                          if (!context.mounted) return;
                                          setSheetState(
                                            () => pinnedIdentity = null,
                                          );
                                        } else {
                                          await widget.sources.pinSource(
                                            pinKey,
                                            result,
                                            seriesWide: seriesWidePin,
                                          );
                                          final identity =
                                              widget.sources.sourceIdentity(
                                            result,
                                            seriesWide: seriesWidePin,
                                          );
                                          if (!context.mounted) return;
                                          setSheetState(
                                            () => pinnedIdentity = identity,
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }

                          return Material(
                            color: const Color(0xFF0C110E),
                            borderRadius: BorderRadius.circular(15),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(15),
                              onTap: () {
                                liveProbe.freezeRanking(results, widget.sources);
                                Navigator.pop(sheetContext, result);
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: isPinned
                                        ? const Color(0x66B9FF45)
                                        : Colors.white.withValues(alpha: .08),
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  leading: CircleAvatar(
                                    radius: 25,
                                    backgroundColor:
                                        const Color(0xFF263B18),
                                    foregroundColor:
                                        const Color(0xFFDCFFAA),
                                    child: Text(
                                      result.quality?.replaceAll('P', '') ?? '—',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    result.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(height: 1.38),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      providerText,
                                      style: const TextStyle(
                                        color: Color(0xFFAAB3AC),
                                      ),
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (statusLabel != null)
                                        Chip(
                                          avatar: isPinned
                                              ? const Icon(
                                                  Icons.push_pin_rounded,
                                                  size: 16,
                                                )
                                              : null,
                                          label: Text(statusLabel),
                                        ),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        tooltip: isPinned
                                            ? 'Unpin source'
                                            : 'Pin source',
                                        icon: Icon(
                                          isPinned
                                              ? Icons.push_pin_rounded
                                              : Icons.push_pin_outlined,
                                        ),
                                        onPressed: () async {
                                          if (isPinned) {
                                            await widget.sources
                                                .unpinSource(pinKey);
                                            if (!context.mounted) return;
                                            setSheetState(
                                              () => pinnedIdentity = null,
                                            );
                                          } else {
                                            await widget.sources.pinSource(
                                              pinKey,
                                              result,
                                              seriesWide: seriesWidePin,
                                            );
                                            final identity =
                                                widget.sources.sourceIdentity(
                                              result,
                                              seriesWide: seriesWidePin,
                                            );
                                            if (!context.mounted) return;
                                            setSheetState(
                                              () => pinnedIdentity = identity,
                                            );
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        })),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (selected != null && liveCheckAllowed) {
      await liveProbe.prepareForPlayback(selected, selection: selectedVia);
    } else if (ownsProbeSession) {
      await liveProbe.release();
    }
    return selected;
  }

  Future<TorBoxItem?> _findInTorBox(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    final items = await widget.torbox.listTorrents();
    TorBoxItem? best;
    var score = -1;
    for (final entry in items.where((e) => e.isReady)) {
      final s = _matchScore(entry.name, item, episode: episode);
      if (s > score) {
        score = s;
        best = entry;
      }
    }
    return score >= 85 ? best : null;
  }

  Future<void> _openTorBoxItem(
    TorBoxItem cloudItem,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    final file = widget.torbox.choosePlayableFile(
      cloudItem,
      fileNameHint: episode?.label,
    );
    if (file == null)
      throw const TorBoxException('No playable video file found in TorBox.');
    final url = await widget.torbox.requestDownloadUrl(cloudItem, file);
    await _openPlayerUrl(
      url,
      item,
      episode,
      releaseHint: file.identityPath,
      expectedSizeBytes: file.size,
      useLocalMediaBridge: true,
      torBoxItem: cloudItem,
      torBoxVideoFile: file,
    );
  }

  Future<PikPakFile?> _findInPikPak(
    MediaItem item, {
    EpisodeItem? episode,
  }) async {
    if (!await widget.pikpak.isSignedIn) return null;

    final folders = <String>[''];
    var scanned = 0;
    PikPakFile? bestMatch;
    var bestScore = -1;

    while (folders.isNotEmpty && scanned < 1200) {
      final folder = folders.removeAt(0);
      final files = await widget.pikpak.listFiles(parentId: folder);

      for (final file in files) {
        scanned++;
        if (file.isFolder) {
          if (folders.length < 100) folders.add(file.id);
          continue;
        }
        if (!_looksLikeVideo(file)) continue;

        final score = _matchScore(file.name, item, episode: episode);
        if (score > bestScore) {
          bestScore = score;
          bestMatch = file;
        }
      }
    }

    // Do not guess. Only strong matches are allowed to auto-play.
    return bestScore >= 85 ? bestMatch : null;
  }

  int _matchScore(String fileName, MediaItem item, {EpisodeItem? episode}) {
    final normalizedName = _normalize(fileName);
    final nameTokens =
        normalizedName.split(' ').where((e) => e.isNotEmpty).toSet();
    final normalizedTitle = _normalize(item.title);
    final titleTokens =
        normalizedTitle.split(' ').where((e) => e.isNotEmpty).toList();
    final meaningful = titleTokens
        .where((word) => !_weakTitleWords.contains(word))
        .toList(growable: false);
    final paddedName = ' $normalizedName ';
    final exactTitlePhrase = paddedName.contains(' $normalizedTitle ');

    if (!exactTitlePhrase) {
      final requiredTokens = meaningful.isEmpty ? titleTokens : meaningful;
      if (requiredTokens.isEmpty) return -1;

      // This is intentionally strict: every meaningful title token must exist.
      // It prevents e.g. "The Whisper Man" from matching "Spider-Man Noir".
      if (!requiredTokens.every(nameTokens.contains)) return -1;
      if (requiredTokens.length == 1 &&
          !nameTokens.contains(requiredTokens.first)) {
        return -1;
      }
    }

    if (episode != null) {
      if (!_matchesEpisode(normalizedName, episode)) return -1;
    } else if (item.kind == MediaKind.movie &&
        RegExp(r'\bs\d{1,2}e\d{1,3}\b').hasMatch(normalizedName)) {
      return -1;
    }

    final targetYear = item.year == null ? null : _extractYear(item.year!);
    final fileYears = RegExp(r'\b(?:19|20)\d{2}\b')
        .allMatches(normalizedName)
        .map((m) => m.group(0)!)
        .toSet();

    if (targetYear != null &&
        fileYears.isNotEmpty &&
        !fileYears.contains(targetYear)) {
      return -1;
    }

    var score = exactTitlePhrase ? 110 : 90;
    if (targetYear != null && fileYears.contains(targetYear)) score += 20;
    if (episode != null) score += 25;

    final lower = fileName.toLowerCase();
    if (lower.contains('2160p') || lower.contains('4k')) {
      score += 4;
    } else if (lower.contains('1080p')) {
      score += 3;
    } else if (lower.contains('720p')) {
      score += 2;
    }
    return score;
  }

  bool _matchesEpisode(String normalizedName, EpisodeItem episode) {
    final s = episode.season;
    final e = episode.episode;
    final ss = s.toString().padLeft(2, '0');
    final ee = e.toString().padLeft(2, '0');
    final variants = <String>{
      's${s}e$e',
      's${s}e$ee',
      's${ss}e$e',
      's${ss}e$ee',
      '${s}x$e',
      '${s}x$ee',
      'season $s episode $e',
      'season $s episode $ee',
    };
    final padded = ' $normalizedName ';
    return variants.any((value) => padded.contains(' $value '));
  }

  bool _looksLikeVideo(PikPakFile file) {
    final mime = file.mimeType?.toLowerCase().trim();
    if (mime != null && mime.isNotEmpty) {
      if (mime.startsWith('video/')) return true;
      if (!mime.contains('octet-stream')) return false;
    }

    final name = file.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return true;
    return _videoExtensions.contains(name.substring(dot + 1));
  }

  Future<bool> _tryOpenFileId(
    String fileId,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? source,
  }) async {
    try {
      final windowsAi =
          Platform.isWindows && await AiSinhalaPreferencesService.isEnabled();
      if (windowsAi && mounted) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status =
              'AI Sinhala • requesting the original PikPak container…';
        });
      }

      final url = await widget.transfer.fetchPlayableUrl(
        fileId,
        preferOriginal: windowsAi,
      );
      unawaited(
        AiSinhalaTraceService.write(
          'pikpak-file-id originalRequested=$windowsAi '
          'resolved=${url != null && url.isNotEmpty} '
          'host=${AiSinhalaTraceService.safeHost(url)}',
        ),
      );
      if (url == null || url.isEmpty) {
        if (windowsAi) {
          throw const PikPakTransferException(
            'PikPak did not expose the original video container. Only a provider rendition/transcode is available, so Orvix cannot safely recover embedded subtitles or an exact-file hash.',
          );
        }
        return false;
      }

      await _openPlayerUrl(
        url,
        item,
        episode,
        source: source,
        releaseHint: source?.fileNameHint,
        expectedSizeBytes: source?.sizeBytes,
        expectedVideoHash: source?.videoHash,
        useLocalMediaBridge: true,
      );
      return true;
    } catch (_) {
      if (source != null) rethrow;
      return false;
    }
  }

  Future<void> _openPikPakFile(
    PikPakFile file,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? source,
  }) async {
    if (!mounted) return;

    final windowsAi =
        Platform.isWindows && await AiSinhalaPreferencesService.isEnabled();
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = windowsAi
          ? 'AI Sinhala • resolving the original PikPak container…'
          : 'Resolving PikPak streaming URL…';
    });

    final url = await widget.transfer.fetchPlayableUrl(
          file.id,
          preferOriginal: windowsAi,
        ) ??
        (windowsAi ? null : file.webContentLink);
    unawaited(
      AiSinhalaTraceService.write(
        'pikpak-library originalRequested=$windowsAi '
        'resolved=${url != null && url.isNotEmpty} '
        'host=${AiSinhalaTraceService.safeHost(url)}',
      ),
    );

    if (url == null || url.isEmpty) {
      if (windowsAi) {
        throw const PikPakTransferException(
          'PikPak exposed only a transcoded rendition for this file. AI Sinhala requires the original container so embedded subtitles and exact-file fingerprinting remain valid.',
        );
      }
      throw Exception('PikPak did not return a playable URL yet.');
    }

    final parsedFileSize = int.tryParse(file.size ?? '');
    await _openPlayerUrl(
      url,
      item,
      episode,
      source: source,
      releaseHint: source?.fileNameHint ?? file.name,
      expectedSizeBytes: source?.sizeBytes ?? parsedFileSize,
      expectedVideoHash: source?.videoHash,
      useLocalMediaBridge: true,
    );
  }

  Future<AiGeneratedSubtitleFile?> _tryTorBoxSiblingSubtitle({
    required TorBoxItem cloudItem,
    required TorBoxFile videoFile,
    required String title,
    EpisodeItem? episode,
  }) async {
    final textSubtitleCount =
        cloudItem.files.where((file) => file.isTextSubtitle).length;
    final candidates = TorBoxService.rankSubtitleCandidatesForVideo(
      cloudItem,
      videoFile,
      season: episode?.season,
      episode: episode?.episode,
    );

    String safeName(String raw) {
      final clean = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
      return clean.length <= 180 ? clean : clean.substring(0, 180);
    }

    unawaited(
      AiSinhalaTraceService.write(
        'torbox-subtitle-scan itemId=${cloudItem.id} '
        'files=${cloudItem.files.length} textSubs=$textSubtitleCount '
        'video="${safeName(videoFile.identityPath)}" '
        'candidates=${candidates.length}',
      ),
    );

    if (textSubtitleCount == 0) {
      unawaited(
        AiSinhalaTraceService.write(
          'torbox-subtitle-miss reason=no-text-subtitle-files',
        ),
      );
      return null;
    }

    if (candidates.isEmpty) {
      final names = cloudItem.files
          .where((file) => file.isTextSubtitle)
          .take(8)
          .map((file) => safeName(file.identityPath))
          .join(' | ');
      unawaited(
        AiSinhalaTraceService.write(
          'torbox-subtitle-miss reason=no-safe-video-match '
          'available="$names"',
        ),
      );
      return null;
    }

    for (final candidate in candidates.take(5)) {
      final subtitle = candidate.file;
      final candidateName = safeName(subtitle.identityPath);
      unawaited(
        AiSinhalaTraceService.write(
          'torbox-subtitle-candidate id=${subtitle.id} '
          'score=${candidate.score} reason=${candidate.reason} '
          'name="$candidateName"',
        ),
      );

      if (mounted) {
        setState(() {
          _status =
              'AI Sinhala • checking TorBox subtitle • $candidateName';
        });
      }

      try {
        final subtitleUrl =
            await widget.torbox.requestDownloadUrl(cloudItem, subtitle);
        final generated = await AiSinhalaSubtitleService
            .prepareGeneratedSinhalaFromVerifiedExternalSubtitle(
          title: title,
          subtitleUrl: subtitleUrl,
          subtitleIdentity:
              'torbox://${cloudItem.kind.name}/${cloudItem.id}/${subtitle.id}',
          subtitleLabel: 'TorBox exact torrent • ${subtitle.name}',
          sourceName: 'torbox-same-torrent-subtitle',
          onStatus: (message) {
            if (!mounted) return;
            setState(() => _status = 'AI Sinhala • $message');
          },
        );

        unawaited(
          AiSinhalaTraceService.write(
            'torbox-subtitle-selected id=${subtitle.id} '
            'score=${candidate.score} name="$candidateName"',
          ),
        );
        return generated;
      } on AiSubtitleException catch (error) {
        final lower = error.message.toLowerCase();
        final candidateSpecific =
            lower.contains('not verified as english') ||
            lower.contains('could not be parsed safely');
        unawaited(
          AiSinhalaTraceService.write(
            'torbox-subtitle-rejected id=${subtitle.id} '
            'candidateSpecific=$candidateSpecific '
            'detail="${safeName(error.message)}"',
          ),
        );
        if (!candidateSpecific) rethrow;
      } on TorBoxException catch (error) {
        unawaited(
          AiSinhalaTraceService.write(
            'torbox-subtitle-fetch-failed id=${subtitle.id} '
            'detail="${safeName(error.message)}"',
          ),
        );
      }
    }

    unawaited(
      AiSinhalaTraceService.write(
        'torbox-subtitle-miss reason=candidates-not-usable',
      ),
    );
    return null;
  }

  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? source,
    String? aiSourceUrl,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    bool useLocalMediaBridge = false,
    TorBoxItem? torBoxItem,
    TorBoxFile? torBoxVideoFile,
  }) async {
    if (!mounted) return;

    final aiSettingEnabled =
        await AiSinhalaPreferencesService.isEnabled();
    PlaybackPreparation.throwIfCurrentCancelled();

    // AI Sinhala no longer blocks Windows behind a complete-file preflight.
    // The cross-platform MPV player now opens the exact source first, discovers
    // the subtitle tracks the real player can actually see, and progressively
    // translates those native English cues. Keep the old complete-file engine
    // code below as a dormant recovery path while the new architecture is
    // validated; it must not delay normal startup.
    final legacyWindowsAiPreflight = Platform.isWindows &&
        aiSettingEnabled &&
        _legacyCompleteFileAiPreflightEnabled;
    // AI Sinhala beta is temporarily limited to original Free P2P sources.
    // Debrid/cloud playback must stay normal and must never enter AI preflight.
    final nativeCueAi = aiSettingEnabled;
    final originalUri = Uri.tryParse(url);
    final originalLocalP2p = originalUri != null &&
        (originalUri.host == '127.0.0.1' || originalUri.host == 'localhost') &&
        originalUri.port == 11470 &&
        originalUri.pathSegments.length >= 2 &&
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(originalUri.pathSegments.first) &&
        int.tryParse(originalUri.pathSegments[1]) != null;

    unawaited(
      AiSinhalaTraceService.write(
        'open-player ai=$aiSettingEnabled windows=${Platform.isWindows} '
        'provider=${source?.provider ?? 'unknown'} '
        'cloudBridge=$useLocalMediaBridge localP2p=$originalLocalP2p '
        'torBoxTree=${torBoxItem != null && torBoxVideoFile != null} '
        'nativeCueAi=$nativeCueAi '
        'host=${AiSinhalaTraceService.safeHost(url)}',
      ),
    );

    LocalMediaBridgeHandle? bridgeHandle;
    var playbackUrl = url;

    // The normal Windows path now converges cloud/debrid media onto the same
    // modified stream-server used by Free P2P. The old standalone 11471
    // complete-file preflight is disabled and retained only as dormant recovery
    // code, so active playback + AI share one 11470 transport.
    if (useLocalMediaBridge && !legacyWindowsAiPreflight) {
      var nativeEngineReady = false;

      if (Platform.isWindows) {
        setState(() {
          _resolving = true;
          _status = 'Opening through the Orvix stream engine…';
        });
        try {
          playbackUrl = await LocalTorrentService.instance.proxyRemoteUrl(
            url,
            fileNameHint: releaseHint,
          );
          nativeEngineReady = true;
        } catch (_) {
          if (mounted) {
            setState(() {
              _status =
                  'Native stream engine could not read this source; using the local media bridge…';
            });
          }
        }
      }

      PlaybackPreparation.throwIfCurrentCancelled();
      if (!nativeEngineReady) {
        setState(() {
          _resolving = true;
          _status = 'Opening through the Orvix local media bridge…';
        });
        bridgeHandle = await LocalMediaBridgeService.instance.bridge(
          url,
          fileNameHint: releaseHint,
        );
        playbackUrl = bridgeHandle.url;
        if (PlaybackPreparation.current?.isCancelled == true) {
          await LocalMediaBridgeService.instance.release(
            bridgeHandle.sessionId,
          );
          throw const PlaybackPreparationCancelled();
        }
      }
    }

    final title = episode == null
        ? item.title
        : '${item.title} • ${episode.label} ${episode.title}';
    final next = _nextEpisode(item, episode);

    AiGeneratedSubtitleFile? preparedAiSubtitleFile;
    var aiPreflightAttempted = false;
    String? aiPreflightFailure;

    // Windows debrid/cloud AI now mirrors the proven complete-file Free P2P
    // subtitle flow: inspect the exact selected media before opening MPV,
    // extract the full English text subtitle through the modified 11470 engine,
    // translate every cue, write one Sinhala SRT, then open the player.
    //
    // IMPORTANT: original Free P2P playback is explicitly excluded here. Its
    // existing resolver/stream lifecycle is left untouched; this block only
    // makes cloud/debrid behave like that known-good subtitle architecture.
    final windowsDebridCompleteSubtitlePreflight = false;

    if (windowsDebridCompleteSubtitlePreflight) {
      aiPreflightAttempted = true;
      if (mounted) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status =
              'AI Sinhala • extracting the complete English subtitle before playback…';
        });
      }

      unawaited(
        AiSinhalaTraceService.write(
          'complete-preflight-start mode=debrid-11470 '
          'provider=${source?.provider ?? 'unknown'} '
          'playbackHost=${AiSinhalaTraceService.safeHost(playbackUrl)}',
        ),
      );

      Future<AiGeneratedSubtitleFile?> prepareFromExactP2pOracle() async {
        if (source == null ||
            !source.isMagnet ||
            (source.torrentFileIndex == null &&
                source.fileNameHint?.trim().isNotEmpty != true)) {
          return null;
        }

        String? oracleUrl;
        try {
          if (mounted) {
            setState(() {
              _status =
                  'AI Sinhala • debrid subtitle was not readable. Checking the exact same torrent through the Free P2P subtitle engine…';
            });
          }
          unawaited(
            AiSinhalaTraceService.write(
              'complete-preflight-p2p-oracle-start '
              'fileIdx=${source.torrentFileIndex ?? -1}',
            ),
          );

          // Use the same Windows warm-up as real Free P2P playback. The old
          // subtitle-oracle experiment used warmForPlayback=false and could ask
          // for embedded tracks before the torrent engine had enough metadata.
          oracleUrl = await LocalTorrentService.instance.resolve(
            source,
            warmForPlayback: true,
            onProgress: (message) {
              if (!mounted) return;
              setState(() {
                _status = 'AI Sinhala • Free P2P subtitle check • $message';
              });
            },
          );

          final generated = await AiSinhalaSubtitleService
              .prepareGeneratedSinhalaFromEmbeddedSubtitle(
            title: title,
            videoUrl: oracleUrl,
            videoFileNameHint: source.fileNameHint ?? releaseHint,
            onStatus: (message) {
              if (!mounted) return;
              setState(() => _status = 'AI Sinhala • $message');
            },
          );
          unawaited(
            AiSinhalaTraceService.write(
              'complete-preflight-p2p-oracle-match '
              'provider=${source.provider}',
            ),
          );
          return generated;
        } catch (error) {
          unawaited(
            AiSinhalaTraceService.write(
              'complete-preflight-p2p-oracle-miss '
              'type=${error.runtimeType}',
            ),
          );
          return null;
        } finally {
          // The torrent is subtitle-only in debrid mode. Playback itself stays
          // on the already prepared cloud/CDN URL.
          try {
            await LocalTorrentService.instance.releaseCurrentStream();
          } catch (_) {}
        }
      }

      try {
        preparedAiSubtitleFile = await AiSinhalaSubtitleService
            .prepareGeneratedSinhalaFromEmbeddedSubtitle(
          title: title,
          videoUrl: playbackUrl,
          videoFileNameHint: source?.fileNameHint ?? releaseHint,
          onStatus: (message) {
            if (!mounted) return;
            setState(() => _status = 'AI Sinhala • $message');
          },
        );

        unawaited(
          AiSinhalaTraceService.write(
            'complete-preflight-match mode=debrid-11470 '
            'source=${preparedAiSubtitleFile?.source ?? 'unknown'}',
          ),
        );
      } on AiSubtitleException catch (error) {
        unawaited(
          AiSinhalaTraceService.write(
            'complete-preflight-remote-miss type=AiSubtitleException '
            'detail=${error.message.replaceAll(RegExp(r'\\s+'), ' ').trim()}',
          ),
        );

        // Exact sibling .srt/.ass files inside the same TorBox torrent are
        // trustworthy and tiny, so keep this same-release path before waking
        // the P2P oracle.
        if (torBoxItem != null && torBoxVideoFile != null) {
          try {
            preparedAiSubtitleFile = await _tryTorBoxSiblingSubtitle(
              cloudItem: torBoxItem,
              videoFile: torBoxVideoFile,
              title: title,
              episode: episode,
            );
          } catch (siblingError) {
            unawaited(
              AiSinhalaTraceService.write(
                'complete-preflight-torbox-sibling-miss '
                'type=${siblingError.runtimeType}',
              ),
            );
          }
        }

        preparedAiSubtitleFile ??= await prepareFromExactP2pOracle();

        if (preparedAiSubtitleFile == null) {
          aiPreflightFailure =
              'No readable English text subtitle could be extracted from this exact release. '
              'Orvix will not use the inaccurate live/audio Sinhala fallback.';
        }
      } catch (error) {
        unawaited(
          AiSinhalaTraceService.write(
            'complete-preflight-error type=${error.runtimeType}',
          ),
        );
        preparedAiSubtitleFile = await prepareFromExactP2pOracle();
        if (preparedAiSubtitleFile == null) {
          aiPreflightFailure =
              'AI Sinhala could not prepare a complete subtitle for this exact release. '
              'Orvix will play the native subtitles instead of guessing live Sinhala.';
        }
      }

      if (preparedAiSubtitleFile != null && mounted) {
        setState(() {
          _status =
              'AI Sinhala • complete Sinhala subtitle ready. Opening player…';
        });
      }
    }

    // Dormant compatibility path for the retired standalone 11471 preflight.
    // Active beta.38 Windows playback does not enter this branch.
    if (legacyWindowsAiPreflight) {
      aiPreflightAttempted = true;
      if (mounted) {
        setState(() {
          _resolving = true;
          _resolveProgress = null;
          _status =
              'AI Sinhala • starting the Orvix media engine before playback…';
        });
      }

      try {
        unawaited(
          AiSinhalaTraceService.write(
            'preflight-start provider=${source?.provider ?? 'unknown'} '
            'host=${AiSinhalaTraceService.safeHost(url)}',
          ),
        );
        final preparation = await OrvixMediaEngineService.instance.prepare(
          url,
          onStatus: (message) {
            if (!mounted) return;
            setState(() => _status = 'AI Sinhala • $message');
          },
        );

        final enginePlaybackUrl = preparation.playbackUrl;
        unawaited(
          AiSinhalaTraceService.write(
            'preflight-result embedded=${preparation.hasEmbeddedText} '
            'fingerprint=${preparation.hasExactFingerprint} '
            'playbackSession=${enginePlaybackUrl != null && enginePlaybackUrl.isNotEmpty}',
          ),
        );
        if (enginePlaybackUrl == null || enginePlaybackUrl.isEmpty) {
          throw const AiSubtitleException(
            'The Orvix media engine did not create a local playback session.',
          );
        }

        if (preparation.hasEmbeddedText) {
          final identity =
              'orvix-media-engine://${preparation.movieHash ?? 'unknown'}/${preparation.embeddedStreamIndex ?? -1}';
          preparedAiSubtitleFile = await AiSinhalaSubtitleService
              .prepareGeneratedSinhalaFromEngineEmbedded(
            title: title,
            embeddedSrt: preparation.embeddedSrt!,
            embeddedIdentity: identity,
            embeddedLabel:
                preparation.embeddedLabel ?? 'English embedded',
            onStatus: (message) {
              if (!mounted) return;
              setState(() => _status = 'AI Sinhala • $message');
            },
          );
        } else {
          final sourceHash = expectedVideoHash?.trim().toLowerCase();
          final sourceHashValid = sourceHash != null &&
              RegExp(r'^[0-9a-f]{16}$').hasMatch(sourceHash) &&
              expectedSizeBytes != null &&
              expectedSizeBytes > 0;

          final engineHash = preparation.movieHash?.trim().toLowerCase();
          final engineHashValid = engineHash != null &&
              RegExp(r'^[0-9a-f]{16}$').hasMatch(engineHash) &&
              preparation.movieByteSize != null &&
              preparation.movieByteSize! > 0;

          final sameTuple = sourceHashValid &&
              engineHashValid &&
              sourceHash == engineHash &&
              expectedSizeBytes == preparation.movieByteSize;

          unawaited(
            AiSinhalaTraceService.write(
              'fingerprints source=$sourceHashValid engine=$engineHashValid '
              'sameTuple=$sameTuple',
            ),
          );

          // TorBox already owns the full torrent file tree. Before searching
          // another subtitle service or waking the P2P engine, inspect sibling
          // .srt/.ass/.ssa/.vtt files from this exact cloud torrent.
          if (torBoxItem != null && torBoxVideoFile != null) {
            if (mounted) {
              setState(() {
                _status =
                    'AI Sinhala • checking subtitles inside this exact TorBox torrent…';
              });
            }
            preparedAiSubtitleFile = await _tryTorBoxSiblingSubtitle(
              cloudItem: torBoxItem,
              videoFile: torBoxVideoFile,
              title: title,
              episode: episode,
            );
          }

          Future<AiGeneratedSubtitleFile?> tryExact({
            required String hash,
            required int size,
            required String label,
          }) async {
            try {
              if (mounted) {
                setState(() {
                  _status =
                      'AI Sinhala • checking the $label exact-file fingerprint…';
                });
              }
              final generated = await AiSinhalaSubtitleService
                  .prepareGeneratedSinhalaFromExactFingerprint(
                title: title,
                movieHash: hash,
                movieByteSize: size,
                onStatus: (message) {
                  if (!mounted) return;
                  setState(() => _status = 'AI Sinhala • $message');
                },
              );
              unawaited(
                AiSinhalaTraceService.write('exact-match label=$label'),
              );
              return generated;
            } on AiSubtitleException catch (error) {
              if (!error.message
                  .toLowerCase()
                  .contains('returned no exact-file subtitle')) {
                rethrow;
              }
              unawaited(
                AiSinhalaTraceService.write('exact-miss label=$label'),
              );
              return null;
            }
          }

          if (preparedAiSubtitleFile == null && sourceHashValid) {
            preparedAiSubtitleFile = await tryExact(
              hash: sourceHash!,
              size: expectedSizeBytes!,
              label: 'source',
            );
          }

          if (preparedAiSubtitleFile == null &&
              engineHashValid &&
              !sameTuple) {
            preparedAiSubtitleFile = await tryExact(
              hash: engineHash!,
              size: preparation.movieByteSize!,
              label: 'engine',
            );
          }

          if (preparedAiSubtitleFile == null) {
            if (mounted) {
              setState(() {
                _status =
                    'AI Sinhala • checking the official hash-scoped subtitle addons…';
              });
            }

            final tuples = <({String hash, int size, String label})>[];
            if (sourceHashValid) {
              tuples.add((
                hash: sourceHash!,
                size: expectedSizeBytes!,
                label: 'source',
              ));
            }
            if (engineHashValid && !sameTuple) {
              tuples.add((
                hash: engineHash!,
                size: preparation.movieByteSize!,
                label: 'engine',
              ));
            }

            for (final tuple in tuples) {
              final candidates = await OnlineSubtitleService.search(
                item: item,
                episode: episode,
                releaseHint: releaseHint,
                videoSize: tuple.size,
                videoHash: tuple.hash,
                preferredLanguage: 'eng',
                includeTranscriptFallbacks: false,
              );
              OnlineSubtitleResult? selectedCandidate;

              // The official legacy addon has a materially stronger route:
              // the OpenSubtitles file hash is the resource id itself. Prefer
              // that over v3 results even when v3 has a larger ranking bonus.
              for (final candidate in candidates) {
                if (candidate.language == 'eng' && candidate.exactHashPath) {
                  selectedCandidate = candidate;
                  break;
                }
              }

              // OpenSubtitles v3 receives videoHash/videoSize as optional extra
              // parameters but can still return generic IMDb/episode results.
              // Do not silently treat those as exact. Only auto-use v3 when
              // its result metadata also matches a release-specific token.
              if (selectedCandidate == null) {
                for (final candidate in candidates) {
                  if (candidate.language == 'eng' &&
                      candidate.hashScoped &&
                      candidate.strongReleaseMatchCount > 0) {
                    selectedCandidate = candidate;
                    break;
                  }
                }
              }

              if (selectedCandidate == null) {
                unawaited(
                  AiSinhalaTraceService.write(
                    'hash-addon-rejected label=${tuple.label} '
                    'reason=no-exact-or-release-specific-match',
                  ),
                );
                continue;
              }

              unawaited(
                AiSinhalaTraceService.write(
                  'hash-addon-match label=${tuple.label} '
                  'provider=${selectedCandidate.provider} '
                  'score=${selectedCandidate.score} '
                  'exactHashPath=${selectedCandidate.exactHashPath} '
                  'releaseMatches=${selectedCandidate.releaseMatchCount} '
                  'strongReleaseMatches=${selectedCandidate.strongReleaseMatchCount}',
                ),
              );
              preparedAiSubtitleFile = await AiSinhalaSubtitleService
                  .prepareGeneratedSinhalaFromOnlineSubtitle(
                title: title,
                subtitleUrl: selectedCandidate.url,
                subtitleIdentity:
                    'hash-addon|${tuple.label}|${selectedCandidate.provider}|${selectedCandidate.id}',
                subtitleLabel:
                    '${selectedCandidate.provider} • ${selectedCandidate.label}',
                onStatus: (message) {
                  if (!mounted) return;
                  setState(() => _status = 'AI Sinhala • $message');
                },
              );
              break;
            }
          }

          // Debrid/cloud playback can lose the exact subtitle path even when
          // the original Torrentio source is a magnet that the proven Free P2P
          // engine can inspect by exact info-hash + file index. Reuse that
          // torrent only as a short-lived subtitle oracle: extract/translate
          // the exact source subtitle locally, then keep video playback on the
          // fast debrid/CDN session returned by the standalone media engine.
          //
          // This deliberately runs after the remote embedded + exact-hash
          // paths. It never falls back to a different release or an unverified
          // OpenSubtitles timeline.
          if (preparedAiSubtitleFile == null &&
              source != null &&
              source.isMagnet &&
              !originalLocalP2p &&
              (source.torrentFileIndex != null ||
                  source.fileNameHint?.trim().isNotEmpty == true)) {
            try {
              unawaited(
                AiSinhalaTraceService.write(
                  'p2p-subtitle-oracle-start provider=${source.provider} '
                  'fileIdx=${source.torrentFileIndex ?? -1} '
                  'hasFileHint=${source.fileNameHint?.trim().isNotEmpty == true}',
                ),
              );
              if (mounted) {
                setState(() {
                  _status =
                      'AI Sinhala • exact debrid subtitle was unavailable. '
                      'Checking the same torrent through the Free P2P subtitle engine…';
                });
              }

              final subtitleOracleUrl =
                  await LocalTorrentService.instance.resolve(
                source,
                warmForPlayback: false,
                onProgress: (message) {
                  if (!mounted) return;
                  setState(() {
                    _status = 'AI Sinhala • subtitle check • $message';
                  });
                },
              );

              preparedAiSubtitleFile = await AiSinhalaSubtitleService
                  .prepareGeneratedSinhalaFromEmbeddedSubtitle(
                title: title,
                videoUrl: subtitleOracleUrl,
                videoFileNameHint: source.fileNameHint ?? releaseHint,
                onStatus: (message) {
                  if (!mounted) return;
                  setState(() => _status = 'AI Sinhala • $message');
                },
              );

              unawaited(
                AiSinhalaTraceService.write(
                  'p2p-subtitle-oracle-match provider=${source.provider}',
                ),
              );
            } on AiSubtitleException catch (error) {
              unawaited(
                AiSinhalaTraceService.write(
                  'p2p-subtitle-oracle-miss type=AiSubtitleException '
                  'detail=${error.message.replaceAll(RegExp(r'\\s+'), ' ').trim()}',
                ),
              );
            } catch (error) {
              unawaited(
                AiSinhalaTraceService.write(
                  'p2p-subtitle-oracle-miss type=${error.runtimeType}',
                ),
              );
            } finally {
              // The torrent was opened only to recover the exact subtitle. The
              // actual movie continues through TorBox/PikPak/debrid.
              try {
                await LocalTorrentService.instance.releaseCurrentStream();
              } catch (_) {}
            }
          }

          if (preparedAiSubtitleFile == null) {
            final detail = [
              preparation.probeError,
              preparation.hashError,
            ]
                .whereType<String>()
                .where((value) => value.trim().isNotEmpty)
                .join(' • ');
            throw AiSubtitleException(
              detail.isEmpty
                  ? 'No safe subtitle matched this exact file.'
                  : 'No safe subtitle matched this exact file. $detail',
            );
          }
        }

        playbackUrl = enginePlaybackUrl;

        if (mounted) {
          setState(() {
            _status =
                'AI Sinhala • complete subtitle ready. Opening player…';
          });
        }
      } catch (error) {
        unawaited(
          AiSinhalaTraceService.write(
            'preflight-failed type=${error.runtimeType}',
          ),
        );
        if (originalLocalP2p) {
          try {
            await LocalTorrentService.instance.releaseCurrentStream();
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _resolving = false;
            _resolveProgress = null;
            _status = '';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'AI Sinhala preparation failed before playback: ${error.toString()}',
              ),
              duration: const Duration(seconds: 9),
            ),
          );
        }
        // Fail closed: with Windows AI Sinhala enabled, normal playback is
        // never allowed to start without a complete prepared Sinhala SRT.
        return;
      }
    }

    if (PlaybackPreparation.current?.isCancelled != true && mounted) {
      setState(() {
        _resolving = false;
        _resolveProgress = null;
        _status = '';
      });
    }

    try {
      PlaybackPreparation.throwIfCurrentCancelled();
      final preference = await PlayerEnginePreferencesService.get();
      final aiEnabled =
          Platform.isAndroid && aiSettingEnabled;
      final engine = PlayerEngineRouter.choose(
        preference: preference,
        isAndroid: _androidPlayback,
        isAndroidTv: PlatformProfile.isAndroidTv,
        url: playbackUrl,
        releaseHint: releaseHint,
        aiSinhalaEnabled: aiEnabled && !useLocalMediaBridge,
      );

      final androidAutoFallbackToExo = Platform.isAndroid &&
          preference == PlayerEnginePreference.auto &&
          !aiSettingEnabled &&
          !useLocalMediaBridge &&
          source?.isMagnet != true;
      if (source != null) {
        FreeP2pPlaybackTrace.instance.active(source)?.stage(
          'player',
          engine == PlayerEngineKind.exoPlayer && _androidPlayback
              ? 'exoPlayer'
              : 'libmpv',
          detail: <String, Object?>{'preference': preference.name},
        );
      }

      if (engine == PlayerEngineKind.exoPlayer && _androidPlayback) {
        final result = await _openExoPlayer(
          playbackUrl,
          title,
          item,
          episode,
          source: source,
          autoFallbackToMpv: preference == PlayerEnginePreference.auto,
        );

        final shouldFallback = mounted &&
            (result?.switchToMpv == true ||
                (preference == PlayerEnginePreference.auto &&
                    result?.failed == true));
        if (!shouldFallback) {
          // ExoPlayer closed (normal exit, startup failure, or this screen
          // went away meanwhile) and MPV does not take over: detach the
          // local P2P torrent exactly like the MPV exit does, so it never
          // keeps downloading after the player is gone.
          if (originalLocalP2p) await _releaseLocalP2pAfterPlayer();
          return;
        }

        if (result?.failed == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ExoPlayer failed — trying MPV…'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }

      await _openMpvPlayer(
        playbackUrl,
        title,
        item,
        episode,
        next,
        source: source,
        aiSourceUrl: aiSourceUrl ?? playbackUrl,
        releaseHint: releaseHint,
        expectedSizeBytes: expectedSizeBytes,
        expectedVideoHash: expectedVideoHash,
        preparedAiSubtitleFile: preparedAiSubtitleFile,
        aiPreflightAttempted: useLocalMediaBridge ? false : aiPreflightAttempted,
        aiPreflightFailure: useLocalMediaBridge ? null : aiPreflightFailure,
        fallbackToExo: androidAutoFallbackToExo,
        releaseLocalP2pOnExit: originalLocalP2p,
      );
    } finally {
      if (bridgeHandle != null) {
        await LocalMediaBridgeService.instance.release(
          bridgeHandle.sessionId,
        );
      }
    }
  }

  Future<AndroidExoPlayerResult?> _openExoPlayer(
    String url,
    String title,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? source,
    bool autoFallbackToMpv = false,
  }) async {
    if (!mounted || !_androidPlayback) return null;
    // Never open a player for a preparation the user already backed out of.
    PlaybackPreparation.throwIfCurrentCancelled();
    final exoLauncher = debugExoLauncher;
    final result = exoLauncher != null
        ? await exoLauncher(url)
        : await Navigator.of(context).push<AndroidExoPlayerResult>(
            MaterialPageRoute(
              builder: (_) => AndroidExoPlayerScreen(
                url: url,
                title: title,
                mediaState: widget.mediaState,
                item: item,
                episode: episode,
                autoFallbackToMpv: autoFallbackToMpv,
              ),
            ),
          );
    if (!mounted) return result;

    if (source != null && result?.started == true) {
      unawaited(widget.sources.recordPlaybackOutcome(source, success: true));
      unawaited(_tracePlayerStarted(source, url));
    } else if (source != null && result?.failed == true) {
      unawaited(
        widget.sources.recordPlaybackOutcome(
          source,
          success: false,
          reason: result?.error,
        ),
      );
      // Auto falls back to MPV after an ExoPlayer failure.
      _tracePlayerFailed(source, result?.error, last: !autoFallbackToMpv);
    } else if (result?.switchToMpv != true) {
      _tracePlayerClosed(source);
    }
    return result;
  }

  Future<void> _recordSourceStartupFailure(
    SourceResult source,
    String url,
    String message, {
    bool fallbackFollows = false,
    bool sourceFallback = false,
  }) async {
    // Recorded before any await: the player may close right after this
    // callback, and the attempt must already read as a startup failure.
    final trace = _tracePlayerFailed(
      source,
      message,
      last: !fallbackFollows,
      sourceFallback: sourceFallback,
    );
    var reason = message.trim();
    if (source.isMagnet) {
      final health = await LocalTorrentService.instance.healthForStreamUrl(url);
      _traceEngineStats(trace, health);
      if (health != null) {
        reason = '$reason • ${health.summary}';
      }
    }
    await widget.sources.recordPlaybackOutcome(
      source,
      success: false,
      reason: reason,
    );
  }

  Future<void> _openMpvPlayer(
    String url,
    String title,
    MediaItem item,
    EpisodeItem? episode,
    EpisodeItem? next, {
    SourceResult? source,
    String? aiSourceUrl,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
    AiGeneratedSubtitleFile? preparedAiSubtitleFile,
    bool aiPreflightAttempted = false,
    String? aiPreflightFailure,
    bool fallbackToExo = false,
    bool releaseLocalP2pOnExit = false,
  }) async {
    if (!mounted) return;
    final uri = Uri.tryParse(url);
    final localP2p = uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port == 11470 &&
        uri.pathSegments.length >= 2 &&
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(uri.pathSegments.first) &&
        int.tryParse(uri.pathSegments[1]) != null;

    // A one-click Free P2P attempt with a verified next source lets MPV
    // leave by itself on a startup failure, so the next source starts
    // without the user. Never combined with the MPV-to-ExoPlayer fallback.
    final sourceFallback =
        _sourceFallbackArmed && !fallbackToExo && source != null;
    final VoidCallback? onPlaybackStarted = source == null
        ? null
        : () {
            unawaited(
              widget.sources.recordPlaybackOutcome(
                source,
                success: true,
              ),
            );
            unawaited(_tracePlayerStarted(source, url));
          };
    final ValueChanged<String>? onStartupFailed = source == null
        ? null
        : (message) {
            if (sourceFallback) _sourceFallbackRequested = true;
            unawaited(
              _recordSourceStartupFailure(
                source,
                url,
                message,
                fallbackFollows: fallbackToExo,
                sourceFallback: sourceFallback,
              ),
            );
          };
    final Future<void> Function(String message)? onStartupFallback =
        fallbackToExo
            ? (message) async {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('MPV could not start — trying ExoPlayer…'),
                    duration: Duration(seconds: 2),
                  ),
                );
                await _openExoPlayer(
                  url,
                  title,
                  item,
                  episode,
                  source: source,
                  autoFallbackToMpv: false,
                );
              }
            : sourceFallback
                ? (message) async {
                    // The player has left; the one-click run starts the
                    // next verified source once this route is gone.
                  }
                : null;

    // Never open a player for a preparation the user already backed out of.
    PlaybackPreparation.throwIfCurrentCancelled();
    final launcher = debugPlayerLauncher;
    if (launcher != null) {
      await launcher(DebugPlayerLaunch(
        url: url,
        source: source,
        onPlaybackStarted: onPlaybackStarted,
        onStartupFailed: onStartupFailed,
        onStartupFallback: onStartupFallback,
      ));
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            playback: widget.playback,
            url: url,
            aiSourceUrl: aiSourceUrl,
            title: title,
            mediaState: widget.mediaState,
            item: item,
            episode: episode,
            aiSubtitle: null,
            preparedAiSubtitleFile: preparedAiSubtitleFile,
            aiPreflightAttempted: aiPreflightAttempted,
            aiPreflightFailure: aiPreflightFailure,
            allowAiSinhala: true,
            releaseHint: releaseHint,
            expectedSizeBytes: expectedSizeBytes,
            expectedVideoHash: expectedVideoHash,
            nextEpisodeLabel:
                next == null ? null : '${next.label} ${next.title}',
            onPlaybackStarted: onPlaybackStarted,
            onStartupFailed: onStartupFailed,
            onStartupFallback: onStartupFallback,
            onNext: next == null
                ? null
                : () async {
                    if (!mounted) return;
                    await _play(item, episode: next);
                  },
          ),
        ),
      );
    }

    // With an ExoPlayer fallback the MPV route closes before ExoPlayer
    // answers; ExoPlayer records the outcome then.
    if (!fallbackToExo) _tracePlayerClosed(source);

    // Only detach after the MPV route and native video surface are fully gone.
    // Android TV may still need the same P2P URL for its Exo fallback, so that
    // handoff path deliberately keeps the torrent attached.
    if ((localP2p || releaseLocalP2pOnExit) && !fallbackToExo) {
      await _releaseLocalP2pAfterPlayer();
    }
  }

  /// Detaches the local P2P torrent once a player route and its native
  /// video surface are fully gone. Shared by the MPV and ExoPlayer exits.
  Future<void> _releaseLocalP2pAfterPlayer() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await LocalTorrentService.instance.releaseCurrentStream();
  }

  EpisodeItem? _nextEpisode(MediaItem item, EpisodeItem? current) {
    if (current == null || item.episodes.isEmpty) return null;
    final episodes = [...item.episodes]..sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.episode.compareTo(b.episode);
      });
    final index = episodes.indexWhere(
      (episode) =>
          episode.id == current.id ||
          (episode.season == current.season &&
              episode.episode == current.episode),
    );
    if (index < 0 || index + 1 >= episodes.length) return null;
    return episodes[index + 1];
  }

  String? _extractYear(String value) {
    return RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(value)?.group(0);
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  void _showPlayError(Object error) {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });
    // A failed Free P2P attempt can be copied for a bug report. Cloud/debrid
    // playback is not traced, so it never offers this.
    final traced = FreeP2pPlaybackTrace.instance.attempts.firstOrNull;
    final offerReport = traced != null &&
        traced.outcome != FreeP2pPlaybackOutcome.playing &&
        traced.outcome != FreeP2pPlaybackOutcome.cancelled &&
        (traced.sinceEnd ?? Duration.zero) < const Duration(seconds: 30);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not play: $error'),
        action: offerReport
            ? SnackBarAction(
                label: 'Copy report',
                onPressed: () => unawaited(
                  Clipboard.setData(
                    ClipboardData(
                      text: FreeP2pPlaybackTrace.instance.report(),
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class _CastRail extends StatelessWidget {
  const _CastRail({
    required this.members,
    required this.tv,
  });

  final List<CastMember> members;
  final bool tv;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cast',
          style: TextStyle(
            fontSize: tv ? 19 : 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: tv ? 164 : 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: members.length,
            separatorBuilder: (_, __) => SizedBox(width: tv ? 16 : 12),
            itemBuilder: (context, index) {
              final member = members[index];
              return SizedBox(
                width: tv ? 92 : 82,
                child: Column(
                  children: [
                    ClipOval(
                      child: SizedBox(
                        width: tv ? 82 : 72,
                        height: tv ? 82 : 72,
                        child: member.photo?.trim().isNotEmpty == true
                            ? CachedNetworkImage(
                                imageUrl: member.photo!,
                                fit: BoxFit.cover,
                                memCacheWidth: 220,
                                fadeInDuration: Duration.zero,
                                placeholder: (_, __) => const ColoredBox(
                                  color: Color(0xFF171C18),
                                ),
                                errorWidget: (_, __, ___) => const ColoredBox(
                                  color: Color(0xFF171C18),
                                  child: Icon(Icons.person_outline_rounded),
                                ),
                              )
                            : const ColoredBox(
                                color: Color(0xFF171C18),
                                child: Icon(Icons.person_outline_rounded),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: tv ? 12.5 : 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (member.character?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 2),
                      Text(
                        member.character!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF8E9990),
                          fontSize: 10,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MobileSeasonTile extends StatefulWidget {
  const _MobileSeasonTile({
    required this.season,
    required this.selected,
    required this.onTap,
  });

  final int season;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MobileSeasonTile> createState() => _MobileSeasonTileState();
}

class _MobileSeasonTileState extends State<_MobileSeasonTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    const selectedLime = Color(0xFF9FE52E);
    final active = widget.selected;
    final highlighted = _hovered || _focused;
    final label = widget.season == 0 ? 'Specials' : 'Season ${widget.season}';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: highlighted ? 1.025 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            onFocusChange: (value) => setState(() => _focused = value),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 38,
              constraints: const BoxConstraints(minWidth: 92),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? selectedLime
                    : highlighted
                        ? const Color(0xFF1B211A)
                        : const Color(0xFF101411),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active
                      ? lime
                      : highlighted
                          ? lime.withValues(alpha: .72)
                          : Colors.white.withValues(alpha: .10),
                  width: active || highlighted ? 1.6 : 1,
                ),
              ),
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: active ? Colors.black : Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopEpisodeCard extends StatefulWidget {
  const _DesktopEpisodeCard({
    required this.episode,
    required this.onTap,
  });

  final EpisodeItem episode;
  final VoidCallback? onTap;

  @override
  State<_DesktopEpisodeCard> createState() => _DesktopEpisodeCardState();
}

class _DesktopEpisodeCardState extends State<_DesktopEpisodeCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final active = _hovered || _focused;
    final episode = widget.episode;
    final cleanOverview = episode.overview?.replaceFirst(
      RegExp(r'^★\s*\d+(?:\.\d+)?\s*'),
      '',
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.025 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: 322,
          child: Material(
            color: const Color(0xFF0C100E),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onFocusChange: (value) => setState(() => _focused = value),
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: active
                        ? lime.withValues(alpha: .72)
                        : Colors.white.withValues(alpha: .10),
                    width: active ? 1.6 : 1,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .38),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : const [],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (episode.thumbnail?.trim().isNotEmpty == true)
                      CachedNetworkImage(
                        imageUrl: episode.thumbnail!,
                        fit: BoxFit.cover,
                        memCacheWidth: 720,
                        fadeInDuration: Duration.zero,
                        placeholder: (_, __) =>
                            const ColoredBox(color: Color(0xFF151916)),
                        errorWidget: (_, __, ___) =>
                            const ColoredBox(color: Color(0xFF151916)),
                      )
                    else
                      const ColoredBox(color: Color(0xFF151916)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x08000000),
                            Color(0x24000000),
                            Color(0xA6000000),
                            Color(0xF6090B0A),
                          ],
                          stops: [0, .35, .68, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 11,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3090B0A),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .12),
                          ),
                        ),
                        child: Text(
                          episode.label,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 11,
                      top: 11,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active
                              ? lime
                              : const Color(0xB3090B0A),
                          border: Border.all(
                            color: active
                                ? lime
                                : Colors.white.withValues(alpha: .14),
                          ),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: active ? Colors.black : Colors.white,
                          size: 23,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            episode.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          if (cleanOverview?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: 4),
                            Text(
                              cleanOverview!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFC4CBC6),
                                fontSize: 11.2,
                              ),
                            ),
                          ],
                          if (episode.rating != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              '★ ${episode.rating!.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Color(0xFFD8DED9),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ],
                      ),
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

class _MetaPill extends StatelessWidget {
  const _MetaPill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: .14)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}
