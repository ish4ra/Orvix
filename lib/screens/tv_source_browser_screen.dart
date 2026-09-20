import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/source_provider_service.dart';

/// Android TV source picker.
///
/// Keep this deliberately close to the normal Orvix/mobile source experience:
/// one complete source list, no TV-only ranking modes, no compatibility
/// filters, and no hidden long-press pin gesture.
class TvSourceBrowserScreen extends StatefulWidget {
  const TvSourceBrowserScreen({
    super.key,
    required this.sources,
    required this.item,
    required this.resultsFuture,
    this.episode,
    this.onPlaySource,
  });

  final SourceProviderService sources;
  final MediaItem item;
  final EpisodeItem? episode;
  final Future<List<SourceResult>> resultsFuture;
  final Future<void> Function(SourceResult source)? onPlaySource;

  @override
  State<TvSourceBrowserScreen> createState() => _TvSourceBrowserScreenState();
}

class _TvSourceBrowserScreenState extends State<TvSourceBrowserScreen> {
  List<SourceResult> _results = const [];
  bool _loading = true;
  String? _error;
  String? _openingResource;

  @override
  void initState() {
    super.initState();
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

      final results = refresh
          ? await widget.sources.resolve(
              widget.item,
              episode: widget.episode,
              includeLowQuality: true,
            )
          : await widget.resultsFuture;

      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _play(SourceResult source) async {
    if (_openingResource != null) return;

    final callback = widget.onPlaySource;
    if (callback == null) {
      Navigator.of(context).pop(source);
      return;
    }

    setState(() => _openingResource = source.resource);
    try {
      await callback(source);
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
              const SizedBox(height: 22),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
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

    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'No sources found.',
          style: TextStyle(
            color: Color(0xFFB7BDB8),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 30),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final source = _results[index];
        return _TvSourceRow(
          source: source,
          autofocus: index == 0,
          busy: _openingResource == source.resource,
          onPressed: () => unawaited(_play(source)),
        );
      },
    );
  }
}

class _TvSourceRow extends StatefulWidget {
  const _TvSourceRow({
    required this.source,
    required this.autofocus,
    required this.busy,
    required this.onPressed,
  });

  final SourceResult source;
  final bool autofocus;
  final bool busy;
  final VoidCallback onPressed;

  @override
  State<_TvSourceRow> createState() => _TvSourceRowState();
}

class _TvSourceRowState extends State<_TvSourceRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final quality = source.quality ?? source.releaseQuality ?? '—';
    final detail = <String>[
      source.provider,
      if (source.cached) 'Cached',
      if (source.sizeLabel != null) source.sizeLabel!,
      if (source.seeders != null) '${source.seeders} seeders',
      source.isMagnet ? 'P2P' : 'Direct',
    ].join('  •  ');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      decoration: BoxDecoration(
        color: _focused ? const Color(0xFF222723) : const Color(0xFF141815),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _focused ? Colors.white : const Color(0xFF303631),
          width: _focused ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: widget.autofocus,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.busy ? null : widget.onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            child: Row(
              children: [
                Container(
                  width: 70,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E120F),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFF343B35)),
                  ),
                  child: Text(
                    quality.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFF0F2F0),
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFA5AEA7),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                if (widget.busy)
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                else
                  Icon(
                    Icons.play_arrow_rounded,
                    size: 34,
                    color: _focused
                        ? Colors.white
                        : const Color(0xFF8F9891),
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
              color: _focused ? Colors.white : const Color(0xFF303731),
              width: _focused ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 24),
        ),
      ),
    );
  }
}
