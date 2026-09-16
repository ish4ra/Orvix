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
    if (!mounted) return;
    setState(() {
      _addons = values;
      _busy = false;
    });
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
      if (mounted) setState(() => _message = 'Source provider added.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.toString();
      });
    }
  }

  Future<void> _remove(String url) async {
    await widget.sources.removeAddonUrl(url);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 60),
      children: [
        Text(
          'Sources',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Connect Stremio-compatible source providers you are authorized to use. Pikora does not bundle content sources.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: const Color(0xFF11141C),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF242938)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add provider',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'Paste the addon base URL or manifest.json URL. Search results from configured providers can then be sent to your PikPak account.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_busy,
                      onSubmitted: (_) => _busy ? null : _add(),
                      decoration: const InputDecoration(
                        hintText: 'https://your-provider.example/manifest.json',
                        prefixIcon: Icon(Icons.extension_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _add,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(_message!),
              ],
            ],
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            const Text(
              'Configured providers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (_busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_addons.isEmpty && !_busy)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1118),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline),
                SizedBox(width: 12),
                Expanded(
                  child: Text('No source providers configured yet. Catalog browsing and PikPak library playback still work without one.'),
                ),
              ],
            ),
          )
        else
          ..._addons.map(
            (url) => Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.hub_outlined)),
                title: Text(Uri.tryParse(url)?.host ?? url),
                subtitle: Text(url),
                trailing: IconButton(
                  tooltip: 'Remove',
                  onPressed: _busy ? null : () => _remove(url),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
