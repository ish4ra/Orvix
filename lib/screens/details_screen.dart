import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/ai_sinhala_preferences_service.dart';
import '../services/catalog_service.dart';
import '../services/cloud_preferences_service.dart';
import '../services/local_torrent_service.dart';
import '../services/media_state_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/platform_profile.dart';
import '../services/player_engine_preferences_service.dart';
import '../services/source_provider_service.dart';
import '../services/torbox_service.dart';
import 'android_exo_player_screen.dart';
import 'player_screen.dart';
import 'sources_screen.dart';
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
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050806),
      body: FutureBuilder<MediaItem>(
        future: _detailsFuture,
        builder: (context, snapshot) {
          final item = snapshot.data ?? widget.item;
          if (PlatformProfile.isAndroidTv) {
            return _tvDetailsLayout(item);
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
                    onPressed: () => Navigator.of(context).pop(),
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

  Widget _tvDetailsLayout(MediaItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF0A0C0B)),
        CustomScrollView(
          cacheExtent: 1100,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(42, 28, 42, 18),
                child: Column(
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 30,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -.65,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        _TvMetaText(item.typeLabel),
                        if (item.year != null) _TvMetaText(item.year!),
                        if (item.runtime != null) _TvMetaText(item.runtime!),
                        if (item.rating != null)
                          _TvMetaText('★ ${item.rating!.toStringAsFixed(1)}'),
                        ...item.genres.take(3).map(_TvMetaText.new),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (item.background?.trim().isNotEmpty == true)
                          SizedBox(
                            width: 300,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: CachedNetworkImage(
                                      imageUrl: item.background!,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 720,
                                      fadeInDuration: Duration.zero,
                                      placeholder: (_, __) =>
                                          const ColoredBox(
                                            color: Color(0xFF151816),
                                          ),
                                      errorWidget: (_, __, ___) =>
                                          const ColoredBox(
                                            color: Color(0xFF151816),
                                          ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Overview',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (item.background?.trim().isNotEmpty == true)
                          const SizedBox(width: 26),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (item.description?.trim().isNotEmpty == true)
                                Text(
                                  item.description!,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFD2D7D3),
                                    fontSize: 14,
                                    height: 1.5,
                                  ),
                                ),
                              const SizedBox(height: 18),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  if (item.kind == MediaKind.movie)
                                    FilledButton.icon(
                                      onPressed: _resolving
                                          ? null
                                          : () => _findSourcesAndPlay(item),
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: const Text('Choose source'),
                                    ),
                                  FilledButton.tonalIcon(
                                    onPressed: () => _toggleLibrary(item),
                                    icon: Icon(
                                      _inLibrary
                                          ? Icons.video_library_rounded
                                          : Icons.library_add_outlined,
                                    ),
                                    label: Text(
                                      _inLibrary ? 'In Library' : 'Library',
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
                                      _watchlisted
                                          ? 'Watchlisted'
                                          : 'Watchlist',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
              SliverToBoxAdapter(child: _tvEpisodeRail(item)),
            SliverToBoxAdapter(child: _tvFactsSection(item)),
            const SliverToBoxAdapter(child: SizedBox(height: 64)),
          ],
        ),
        Positioned(
          top: 18,
          left: 18,
          child: SafeArea(
            child: IconButton.filledTonal(
              autofocus: true,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).pop(),
              style: ButtonStyle(
                backgroundColor:
                    const WidgetStatePropertyAll(Color(0xFF181C19)),
                side: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? const BorderSide(color: Colors.white, width: 2)
                      : const BorderSide(color: Color(0xFF323833)),
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

  Widget _tvEpisodeRail(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    if (seasons.isEmpty) return const SizedBox.shrink();
    final selected = _selectedSeason ?? seasons.first;
    final episodes = item.episodes.where((e) => e.season == selected).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));

    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 42),
            child: Text(
              'Seasons',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: -.25,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 86,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 3),
              scrollDirection: Axis.horizontal,
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return _TvSeasonTile(
                  season: season,
                  poster: item.seasonPoster(season),
                  selected: season == selected,
                  onTap: () => setState(() => _selectedSeason = season),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 42),
            child: Text(
              'Season $selected',
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                letterSpacing: -.2,
              ),
            ),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 238,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 5),
              scrollDirection: Axis.horizontal,
              cacheExtent: 1400,
              itemCount: episodes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 15),
              itemBuilder: (context, index) {
                final episode = episodes[index];
                return RepaintBoundary(
                  child: _TvEpisodeCard(
                    episode: episode,
                    onPlay: _resolving
                        ? null
                        : () => _findSourcesAndPlay(
                              item,
                              episode: episode,
                            ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tvFactsSection(MediaItem item) {
    final hasCredits = item.directors.isNotEmpty || item.cast.isNotEmpty;
    final hasFacts = item.country?.trim().isNotEmpty == true ||
        item.certification?.trim().isNotEmpty == true;
    if (!hasCredits && !hasFacts) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(42, 26, 42, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Show Details',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          if (item.directors.isNotEmpty)
            Text(
              'Director${item.directors.length > 1 ? 's' : ''}: '
              '${item.directors.join(', ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFB7C1B9),
                height: 1.45,
              ),
            ),
          if (hasFacts) ...[
            const SizedBox(height: 5),
            Text(
              [
                if (item.country?.trim().isNotEmpty == true)
                  item.country!.trim(),
                if (item.certification?.trim().isNotEmpty == true)
                  'Rated ${item.certification!.trim()}',
              ].join('  •  '),
              style: const TextStyle(
                color: Color(0xFF8F9A91),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (item.castMembers.isNotEmpty) ...[
            const SizedBox(height: 22),
            _CastRail(
              members: item.castMembers.take(14).toList(growable: false),
              tv: true,
            ),
          ] else if (item.cast.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Cast: ${item.cast.take(12).join(', ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFAAB4AC),
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hero(MediaItem item) {
    final tv = PlatformProfile.isAndroidTv;
    return SizedBox(
      height: tv ? 400 : 560,
      child: Stack(
        fit: StackFit.expand,
        children: [
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
          Padding(
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
          ),
        ],
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
          SizedBox(
            height: compact ? 72 : 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return _MobileSeasonTile(
                  season: season,
                  poster: item.seasonPoster(season),
                  selected: season == selected,
                  onTap: () => setState(() => _selectedSeason = season),
                );
              },
            ),
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
          ...episodes.map((episode) => _episodeTile(item, episode)),
        ],
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

      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveProgress = null;
      });
      await _findSourcesAndPlay(
        item,
        episode: episode,
        // Android TV stays manual while the playback path is being stabilized.
        // This also prevents legacy series-wide pins from silently choosing a
        // source the user did not select.
        autoUsePinned: !PlatformProfile.isAndroidTv,
      );
    } catch (e) {
      _showPlayError(e);
    }
  }

  Future<void> _findSourcesAndPlay(
    MediaItem item, {
    EpisodeItem? episode,
    bool autoUsePinned = false,
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
              onPlaySource: (chosen) async {
                final hasCloudConnection =
                    (await widget.pikpak.isSignedIn) ||
                    (await widget.torbox.isConnected);
                await _playSourceResult(
                  chosen,
                  item,
                  episode,
                  hasCloudConnection: hasCloudConnection,
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
      );
      if (!mounted) return;
      setState(() => _resolving = false);

      if (results.isEmpty) {
        await _showNoSourcesDialog(item, episode: episode);
        return;
      }

      final pikpakConnected = await widget.pikpak.isSignedIn;
      final torboxConnected = await widget.torbox.isConnected;
      final hasCloudConnection = pikpakConnected || torboxConnected;

      SourceResult? chosen;
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
              chosen = result;
              break;
            }
          }
        }
      }
      // With no debrid/cloud connection, Normal Play behaves like a
      // Stremio-style free path: rank direct and torrent/P2P results together
      // and pick the healthiest source automatically. Find Sources remains
      // fully manual.
      if (autoUsePinned && !hasCloudConnection && chosen == null) {
        final freeResults = widget.sources.sortForFreeStreaming(results);
        if (chosen == null && freeResults.isNotEmpty) {
          chosen = freeResults.first;
        }
      }

      chosen ??= await _chooseSource(results, item, episode);
      if (chosen == null || !mounted) return;
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

  String _sourceReleaseHint(SourceResult source) {
    final fileName = source.fileNameHint?.trim();
    if (fileName != null && fileName.isNotEmpty) return fileName;
    return source.title.split('\n').last.trim();
  }

  Future<void> _playSourceResult(
    SourceResult chosen,
    MediaItem item,
    EpisodeItem? episode, {
    bool? hasCloudConnection,
  }) async {
    final cloudConnected = hasCloudConnection ??
        ((await widget.pikpak.isSignedIn) || (await widget.torbox.isConnected));
    final releaseHint = _sourceReleaseHint(chosen);

    if (!chosen.isMagnet) {
      if (!mounted) return;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Opening direct stream…';
      });
      await _openPlayerUrl(
        chosen.resource,
        item,
        episode,
        source: chosen,
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
        expectedVideoHash: chosen.videoHash,
      );
      return;
    }

    if (!cloudConnected) {
      if (!mounted) return;
      setState(() {
        _resolving = true;
        _resolveProgress = null;
        _status = 'Starting local P2P torrent stream…';
      });
      late final String localUrl;
      try {
        localUrl = await LocalTorrentService.instance.resolve(
          chosen,
          onProgress: (message) {
            if (mounted) setState(() => _status = message);
          },
        );
      } catch (error) {
        unawaited(
          widget.sources.recordPlaybackOutcome(
            chosen,
            success: false,
            reason: error.toString(),
          ),
        );
        rethrow;
      }
      if (!mounted) return;
      setState(() => _status = 'P2P stream ready — opening player…');
      await _openPlayerUrl(
        localUrl,
        item,
        episode,
        source: chosen,
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
        expectedVideoHash: chosen.videoHash,
      );
      return;
    }

    final cloud = await _chooseCloudProvider();
    if (cloud == null || !mounted) return;
    if (cloud == CloudProvider.torbox) {
      await _sendSourceToTorBox(chosen, item, episode);
    } else {
      await _sendSourceToPikPak(chosen, item, episode);
    }
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
    if (!mounted) return;

    final openSources = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          configured.isEmpty
              ? 'No source providers configured'
              : 'No sources found',
        ),
        content: Text(
          configured.isEmpty
              ? 'Configure a Stremio-compatible source provider. Direct HTTP streams play immediately, and torrent/magnet sources can use Orvix built-in local P2P engine on Windows, Android, Android TV and macOS. PikPak/TorBox are optional cloud paths.'
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
                _findSourcesAndPlay(item, episode: episode);
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
    final pikpak = await widget.pikpak.isSignedIn;
    final torbox = await widget.torbox.isConnected;
    if (!pikpak && !torbox) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This torrent source needs PikPak or TorBox. Direct / Free sources play without a debrid account.',
            ),
          ),
        );
      }
      return null;
    }
    if (pikpak && !torbox) return CloudProvider.pikpak;
    if (torbox && !pikpak) return CloudProvider.torbox;
    if (!mounted) return preferred;
    final chosen = await showDialog<CloudProvider>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send source to'),
        content: const Text(
          'Both cloud services are connected. Choose where Orvix should prepare this source.',
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, CloudProvider.pikpak),
            icon: const Icon(Icons.cloud_outlined),
            label: const Text('PikPak'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, CloudProvider.torbox),
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('TorBox'),
          ),
        ],
      ),
    );
    if (chosen != null) await widget.cloudPreferences.setPreferred(chosen);
    return chosen;
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
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
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
        releaseHint: file.name,
        expectedSizeBytes: file.size,
        expectedVideoHash: chosen.videoHash,
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
      );
      return;
    }

    if (added.fileId != null &&
        await _tryOpenFileId(added.fileId!, item, episode)) {
      return;
    }

    await _waitForLibraryMatch(item, episode: episode);
  }

  Future<void> _waitForTask(
    String taskId, {
    required MediaItem item,
    EpisodeItem? episode,
    String? initialFileId,
  }) async {
    var fileId = initialFileId;
    for (var attempt = 0; attempt < 45; attempt++) {
      if (!mounted) return;
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }

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
        if (fileId != null && await _tryOpenFileId(fileId, item, episode)) {
          return;
        }
        for (var scan = 0; scan < 5; scan++) {
          final match = await _findInPikPak(item, episode: episode);
          if (match != null) {
            await _openPikPakFile(match, item, episode);
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
  }) async {
    for (var attempt = 1; attempt <= 18; attempt++) {
      if (!mounted) return;
      setState(() {
        _resolveProgress = (.05 + attempt / 20).clamp(0, .94).toDouble();
        _status = 'Waiting for the new PikPak file… ${attempt * 5}s';
      });
      await Future<void>.delayed(const Duration(seconds: 5));
      final match = await _findInPikPak(item, episode: episode);
      if (match != null) {
        await _openPikPakFile(match, item, episode);
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
    EpisodeItem? episode,
  ) async {
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
            ),
          ),
        ),
      );
    }
    var priority = await widget.sources.getPriorityOrder();
    var resultLimit = await widget.sources.getResultLimit();
    var compatibilityOnly = false;
    var smoothRanking = false;
    var freeStreamingRanking = false;
    final pinKey = widget.sources.sourceTargetKey(item, episode: episode);
    final seriesWidePin = item.kind == MediaKind.series;
    var pinnedIdentity = await widget.sources.getPinnedSourceIdentity(pinKey);
    if (!mounted) return null;

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
                child: const Text('Reset best'),
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
        setSheetState(() => priority = saved);
      }
    }

    return showModalBottomSheet<SourceResult>(
      context: context,
      backgroundColor: const Color(0xFF0D120E),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 960),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final compactSheet = MediaQuery.sizeOf(context).width < 680;
          final ranked = freeStreamingRanking
              ? widget.sources.sortForFreeStreaming(results)
              : smoothRanking
                  ? widget.sources.sortForSmoothPlayback(results)
                  : widget.sources.sortResults(results, priority);
          final filtered = compatibilityOnly
              ? ranked
                  .where((result) => result.compatibilityFriendly)
                  .toList(growable: false)
              : [...ranked];
          final compatibilityHiddenCount = ranked.length - filtered.length;

          final ordered = [...filtered];
          if (pinnedIdentity != null) {
            final pinnedIndex = ordered.indexWhere(
              (result) => widget.sources.matchesPinned(
                result,
                pinnedIdentity,
                seriesWide: seriesWidePin,
              ),
            );
            if (pinnedIndex > 0) {
              final pinned = ordered.removeAt(pinnedIndex);
              ordered.insert(0, pinned);
            }
          }

          final totalAfterFilter = ordered.length;
          final sorted = resultLimit > 0 && ordered.length > resultLimit
              ? ordered.take(resultLimit).toList(growable: false)
              : ordered;
          final limitHiddenCount = totalAfterFilter - sorted.length;
          final best = sorted.isEmpty ? null : sorted.first;
          final bestIsPinned = best != null &&
              widget.sources.matchesPinned(best, pinnedIdentity);
          final color = Theme.of(context).colorScheme;
          final priorityText =
              priority.map((e) => e.label.toLowerCase()).join(' → ');
          final rankingText = freeStreamingRanking
              ? 'Free P2P: availability → device compatibility → exact file → seed health → practical size'
              : smoothRanking
                  ? 'Smooth: compatibility → 1080/720 → efficient codec → seeders → smaller files → cache'
                  : 'Priority: $priorityText';
          final summaryParts = <String>[
            resultLimit > 0
                ? 'Showing ${sorted.length} of $totalAfterFilter results'
                : '${sorted.length} result${sorted.length == 1 ? '' : 's'} shown',
            if (freeStreamingRanking) 'free streaming ranking on',
            if (smoothRanking) 'smooth ranking on',
            if (compatibilityHiddenCount > 0)
              '$compatibilityHiddenCount risky hidden',
            if (limitHiddenCount > 0) '$limitHiddenCount beyond limit',
          ];

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .84,
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
                    Text(
                      'Choose source',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
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
                        FilterChip(
                          selected: freeStreamingRanking,
                          avatar: const Icon(Icons.bolt_rounded, size: 18),
                          label: const Text('Free Streaming'),
                          tooltip:
                              'Prioritize healthy torrent swarms for non-debrid playback.',
                          onSelected: (value) => setSheetState(() {
                            freeStreamingRanking = value;
                            if (value) smoothRanking = false;
                          }),
                        ),
                        FilterChip(
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
                        FilterChip(
                          selected: smoothRanking,
                          avatar: Icon(
                            smoothRanking
                                ? Icons.speed_rounded
                                : Icons.speed_outlined,
                            size: 18,
                          ),
                          label: const Text('Smooth'),
                          tooltip:
                              'Prioritize compatible, efficient and healthy sources.',
                          onSelected: (value) => setSheetState(() {
                            smoothRanking = value;
                            if (value) freeStreamingRanking = false;
                          }),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort'),
                        ),
                        if (best != null)
                          FilledButton.icon(
                            onPressed: () => Navigator.pop(sheetContext, best),
                            icon: const Icon(Icons.bolt_rounded),
                            label: Text(
                              bestIsPinned
                                  ? 'Play pinned'
                                  : 'Quick Play ${best.quality ?? ''}'.trim(),
                            ),
                          ),
                      ],
                    ),
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
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: sorted.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final result = sorted[index];
                          final isPinned = widget.sources.matchesPinned(
                            result,
                            pinnedIdentity,
                            seriesWide: seriesWidePin,
                          );
                          final statusLabel = isPinned
                              ? 'Pinned'
                              : index == 0
                                  ? freeStreamingRanking
                                      ? 'Free Stream'
                                      : smoothRanking
                                          ? 'Smooth'
                                          : 'Best'
                                  : null;
                          final providerText =
                              '${result.provider}${result.isMagnet ? ' • torrent / P2P' : ' • direct URL'}${result.compatibilityFriendly ? '' : ' • ⚠ compatibility risk'}';

                          if (compactSheet) {
                            return InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => Navigator.pop(sheetContext, result),
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

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 7,
                            ),
                            leading: CircleAvatar(
                              radius: 25,
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
                              child: Text(providerText),
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
                                      await widget.sources.unpinSource(pinKey);
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
                            onTap: () => Navigator.pop(sheetContext, result),
                          );
                        },
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
    final file = widget.torbox.choosePlayableFile(cloudItem);
    if (file == null)
      throw const TorBoxException('No playable video file found in TorBox.');
    final url = await widget.torbox.requestDownloadUrl(cloudItem, file);
    await _openPlayerUrl(
      url,
      item,
      episode,
      releaseHint: file.name,
      expectedSizeBytes: file.size,
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
    EpisodeItem? episode,
  ) async {
    try {
      final url = await widget.transfer.fetchPlayableUrl(fileId);
      if (url == null || url.isEmpty) return false;
      await _openPlayerUrl(url, item, episode);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openPikPakFile(
    PikPakFile file,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
    if (!mounted) return;
    setState(() => _status = 'Resolving PikPak streaming URL…');
    final url =
        await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
    if (url == null || url.isEmpty) {
      throw Exception('PikPak did not return a playable URL yet.');
    }
    await _openPlayerUrl(
      url,
      item,
      episode,
      releaseHint: file.name,
    );
  }

  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode, {
    SourceResult? source,
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
  }) async {
    if (!mounted) return;

    setState(() {
      _resolving = false;
      _resolveProgress = null;
      _status = '';
    });

    final title = episode == null
        ? item.title
        : '${item.title} • ${episode.label} ${episode.title}';
    final next = _nextEpisode(item, episode);

    final preference = await PlayerEnginePreferencesService.get();
    final aiEnabled = Platform.isAndroid &&
        !PlatformProfile.isAndroidTv &&
        await AiSinhalaPreferencesService.isEnabled();
    final engine = PlayerEngineRouter.choose(
      preference: preference,
      isAndroid: Platform.isAndroid,
      url: url,
      releaseHint: releaseHint,
      aiSinhalaEnabled: aiEnabled,
    );

    if (engine == PlayerEngineKind.exoPlayer && Platform.isAndroid) {
      final result = await Navigator.of(context).push<AndroidExoPlayerResult>(
        MaterialPageRoute(
          builder: (_) => AndroidExoPlayerScreen(
            url: url,
            title: title,
            mediaState: widget.mediaState,
            item: item,
            episode: episode,
            autoFallbackToMpv:
                preference == PlayerEnginePreference.auto,
          ),
        ),
      );
      if (!mounted) return;

      if (source != null && result?.started == true) {
        unawaited(
          widget.sources.recordPlaybackOutcome(source, success: true),
        );
      } else if (source != null && result?.failed == true) {
        unawaited(
          widget.sources.recordPlaybackOutcome(
            source,
            success: false,
            reason: result?.error,
          ),
        );
      }

      final shouldFallback = result?.switchToMpv == true ||
          (preference == PlayerEnginePreference.auto &&
              result?.failed == true);
      if (!shouldFallback) return;

      if (result?.failed == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ExoPlayer failed — trying MPV…'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }

    await _openMpvPlayer(
      url,
      title,
      item,
      episode,
      next,
      source: source,
      releaseHint: releaseHint,
      expectedSizeBytes: expectedSizeBytes,
      expectedVideoHash: expectedVideoHash,
    );
  }

  Future<void> _recordSourceStartupFailure(
    SourceResult source,
    String url,
    String message,
  ) async {
    var reason = message.trim();
    if (source.isMagnet) {
      final health = await LocalTorrentService.instance.healthForStreamUrl(url);
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
    String? releaseHint,
    int? expectedSizeBytes,
    String? expectedVideoHash,
  }) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          playback: widget.playback,
          url: url,
          title: title,
          mediaState: widget.mediaState,
          item: item,
          episode: episode,
          aiSubtitle: null,
          allowAiSinhala: !PlatformProfile.isAndroidTv,
          releaseHint: releaseHint,
          expectedSizeBytes: expectedSizeBytes,
          expectedVideoHash: expectedVideoHash,
          nextEpisodeLabel: next == null ? null : '${next.label} ${next.title}',
          onPlaybackStarted: source == null
              ? null
              : () {
                  unawaited(
                    widget.sources.recordPlaybackOutcome(
                      source,
                      success: true,
                    ),
                  );
                },
          onStartupFailed: source == null
              ? null
              : (message) {
                  unawaited(
                    _recordSourceStartupFailure(source, url, message),
                  );
                },
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Could not play: $error')));
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

class _TvSeasonTile extends StatefulWidget {
  const _TvSeasonTile({
    required this.season,
    required this.poster,
    required this.selected,
    required this.onTap,
  });

  final int season;
  final String? poster;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TvSeasonTile> createState() => _TvSeasonTileState();
}

class _TvSeasonTileState extends State<_TvSeasonTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.selected || _focused;
    return AnimatedScale(
      scale: _focused ? 1.035 : 1,
      duration: const Duration(milliseconds: 100),
      child: SizedBox(
        width: 150,
        child: Material(
          color: highlighted
              ? const Color(0xFF243221)
              : const Color(0xFF151916),
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            focusColor: Colors.transparent,
            onFocusChange: (value) => setState(() => _focused = value),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: _focused
                      ? Colors.white
                      : widget.selected
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0xFF343B35),
                  width: _focused ? 2.2 : 1.2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  if (widget.poster?.trim().isNotEmpty == true)
                    SizedBox(
                      width: 45,
                      height: double.infinity,
                      child: CachedNetworkImage(
                        imageUrl: widget.poster!,
                        fit: BoxFit.cover,
                        memCacheWidth: 140,
                        fadeInDuration: Duration.zero,
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Season ${widget.season}',
                        style: TextStyle(
                          fontWeight: widget.selected || _focused
                              ? FontWeight.w900
                              : FontWeight.w700,
                          fontSize: 13.5,
                        ),
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

class _MobileSeasonTile extends StatelessWidget {
  const _MobileSeasonTile({
    required this.season,
    required this.poster,
    required this.selected,
    required this.onTap,
  });

  final int season;
  final String? poster;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: .45)
          : const Color(0xFF111612),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          width: 138,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : const Color(0xFF2A332C),
              width: selected ? 1.8 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              if (poster?.trim().isNotEmpty == true)
                SizedBox(
                  width: 42,
                  height: double.infinity,
                  child: CachedNetworkImage(
                    imageUrl: poster!,
                    fit: BoxFit.cover,
                    memCacheWidth: 130,
                    fadeInDuration: Duration.zero,
                  ),
                ),
              Expanded(
                child: Center(
                  child: Text(
                    'Season $season',
                    style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.w900 : FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvMetaText extends StatelessWidget {
  const _TvMetaText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFFB6C0B8),
        fontSize: 12.5,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _TvEpisodeCard extends StatefulWidget {
  const _TvEpisodeCard({
    required this.episode,
    required this.onPlay,
  });

  final EpisodeItem episode;
  final VoidCallback? onPlay;

  @override
  State<_TvEpisodeCard> createState() => _TvEpisodeCardState();
}

class _TvEpisodeCardState extends State<_TvEpisodeCard> {
  bool _focused = false;

  String? _dateLabel(EpisodeItem episode) {
    final date = episode.releaseDate;
    if (date == null) return null;
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final primary = Theme.of(context).colorScheme.primary;
    final overview = episode.overview?.replaceFirst(
      RegExp(r'^★\s*\d+(?:\.\d+)?\s*'),
      '',
    );
    final date = _dateLabel(episode);

    return AnimatedScale(
      scale: _focused ? 1.025 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        width: 340,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _focused
                ? Colors.white.withValues(alpha: .95)
                : const Color(0xFF2A302C),
            width: _focused ? 2.5 : 1,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .44),
                    blurRadius: 24,
                    offset: const Offset(0, 9),
                  ),
                  BoxShadow(
                    color: primary.withValues(alpha: .12),
                    blurRadius: 18,
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Material(
            color: const Color(0xFF111412),
            child: InkWell(
              focusColor: Colors.transparent,
              onFocusChange: (value) => setState(() => _focused = value),
              onTap: widget.onPlay,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (episode.thumbnail != null &&
                      episode.thumbnail!.trim().isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: episode.thumbnail!,
                      fit: BoxFit.cover,
                      memCacheWidth: 720,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, __) =>
                          const ColoredBox(color: Color(0xFF171B18)),
                      errorWidget: (_, __, ___) =>
                          const ColoredBox(color: Color(0xFF171B18)),
                    )
                  else
                    const ColoredBox(color: Color(0xFF171B18)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00000000),
                          Color(0x22000000),
                          Color(0xE6070908),
                        ],
                        stops: [0, .44, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 15,
                    right: 15,
                    bottom: 13,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x99000000),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            'S${episode.season}E${episode.episode}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          episode.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (overview != null && overview.trim().isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            overview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE0E4E1),
                              fontSize: 12.2,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        if (date != null) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              date,
                              style: const TextStyle(
                                color: Color(0xFFB5BBB6),
                                fontSize: 10.8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: AnimatedOpacity(
                      opacity: _focused ? 1 : .72,
                      duration: const Duration(milliseconds: 100),
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        size: 32,
                        color: _focused
                            ? primary
                            : Colors.white.withValues(alpha: .84),
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
