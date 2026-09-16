import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/catalog_service.dart';
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
  });

  final MediaItem item;
  final CatalogService catalog;
  final PikPakService pikpak;
  final PikPakTransferService transfer;
  final SourceProviderService sources;
  final PlaybackService playback;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  late Future<MediaItem> _detailsFuture;
  bool _resolving = false;
  String _status = '';
  int? _selectedSeason;

  @override
  void initState() {
    super.initState();
    _detailsFuture = _loadDetails();
  }

  Future<MediaItem> _loadDetails() async {
    final details = await widget.catalog.details(widget.item);
    final item = details ?? widget.item;
    if (item.episodes.isNotEmpty) {
      _selectedSeason = item.episodes.map((e) => e.season).reduce((a, b) => a < b ? a : b);
    }
    return item;
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
                  SliverToBoxAdapter(child: _Hero(item: item)),
                  SliverToBoxAdapter(child: _Info(item: item)),
                  if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
                    SliverToBoxAdapter(child: _episodes(item)),
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
              if (_resolving)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: .64),
                    child: Center(
                      child: Container(
                        width: 430,
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF11141C),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFF292F41)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 20),
                            Text(
                              _status.isEmpty ? 'Finding the best path to play…' : _status,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _episodes(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    final selected = _selectedSeason ?? seasons.first;
    final episodes = item.episodes.where((e) => e.season == selected).toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));

    return Padding(
      padding: const EdgeInsets.fromLTRB(38, 22, 38, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Episodes',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
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
          ...episodes.map(
            (episode) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF10131A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF202635)),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                leading: SizedBox(
                  width: 96,
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
                    : Text(
                        episode.overview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: FilledButton.icon(
                  onPressed: _resolving ? null : () => _play(item, episode: episode),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _play(MediaItem item, {EpisodeItem? episode}) async {
    setState(() {
      _resolving = true;
      _status = 'Checking your PikPak library…';
    });
    try {
      final existing = await _findInPikPak(item, episode: episode);
      if (existing != null) {
        await _openPikPakFile(existing, item, episode);
        return;
      }

      setState(() => _status = 'Checking your configured source providers…');
      final sources = await widget.sources.resolve(item, episode: episode);
      if (!mounted) return;
      setState(() => _resolving = false);

      if (sources.isEmpty) {
        final configured = await widget.sources.getAddonUrls();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(configured.isEmpty
                ? 'Not in PikPak. Add a source provider from Sources, then try again.'
                : 'No configured provider returned a source for this title.'),
          ),
        );
        return;
      }

      final chosen = await _chooseSource(sources);
      if (chosen == null || !mounted) return;

      setState(() {
        _resolving = true;
        _status = 'Sending ${chosen.quality ?? 'source'} to PikPak…';
      });
      final taskName = episode == null
          ? item.title
          : '${item.title} ${episode.label}';
      await widget.transfer.addResource(chosen.resource, name: taskName);

      for (var attempt = 0; attempt < 18; attempt++) {
        if (!mounted) return;
        setState(() => _status = 'PikPak is preparing the file… ${attempt * 5}s');
        await Future<void>.delayed(const Duration(seconds: 5));
        final match = await _findInPikPak(item, episode: episode);
        if (match != null) {
          await _openPikPakFile(match, item, episode);
          return;
        }
      }

      if (!mounted) return;
      setState(() => _resolving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Added to PikPak. It is still preparing; open My PikPak in a moment to play it.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _resolving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not play: $e')));
    }
  }

  Future<SourceResult?> _chooseSource(List<SourceResult> results) {
    return showModalBottomSheet<SourceResult>(
      context: context,
      backgroundColor: const Color(0xFF11141C),
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose source',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text('The selected source will be sent to your connected PikPak account.'),
              const SizedBox(height: 14),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: results.length.clamp(0, 20),
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(result.quality?.replaceAll('P', '') ?? '${index + 1}'),
                      ),
                      title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${result.provider}${result.isMagnet ? ' • torrent' : ' • direct'}'),
                      trailing: const Icon(Icons.chevron_right),
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
        final titleHits = titleWords.where(name.contains).length;
        final episodeOk = episode == null ||
            name.contains(_normalize(episode.label)) ||
            name.contains('s${episode.season}e${episode.episode}') ||
            name.contains('${episode.season}x${episode.episode}');
        if ((name.contains(wanted) || titleHits >= (titleWords.length <= 2 ? 1 : 2)) && episodeOk) {
          return file;
        }
      }
    }
    return null;
  }

  Future<void> _openPikPakFile(PikPakFile file, MediaItem item, EpisodeItem? episode) async {
    if (!mounted) return;
    setState(() => _status = 'Resolving PikPak streaming URL…');
    final url = await widget.transfer.fetchPlayableUrl(file.id) ?? file.webContentLink;
    if (url == null || url.isEmpty) {
      throw Exception('PikPak did not return a playable URL yet.');
    }
    if (!mounted) return;
    setState(() => _resolving = false);
    final title = episode == null ? item.title : '${item.title} • ${episode.label} ${episode.title}';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          playback: widget.playback,
          url: url,
          title: title,
        ),
      ),
    );
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class _Hero extends StatelessWidget {
  const _Hero({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 500,
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
                colors: [Color(0x3307090E), Color(0xFF07090E)],
                stops: [.2, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xF207090E), Color(0x7707090E), Color(0x0007090E)],
                stops: [0, .46, .9],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(42, 100, 42, 48),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.8,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        _MetaPill(item.typeLabel),
                        if (item.year != null) _MetaPill(item.year!),
                        if (item.runtime != null) _MetaPill(item.runtime!),
                        if (item.rating != null) _MetaPill('★ ${item.rating!.toStringAsFixed(1)}'),
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
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(38, 4, 38, 18),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: item.genres.map((genre) => Chip(label: Text(genre))).toList(growable: false),
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
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}
