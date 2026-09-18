import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/source_provider_service.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.sources});

  final SourceProviderService sources;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _controller = TextEditingController();
  final _aioStreamsController = TextEditingController();
  final _resultLimitController = TextEditingController();
  final _preferredGroupsController = TextEditingController();
  List<String> _addons = const [];
  List<SourceSortCriterion> _priority = [
    ...SourceProviderService.defaultPriority
  ];
  String? _torrentioUrl;
  String? _aioStreamsUrl;
  bool _busy = true;
  bool _show3D = false;
  bool _showLowQuality = false;
  int _resultLimit = SourceProviderService.defaultResultLimit;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _controller.dispose();
    _aioStreamsController.dispose();
    _resultLimitController.dispose();
    _preferredGroupsController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final values = await widget.sources.getAddonUrls();
    final priority = await widget.sources.getPriorityOrder();
    final torrentio = await widget.sources.getIntegratedTorrentioUrl();
    final aioStreams = await widget.sources.getAioStreamsManifestUrl();
    final show3D = await widget.sources.getShow3D();
    final preferredGroups = await widget.sources.getPreferredGroups();
    final showLowQuality = await widget.sources.getShowLowQuality();
    final resultLimit = await widget.sources.getResultLimit();
    if (!mounted) return;
    setState(() {
      _addons =
          values.where((value) => value != aioStreams).toList(growable: false);
      _priority = priority;
      _torrentioUrl = torrentio;
      _aioStreamsUrl = aioStreams;
      _aioStreamsController.text =
          aioStreams == null ? '' : '$aioStreams/manifest.json';
      _show3D = show3D;
      _showLowQuality = showLowQuality;
      _resultLimit = resultLimit;
      _resultLimitController.text = resultLimit == 0 ? '' : '$resultLimit';
      _preferredGroupsController.text = preferredGroups.join(', ');
      _busy = false;
    });
  }

  Future<void> _setPriority(List<SourceSortCriterion> priority) async {
    setState(() => _priority = priority);
    await widget.sources.setPriorityOrder(priority);
  }

  Future<void> _setShow3D(bool value) async {
    setState(() => _show3D = value);
    await widget.sources.setShow3D(value);
  }

  Future<void> _setShowLowQuality(bool value) async {
    setState(() => _showLowQuality = value);
    await widget.sources.setShowLowQuality(value);
  }

  Future<void> _setResultLimit(int value) async {
    setState(() => _resultLimit = value);
    await widget.sources.setResultLimit(value);
  }

  Future<void> _saveResultLimit() async {
    final raw = _resultLimitController.text.trim();
    if (raw.isEmpty) {
      await _setResultLimit(0);
      if (!mounted) return;
      setState(() => _message = 'Source picker will show all ranked results.');
      return;
    }

    final value = int.tryParse(raw);
    if (value == null || value < 1 || value > 500) {
      setState(() => _message =
          'Enter any result count from 1 to 500, or leave the field empty for all results.');
      return;
    }

    await _setResultLimit(value);
    if (!mounted) return;
    setState(() => _message =
        'Source picker will show the top $value ranked result${value == 1 ? '' : 's'}.');
  }

  Future<void> _showAllResults() async {
    _resultLimitController.clear();
    await _setResultLimit(0);
    if (!mounted) return;
    setState(() => _message = 'Source picker will show all ranked results.');
  }

  Future<void> _savePreferredGroups() async {
    final groups = _preferredGroupsController.text
        .split(RegExp(r'[,;\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    await widget.sources.setPreferredGroups(groups);
    if (!mounted) return;
    setState(() => _message = groups.isEmpty
        ? 'Preferred release groups cleared.'
        : 'Preferred release groups saved. Matching rows will be highlighted.');
  }

  Future<void> _saveAioStreams() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.sources.setAioStreamsManifestUrl(_aioStreamsController.text);
      await _reload();
      if (mounted) {
        setState(() => _message =
            'AIOStreams connected. Its profile stays local on this device.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.toString();
      });
    }
  }

  Future<void> _clearAioStreams() async {
    setState(() => _busy = true);
    await widget.sources.clearAioStreamsManifestUrl();
    _aioStreamsController.clear();
    await _reload();
    if (mounted) {
      setState(() => _message = 'AIOStreams disconnected from Orvix.');
    }
  }

  Future<void> _openMidnightAioStreamsSetup() async {
    final uri = Uri.parse(
      'https://aiostreamsfortheweebsstable.midnightignite.me/stremio/configure',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      setState(() => _message = 'Could not open the AIOStreams setup page.');
    }
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
        setState(() =>
            _message = 'Provider saved. It will be reused automatically.');
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
                    'Orvix resolves Stremio-compatible stream providers in parallel, ranks results, then uses direct playback, built-in local P2P, or your connected cloud/debrid service as appropriate.',
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
        _aioStreamsCard(context),
        const SizedBox(height: 18),
        _sortCard(context),
        const SizedBox(height: 18),
        _resultPreferencesCard(context),
        const SizedBox(height: 26),
        Text(
          'Provider pool',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 5),
        Text(
          'Add multiple Stremio-compatible providers you are authorized to use. Orvix queries the configured provider pool in parallel, merges the returned streams, then de-duplicates exact rows.',
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
        color: const Color(0xFF0D120E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: active
              ? color.primary.withValues(alpha: .5)
              : const Color(0xFF272D3D),
        ),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 28, offset: Offset(0, 12)),
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
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
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
                      ? 'Integrated into Orvix. Limited Lite/limit profiles are automatically supplemented with a broad result request, then merged and de-duplicated.'
                      : 'The resolver is built into Orvix. Add an authorized Torrentio-compatible endpoint once below and Orvix will migrate and reuse it automatically.',
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

  Widget _aioStreamsCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final active = _aioStreamsUrl != null;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E0B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: active
              ? color.primary.withValues(alpha: .5)
              : const Color(0xFF223125),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stream_rounded),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'AIOStreams',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFF173A2B)
                      : const Color(0xFF34303A),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  active ? 'ACTIVE' : 'OPTIONAL',
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
          const SizedBox(height: 8),
          Text(
            active
                ? 'Orvix is querying your configured AIOStreams profile as an additional source aggregator.'
                : 'Configure a public or self-hosted AIOStreams profile, then paste the generated manifest URL here.',
            style: TextStyle(color: color.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 7),
          Text(
            'Privacy: the manifest can act like a credential, so Orvix stores it only on this device and never cloud-syncs it.',
            style: TextStyle(
              color: color.onSurfaceVariant,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _aioStreamsController,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'AIOStreams manifest URL',
              hintText: 'https://…/stremio/…/manifest.json',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _openMidnightAioStreamsSetup,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open Midnight Stable setup'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _saveAioStreams,
                icon: const Icon(Icons.save_outlined),
                label: Text(active ? 'Update manifest' : 'Connect manifest'),
              ),
              if (active)
                TextButton.icon(
                  onPressed: _busy ? null : _clearAioStreams,
                  icon: const Icon(Icons.link_off_rounded),
                  label: const Text('Disconnect'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sortCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E0B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF223125)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sort_rounded),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Source priority',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _setPriority(
                        [...SourceProviderService.defaultPriority]),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset best'),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            'Drag to choose exactly how sources are ranked. Default is cache → quality → resolution → file size → seeders.',
            style: TextStyle(color: color.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 14),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _priority.length,
            onReorder: _busy
                ? (_, __) {}
                : (oldIndex, newIndex) {
                    final next = [..._priority];
                    if (newIndex > oldIndex) newIndex--;
                    final item = next.removeAt(oldIndex);
                    next.insert(newIndex, item);
                    _setPriority(next);
                  },
            itemBuilder: (context, index) {
              final criterion = _priority[index];
              return Container(
                key: ValueKey(criterion.name),
                margin: const EdgeInsets.only(bottom: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF111912),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: const Color(0xFF253527)),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: color.primaryContainer,
                    child: Text('${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  title: Text(criterion.label,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  trailing: const Icon(Icons.drag_indicator_rounded),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _resultPreferencesCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E0B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF223125)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.filter_alt_outlined),
              SizedBox(width: 10),
              Text(
                'Result preferences',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Results shown in source picker',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose any result count you want. Enter 1 for one result, 3 for three results, or leave it empty to show everything.',
                style: TextStyle(
                  color: color.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 190,
                    child: TextField(
                      controller: _resultLimitController,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _busy ? null : _saveResultLimit(),
                      decoration: InputDecoration(
                        labelText: _resultLimit == 0
                            ? 'All results'
                            : 'Top $_resultLimit',
                        hintText: 'e.g. 3',
                        prefixIcon: const Icon(Icons.numbers_rounded),
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _saveResultLimit,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Apply'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _showAllResults,
                    child: const Text('All results'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 26),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _show3D,
            onChanged: _busy ? null : _setShow3D,
            title: const Text('Show 3D / SBS releases'),
            subtitle: const Text(
              'Off by default. Hides SBS/HSBS/3D/top-bottom encodes that otherwise appear as a double image on a normal display.',
            ),
          ),
          const Divider(height: 18),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _showLowQuality,
            onChanged: _busy ? null : _setShowLowQuality,
            title: const Text('Show legacy / low-quality sources'),
            subtitle: const Text(
                'Off by default when HD sources exist. Hides CAM, DVD and sub-720p clutter without removing them when they are the only results.'),
          ),
          const Divider(height: 26),
          Text(
            'Preferred release groups',
            style: TextStyle(
              color: color.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Optional. Enter group names separated by commas. Matching source rows get a ⭐ Preferred badge; this does not invent sources that a provider did not return.',
            style: TextStyle(color: color.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _preferredGroupsController,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _savePreferredGroups(),
                  decoration: const InputDecoration(
                    hintText: 'GROUP-A, GROUP-B',
                    prefixIcon: Icon(Icons.star_outline_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _savePreferredGroups,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _advancedProviderCard(BuildContext context) {
    final custom = _addons.where((url) => url != _torrentioUrl).toList();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D120E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF223125)),
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
                    isTorrentio
                        ? 'Integrated • ${Uri.tryParse(url)?.host ?? url}'
                        : url,
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
