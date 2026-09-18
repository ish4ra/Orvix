import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/cloud_preferences_service.dart';
import '../services/local_torrent_service.dart';
import '../services/media_state_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/source_provider_service.dart';
import '../services/torbox_service.dart';
import 'player_screen.dart';
import 'sources_screen.dart';

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
    _detailsFuture = _loadDetails();
  }

  Future<MediaItem> _loadDetails() async {
    final item = await widget.catalog.details(widget.item) ?? widget.item;
    if (item.episodes.isNotEmpty) {
      final seasons = item.episodes.map((e) => e.season).toList()..sort();
      _selectedSeason = seasons.first;
    }
    final watchlisted = await widget.mediaState.isWatchlisted(item);
    final inLibrary = await widget.mediaState.isInLibrary(item);
    if (mounted) {
      setState(() {
        _watchlisted = watchlisted;
        _inLibrary = inLibrary;
      });
    }
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
              if (_resolving) _busyOverlay(),
            ],
          );
        },
      ),
    );
  }

  Widget _hero(MediaItem item) {
    return SizedBox(
      height: 560,
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
            padding: const EdgeInsets.fromLTRB(42, 100, 42, 52),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
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
                      onTap: item.kind == MediaKind.movie
                          ? () => _playPinnedRelease(item)
                          : null,
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
                                        : '${pinned.provider} • This release family is preferred when you choose an episode',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (item.kind == MediaKind.movie)
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
                  if (item.cast.isNotEmpty) ...[
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
                          .map(
                            (name) => Chip(
                              avatar: const Icon(
                                Icons.person_outline_rounded,
                                size: 17,
                              ),
                              label: Text(name),
                            ),
                          )
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
          Row(
            children: [
              Expanded(
                child: Text(
                  'Episodes',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: selected,
                borderRadius: BorderRadius.circular(14),
                items: [
                  for (final season in seasons)
                    DropdownMenuItem(
                      value: season,
                      child: Text('Season $season'),
                    ),
                ],
                onChanged: (value) => setState(() => _selectedSeason = value),
              ),
            ],
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

  Widget _busyOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .66),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 470),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF0D120E),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF263827)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_resolveProgress == null)
                  const CircularProgressIndicator()
                else
                  SizedBox(
                    width: 68,
                    height: 68,
                    child: CircularProgressIndicator(value: _resolveProgress),
                  ),
                const SizedBox(height: 20),
                Text(
                  _status.isEmpty ? 'Finding the best path to play…' : _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    height: 1.4,
                  ),
                ),
                if (_resolveProgress != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${(_resolveProgress! * 100).round()}%',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ],
            ),
          ),
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
        autoUsePinned: true,
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
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = episode == null
          ? 'Finding sources for ${item.title}…'
          : 'Finding sources for ${item.title} ${episode.label}…';
    });

    try {
      final results = await widget.sources.resolve(item, episode: episode);
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
        if (freeResults.isNotEmpty) chosen = freeResults.first;
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
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
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
      final localUrl = await LocalTorrentService.instance.resolve(chosen);
      if (!mounted) return;
      setState(() => _status = 'Torrent metadata ready — opening player…');
      await _openPlayerUrl(
        localUrl,
        item,
        episode,
        releaseHint: releaseHint,
        expectedSizeBytes: chosen.sizeBytes,
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

  Future<void> _playPinnedRelease(MediaItem item) async {
    if (_resolving || !mounted) return;
    final pinKey = widget.sources.sourceTargetKey(item);
    final pinned = await widget.sources.getPinnedSourcePreference(pinKey);
    if (pinned == null || !mounted) return;
    setState(() {
      _resolving = true;
      _resolveProgress = null;
      _status = 'Finding pinned release: ${pinned.label}…';
    });
    try {
      final results = await widget.sources.resolve(item);
      if (!mounted) return;
      SourceResult? match;
      for (final result in results) {
        if (widget.sources.matchesPinned(result, pinned.identity)) {
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
      await _playSourceResult(match, item, null);
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
              ? 'Configure a Stremio-compatible source provider. Direct HTTP streams play immediately, and torrent/magnet sources can use Orvix built-in local P2P engine on Windows. PikPak/TorBox are optional cloud paths.'
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
              ? 'Free Streaming: seed health → quality → resolution → efficient size → compatibility'
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
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
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
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                summaryParts.join(' • '),
                                style: TextStyle(color: color.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        FilterChip(
                          selected: freeStreamingRanking,
                          avatar: const Icon(Icons.bolt_rounded, size: 18),
                          label: const Text('Free Streaming'),
                          tooltip:
                              'Prioritize sources likely to stream smoothly without a paid debrid service: healthy seed swarms first, then quality, resolution, manageable size and compatibility.',
                          onSelected: (value) => setSheetState(() {
                            freeStreamingRanking = value;
                            if (value) smoothRanking = false;
                          }),
                        ),
                        const SizedBox(width: 10),
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
                              'Hide known-risk formats such as AV1, 8K, Hi10P and Dolby Vision-only releases. File size is not used.',
                          onSelected: (value) =>
                              setSheetState(() => compatibilityOnly = value),
                        ),
                        const SizedBox(width: 10),
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
                              'Prioritize likely smoother playback: compatible formats, 1080p/720p, efficient x265/HEVC encodes, stronger seed counts and then smaller files. Results are reordered, not hidden.',
                          onSelected: (value) => setSheetState(() {
                            smoothRanking = value;
                            if (value) freeStreamingRanking = false;
                          }),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () =>
                              customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),
                        if (best != null)
                          FilledButton.icon(
                            onPressed: () => Navigator.pop(sheetContext, best),
                            icon: const Icon(Icons.bolt_rounded),
                            label: Text(
                              bestIsPinned
                                  ? 'Quick Play Pinned'
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
                              child: Text(
                                '${result.provider}${result.isMagnet ? ' • torrent / P2P' : ' • direct URL'}${result.compatibilityFriendly ? '' : ' • ⚠ compatibility risk'}',
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isPinned)
                                  const Chip(
                                    avatar: Icon(
                                      Icons.push_pin_rounded,
                                      size: 16,
                                    ),
                                    label: Text('Pinned'),
                                  )
                                else if (index == 0)
                                  Chip(
                                    label: Text(
                                      freeStreamingRanking
                                          ? 'Free Stream'
                                          : smoothRanking
                                              ? 'Smooth'
                                              : 'Best',
                                    ),
                                  ),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip:
                                      isPinned ? 'Unpin source' : 'Pin source',
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
    String? releaseHint,
    int? expectedSizeBytes,
  }) async {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolveProgress = null;
    });

    final title = episode == null
        ? item.title
        : '${item.title} • ${episode.label} ${episode.title}';
    final next = _nextEpisode(item, episode);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          playback: widget.playback,
          url: url,
          title: title,
          mediaState: widget.mediaState,
          item: item,
          episode: episode,
          releaseHint: releaseHint,
          expectedSizeBytes: expectedSizeBytes,
          nextEpisodeLabel: next == null ? null : '${next.label} ${next.title}',
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
