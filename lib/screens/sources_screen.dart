import 'package:flutter/material.dart';

import '../services/source_provider_service.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.sources});

  final SourceProviderService sources;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _controller = TextEditingController();
  List<String> _addons = const [];
  SourceSortMode _sortMode = SourceSortMode.seeders;
  String? _torrentioUrl;
  bool _busy = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final values = await widget.sources.getAddonUrls();
    final sortMode = await widget.sources.getSortMode();
    final torrentio = await widget.sources.getIntegratedTorrentioUrl();
    if (!mounted) return;
    setState(() {
      _addons = values;
      _sortMode = sortMode;
      _torrentioUrl = torrentio;
      _busy = false;
    });
  }

  Future<void> _setSortMode(SourceSortMode mode) async {
    setState(() => _sortMode = mode);
    await widget.sources.setSortMode(mode);
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.sources.addAddonUrl(_controller.text);
      _controller.clear();
      await _reload();
      if (mounted) {
        setState(() => _message = 'Provider saved. It will be reused automatically.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.toString();
      });
    }
  }

  Future<void> _remove(String url) async {
    setState(() => _busy = true);
    await widget.sources.removeAddonUrl(url);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 60),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Source Engine',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -.5,
                        ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Pikora resolves Stremio-compatible sources natively, ranks them here, and sends your selection to PikPak.',
                    style: TextStyle(
                      color: color.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _engineCard(context),
        const SizedBox(height: 18),
        _sortCard(context),
        const SizedBox(height: 26),
        Text(
          'Advanced providers',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 5),
        Text(
          'Optional: add another Stremio-compatible provider you are authorized to use. A saved Torrentio-compatible endpoint is promoted into the integrated slot automatically.',
          style: TextStyle(color: color.onSurfaceVariant, height: 1.45),
        ),
        const SizedBox(height: 13),
        _advancedProviderCard(context),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              color: color.primaryContainer.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_message!),
          ),
        ],
      ],
    );
  }

  Widget _engineCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final active = _torrentioUrl != null;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF11141C),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: active ? color.primary.withValues(alpha: .5) : const Color(0xFF272D3D),
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 28, offset: Offset(0, 12)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.primary.withValues(alpha: .95),
                  color.tertiary.withValues(alpha: .8),
                ],
              ),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.hub_rounded, size: 30, color: Colors.white),
          ),
          const SizedBox(width: 17),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Torrentio-compatible engine',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF173A2B)
                            : const Color(0xFF34303A),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        active ? 'ACTIVE' : 'NOT CONFIGURED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: .7,
                          color: active
                              ? const Color(0xFF83F0B8)
                              : color.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  active
                      ? 'Integrated into Pikora. Your saved endpoint is reused automatically — no need to add it again after updates.'
                      : 'The resolver is built into Pikora. Add an authorized Torrentio-compatible endpoint once below and Pikora will migrate and reuse it automatically.',
                  style: TextStyle(color: color.onSurfaceVariant, height: 1.4),
                ),
                if (active) ...[
                  const SizedBox(height: 7),
                  Text(
                    Uri.tryParse(_torrentioUrl!)?.host ?? 'Torrentio',
                    style: TextStyle(
                      color: color.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sortCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final detail = switch (_sortMode) {
      SourceSortMode.seeders =>
        'Best for reliability. Sources with more active seeders are shown first; known 0-seed torrents drop to the bottom.',
      SourceSortMode.fileSize =>
        'Largest releases are shown first. Useful when you prefer high-bitrate Blu-ray/Remux files.',
      SourceSortMode.quality =>
        'Resolution leads the ranking: 2160p/4K first, followed by 1440p, 1080p and lower qualities.',
    };

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1118),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF242A39)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.sort_rounded),
              SizedBox(width: 10),
              Text(
                'Default source order',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 15),
          SegmentedButton<SourceSortMode>(
            showSelectedIcon: true,
            segments: const [
              ButtonSegment(
                value: SourceSortMode.seeders,
                icon: Icon(Icons.people_alt_rounded),
                label: Text('Seeders'),
              ),
              ButtonSegment(
                value: SourceSortMode.fileSize,
                icon: Icon(Icons.storage_rounded),
                label: Text('File size'),
              ),
              ButtonSegment(
                value: SourceSortMode.quality,
                icon: Icon(Icons.high_quality_rounded),
                label: Text('Quality'),
              ),
            ],
            selected: {_sortMode},
            onSelectionChanged: _busy
                ? null
                : (selection) {
                    if (selection.isNotEmpty) _setSortMode(selection.first);
                  },
          ),
          const SizedBox(height: 13),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              detail,
              key: ValueKey(_sortMode),
              style: TextStyle(color: color.onSurfaceVariant, height: 1.42),
            ),
          ),
        ],
      ),
    );
  }

  Widget _advancedProviderCard(BuildContext context) {
    final custom = _addons.where((url) => url != _torrentioUrl).toList();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF11141C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF242938)),
      ),
      child: ExpansionTile(
        initiallyExpanded: _torrentioUrl == null,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        leading: const Icon(Icons.tune_rounded),
        title: const Text(
          'Provider configuration',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          _torrentioUrl == null
              ? 'Add your provider endpoint once'
              : '${custom.length} additional provider${custom.length == 1 ? '' : 's'}',
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _add(),
                  decoration: const InputDecoration(
                    hintText: 'https://provider.example/manifest.json',
                    prefixIcon: Icon(Icons.extension_outlined),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Save'),
              ),
            ],
          ),
          if (_addons.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 4),
            ..._addons.map(
              (url) {
                final isTorrentio = url == _torrentioUrl;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: isTorrentio
                        ? const Color(0xFF233A31)
                        : const Color(0xFF1D2230),
                    child: Icon(
                      isTorrentio ? Icons.bolt_rounded : Icons.hub_outlined,
                    ),
                  ),
                  title: Text(
                    widget.sources.providerName(url),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    isTorrentio ? 'Integrated • ${Uri.tryParse(url)?.host ?? url}' : url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: _busy ? null : () => _remove(url),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
