import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
import '../services/media_state_service.dart';
import '../services/pikpak_service.dart';
import '../services/pikpak_transfer_service.dart';
import '../services/playback_service.dart';
import '../services/source_provider_service.dart';
import 'player_screen.dart';

class DetailsScreen extends StatefulWidget {
  const DetailsScreen({
    super.key,
    required this.item,
    required this.catalog,
    required this.pikpak,
    required this.transfer,
    required this.sources,
    required this.playback,
    required this.mediaState,
  });

  final MediaItem item;
  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final PlaybackService playback;
  final MediaStateService mediaState;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  late final Future<MediaItem> _detailsFuture;
  bool _resolving = false;
  bool _watchlisted = false;
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
    if (mounted) setState(() => _watchlisted = watchlisted);
    return item;
  }

  Future<void> _toggleWatchlist(MediaItem item) async {
    final added = await widget.mediaState.toggleWatchlist(item);
    if (!mounted) return;
    setState(() => _watchlisted = added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(added ? 'Added to My Watchlist.' : 'Removed from My Watchlist.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07090E),
      body: FutureBuilder<MediaItem>(
        future: _detailsFuture,
        builder: (context, snapshot) {
          final item = snapshot.data ?? widget.item;
          return Stack(
            children: [
              CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _hero(item)),
                  if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
                    SliverToBoxAdapter(child: _episodeSection(item)),
                  if (item.kind == MediaKind.series && item.episodes.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(40, 10, 40, 50),
                        child: Text('Episode metadata is not available for this title yet.'),
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
                colors: [Color(0x2207090E), Color(0xFF07090E)],
                stops: [.16, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFA07090E), Color(0xB807090E), Color(0x0007090E)],
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
                        if (item.rating != null) _MetaPill('★ ${item.rating!.toStringAsFixed(1)}'),
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
                        OutlinedButton.icon(
                          onPressed: () => _toggleWatchlist(item),
                          icon: Icon(
                            _watchlisted ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
                          ),
                          label: Text(_watchlisted ? 'In Watchlist' : 'Watchlist'),
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

  Widget _episodeSection(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    final selected = _selectedSeason ?? seasons.first;
    final episodes = item.episodes.where((e) => e.season == selected).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));

    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 18, 40, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Episodes',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const Spacer(),
              DropdownButton<int>(
                value: selected,
                borderRadius: BorderRadius.circular(14),
                items: [
                  for (final season in seasons)
                    DropdownMenuItem(value: season, child: Text('Season $season')),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF10131A),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFF202635)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        leading: SizedBox(
          width: 104,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: episode.thumbnail == null
                ? Container(
                    color: const Color(0xFF191D27),
                    child: const Icon(Icons.movie_outlined),
                  )
                : CachedNetworkImage(
                    imageUrl: episode.thumbnail!,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const Icon(Icons.movie_outlined),
                  ),
          ),
        ),
        title: Text(
          '${episode.label}  ${episode.title}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: episode.overview == null
            ? null
            : Text(episode.overview!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: FilledButton.icon(
          onPressed: _resolving ? null : () => _play(item, episode: episode),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Play'),
        ),
      ),
    );
  }

  Widget _busyOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .66),
        child: Center(
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF11141C),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF292F41)),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 30, spreadRadius: 5),
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
                  style: const TextStyle(fontWeight: FontWeight.w800, height: 1.4),
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
      _status = 'Checking your PikPak library…';
    });
    try {
      final existing = await _findInPikPak(item, episode: episode);
      if (existing != null) {
        await _openPikPakFile(existing, item, episode);
        return;
      }

      setState(() => _status = 'Checking your configured source providers…');
      final results = await widget.sources.resolve(item, episode: episode);
      if (!mounted) return;
      setState(() => _resolving = false);

      if (results.isEmpty) {
        final configured = await widget.sources.getAddonUrls();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              configured.isEmpty
                  ? 'Not in PikPak. Add a source provider from Sources, then try again.'
                  : 'No configured provider returned a source for this title.',
            ),
          ),
        );
        return;
      }

      final chosen = await _chooseSource(results);
      if (chosen == null || !mounted) return;

      setState(() {
        _resolving = true;
        _resolveProgress = .02;
        _status = 'Sending ${chosen.quality ?? 'source'} to PikPak…';
      });
      final taskName = episode == null ? item.title : '${item.title} ${episode.label}';
      final added = await widget.transfer.addResource(chosen.resource, name: taskName);

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play: $e')),
      );
    }
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
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));

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
        for (var scan = 0; scan < 4; scan++) {
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
        content: Text('The PikPak task is still running. You can check it again shortly.'),
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
        content: Text('Added to PikPak. It is still preparing; check My PikPak shortly.'),
      ),
    );
  }

  Future<SourceResult?> _chooseSource(List<SourceResult> results) {
    final count = results.length > 20 ? 20 : results.length;
    final best = widget.sources.bestSource(results);
    return showModalBottomSheet<SourceResult>(
      context: context,
      backgroundColor: const Color(0xFF11141C),
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 780),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 4),
                        const Text('Results are ranked by quality and common release markers.'),
                      ],
                    ),
                  ),
                  if (best != null)
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(context, best),
                      icon: const Icon(Icons.bolt_rounded),
                      label: Text('Quick Play ${best.quality ?? ''}'.trim()),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 440),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: count,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(result.quality?.replaceAll('P', '') ?? '${index + 1}'),
                      ),
                      title: Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${result.provider}${result.isMagnet ? ' • cloud source' : ' • direct'}',
                      ),
                      trailing: index == 0
                          ? const Chip(label: Text('Best'))
                          : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, result),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<PikPakFile?> _findInPikPak(MediaItem item, {EpisodeItem? episode}) async {
    if (!await widget.pikpak.isSignedIn) return null;
    final wanted = _normalize(episode == null ? item.title : '${item.title} ${episode.label}');
    final titleWords = _normalize(item.title).split(' ').where((e) => e.length > 2).toList();
    final folders = <String>[''];
    var scanned = 0;

    while (folders.isNotEmpty && scanned < 900) {
      final folder = folders.removeAt(0);
      final files = await widget.pikpak.listFiles(parentId: folder);
      for (final file in files) {
        scanned++;
        if (file.isFolder) {
          if (folders.length < 60) folders.add(file.id);
          continue;
        }
        final name = _normalize(file.name);
        final titleHits = titleWords.where((word) => name.contains(word)).length;
        final episodeOk = episode == null ||
            name.contains(_normalize(episode.label)) ||
            name.contains('s${episode.season}e${episode.episode}') ||
            name.contains('${episode.season}x${episode.episode}');
        final enoughTitleHits = titleWords.isEmpty
            ? name.contains(wanted)
            : titleHits >= (titleWords.length <= 2 ? 1 : 2);
        if ((name.contains(wanted) || enoughTitleHits) && episodeOk) return file;
      }
    }
    return null;
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
    final url = await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
    if (url == null || url.isEmpty) {
      throw Exception('PikPak did not return a playable URL yet.');
    }
    await _openPlayerUrl(url, item, episode);
  }

  Future<void> _openPlayerUrl(
    String url,
    MediaItem item,
    EpisodeItem? episode,
  ) async {
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
    final episodes = [...item.episodes]
      ..sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.episode.compareTo(b.episode);
      });
    final index = episodes.indexWhere(
      (episode) =>
          episode.id == current.id ||
          (episode.season == current.season && episode.episode == current.episode),
    );
    if (index < 0 || index + 1 >= episodes.length) return null;
    return episodes[index + 1];
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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
