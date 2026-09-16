from pathlib import Path
import re

# Patch SourceProviderService: richer metadata, custom priority order, broaden limited Torrentio profiles.
p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')

s = s.replace("enum SourceSortMode { seeders, fileSize, quality }\n", """enum SourceSortMode { seeders, fileSize, quality }\n\nenum SourceSortCriterion { releaseQuality, resolution, seeders, fileSize }\n\nextension SourceSortCriterionLabel on SourceSortCriterion {\n  String get label {\n    switch (this) {\n      case SourceSortCriterion.releaseQuality:\n        return 'Quality';\n      case SourceSortCriterion.resolution:\n        return 'Resolution';\n      case SourceSortCriterion.seeders:\n        return 'Seeders';\n      case SourceSortCriterion.fileSize:\n        return 'File size';\n    }\n  }\n}\n""")

s = s.replace("    this.quality,\n    this.seeders,", "    this.quality,\n    this.releaseQuality,\n    this.seeders,")
s = s.replace("  final String? quality;\n  final int? seeders;", "  final String? quality;\n  final String? releaseQuality;\n  final int? seeders;")

needle = """  int get qualityRank {\n    switch (quality?.toUpperCase()) {\n      case '2160P':\n      case '4K':\n        return 600;\n      case '1440P':\n        return 500;\n      case '1080P':\n        return 400;\n      case '720P':\n        return 300;\n      case '480P':\n        return 200;\n      default:\n        return 100;\n    }\n  }\n"""
replacement = needle + """\n  int get releaseQualityRank {\n    switch (releaseQuality?.toUpperCase()) {\n      case 'REMUX':\n        return 800;\n      case 'BLURAY':\n        return 700;\n      case 'WEB-DL':\n        return 600;\n      case 'WEBRIP':\n        return 550;\n      case 'HDTV':\n        return 400;\n      case 'DVD':\n        return 250;\n      case 'CAM':\n        return 100;\n      default:\n        return 200;\n    }\n  }\n"""
s = s.replace(needle, replacement)

s = s.replace("  static const _sortKey = 'pikora_source_sort_mode_v2';", "  static const _sortKey = 'pikora_source_sort_mode_v2';\n  static const _priorityKey = 'pikora_source_priority_v1';")

# Insert custom priority methods after setSortMode.
marker = """  Future<void> setSortMode(SourceSortMode mode) async {\n    final prefs = await SharedPreferences.getInstance();\n    await prefs.setString(_sortKey, mode.name);\n  }\n"""
insert = marker + """\n  static const defaultPriority = <SourceSortCriterion>[\n    SourceSortCriterion.releaseQuality,\n    SourceSortCriterion.resolution,\n    SourceSortCriterion.seeders,\n    SourceSortCriterion.fileSize,\n  ];\n\n  Future<List<SourceSortCriterion>> getPriorityOrder() async {\n    final prefs = await SharedPreferences.getInstance();\n    final stored = prefs.getStringList(_priorityKey);\n    if (stored == null || stored.isEmpty) return [...defaultPriority];\n    final out = <SourceSortCriterion>[];\n    for (final value in stored) {\n      for (final criterion in SourceSortCriterion.values) {\n        if (criterion.name == value && !out.contains(criterion)) out.add(criterion);\n      }\n    }\n    for (final criterion in defaultPriority) {\n      if (!out.contains(criterion)) out.add(criterion);\n    }\n    return out;\n  }\n\n  Future<void> setPriorityOrder(List<SourceSortCriterion> order) async {\n    final normalized = <SourceSortCriterion>[];\n    for (final criterion in order) {\n      if (!normalized.contains(criterion)) normalized.add(criterion);\n    }\n    for (final criterion in defaultPriority) {\n      if (!normalized.contains(criterion)) normalized.add(criterion);\n    }\n    final prefs = await SharedPreferences.getInstance();\n    await prefs.setStringList(_priorityKey, normalized.map((e) => e.name).toList());\n  }\n\n  int compareResults(\n    SourceResult a,\n    SourceResult b,\n    List<SourceSortCriterion> priority,\n  ) {\n    for (final criterion in priority) {\n      final av = _criterionValue(a, criterion);\n      final bv = _criterionValue(b, criterion);\n      final cmp = bv.compareTo(av);\n      if (cmp != 0) return cmp;\n    }\n    return a.title.compareTo(b.title);\n  }\n\n  int _criterionValue(SourceResult result, SourceSortCriterion criterion) {\n    switch (criterion) {\n      case SourceSortCriterion.releaseQuality:\n        return result.releaseQualityRank;\n      case SourceSortCriterion.resolution:\n        return result.qualityRank;\n      case SourceSortCriterion.seeders:\n        return result.seeders ?? -1;\n      case SourceSortCriterion.fileSize:\n        return result.sizeBytes ?? 0;\n    }\n  }\n\n  List<SourceResult> sortResults(\n    Iterable<SourceResult> results,\n    List<SourceSortCriterion> priority,\n  ) {\n    final out = results.toList();\n    out.sort((a, b) => compareResults(a, b, priority));\n    return out;\n  }\n"""
s = s.replace(marker, insert)

# Query broad Torrentio variant alongside limited legacy profile.
old = """    final torrentio = _normalizeAddonUrl(\n      prefs.getString(_torrentioKey) ?? _bundledTorrentioProvider,\n    );\n    if (torrentio != null) out.add(torrentio);\n"""
new = """    final torrentio = _normalizeAddonUrl(\n      prefs.getString(_torrentioKey) ?? _bundledTorrentioProvider,\n    );\n    if (torrentio != null) {\n      final broad = _broadenTorrentioUrl(torrentio);\n      if (broad != null && broad != torrentio) out.add(broad);\n      out.add(torrentio);\n    }\n"""
s = s.replace(old, new)

# resolve uses custom priority.
s = s.replace("    final sortMode = await getSortMode();", "    final sortMode = await getSortMode();\n    final priority = await getPriorityOrder();", 1)
s = s.replace("    out.sort((a, b) => b.preferenceScore.compareTo(a.preferenceScore));\n    return out;", "    return sortResults(out, priority);", 1)

# Metadata parsing from name + title + filename; classify release source.
s = s.replace("""        final quality = _guessQuality(rawTitle);\n        final seeders = _guessSeeders(raw, rawTitle);\n        final sizeBytes = _guessSizeBytes(raw, rawTitle);\n""", """        final metadataText = <String>[\n          raw['name']?.toString() ?? '',\n          rawTitle,\n          fileNameHint ?? '',\n        ].where((value) => value.trim().isNotEmpty).join('\\n');\n        final quality = _guessQuality(metadataText);\n        final releaseQuality = _guessReleaseQuality(metadataText);\n        final seeders = _guessSeeders(raw, metadataText);\n        final sizeBytes = _guessSizeBytes(raw, metadataText);\n""")

s = s.replace("""        final statParts = <String>[\n          '👥 ${seeders?.toString() ?? '—'} seeders',\n          '💾 ${_formatSize(sizeBytes) ?? 'size unknown'}',\n        ];\n""", """        final statParts = <String>[\n          if (releaseQuality != null) '🎞 $releaseQuality',\n          if (quality != null) '📺 $quality',\n          '👥 ${seeders?.toString() ?? '—'} seeders',\n          '💾 ${_formatSize(sizeBytes) ?? 'size unknown'}',\n        ];\n""")
s = s.replace("            quality: quality,\n            seeders: seeders,", "            quality: quality,\n            releaseQuality: releaseQuality,\n            seeders: seeders,")

# Release source classifier + broad URL helper before _guessQuality.
marker = "  String? _guessQuality(String value) {"
helper = r'''  String? _guessReleaseQuality(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\bremux\b').hasMatch(lower)) return 'REMUX';
    if (lower.contains('blu-ray') || lower.contains('bluray') ||
        RegExp(r'\b(?:bdremux|bdrip|brrip)\b').hasMatch(lower)) {
      return 'BluRay';
    }
    if (RegExp(r'\bweb[ ._-]?dl\b').hasMatch(lower) || lower.contains('webdl')) {
      return 'WEB-DL';
    }
    if (RegExp(r'\bweb[ ._-]?rip\b').hasMatch(lower) || lower.contains('webrip')) {
      return 'WEBRip';
    }
    if (RegExp(r'\b(?:hdtv|hdrip|ppv|dsr)\b').hasMatch(lower)) return 'HDTV';
    if (RegExp(r'\b(?:dvdrip|dvd-rip|dvd)\b').hasMatch(lower)) return 'DVD';
    if (RegExp(r'\b(?:cam|hdcam|camrip|telesync|telecine)\b').hasMatch(lower)) return 'CAM';
    return null;
  }

  String? _broadenTorrentioUrl(String value) {
    if (!_looksLikeTorrentio(value)) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final segments = [...uri.pathSegments];
    var changed = false;

    if (segments.isNotEmpty && segments.last.toLowerCase() == 'lite') {
      segments.removeLast();
      changed = true;
    }

    for (var i = 0; i < segments.length; i++) {
      if (!segments[i].contains('=')) continue;
      final parts = segments[i].split('|');
      final filtered = parts.where((part) {
        final key = part.split('=').first.trim().toLowerCase();
        return key != 'limit';
      }).toList();
      if (filtered.length != parts.length) {
        changed = true;
        if (filtered.isEmpty) {
          segments.removeAt(i);
          i--;
        } else {
          segments[i] = filtered.join('|');
        }
      }
    }

    if (!changed) return value;
    return uri.replace(pathSegments: segments).toString().replaceAll(RegExp(r'/$'), '');
  }

'''
s = s.replace(marker, helper + marker)
p.write_text(s, encoding='utf-8')

# Patch source picker to use fully customizable priority.
p = Path('lib/screens/details_screen.dart')
s = p.read_text(encoding='utf-8')
start = s.index('  Future<SourceResult?> _chooseSource(List<SourceResult> results) async {')
end = s.index('\n\n  Future<PikPakFile?> _findInPikPak(', start)
new_method = r'''  Future<SourceResult?> _chooseSource(List<SourceResult> results) async {
    var priority = await widget.sources.getPriorityOrder();
    if (!mounted) return null;

    Future<void> customizePriority(BuildContext dialogContext, StateSetter setSheetState) async {
      final working = [...priority];
      final saved = await showDialog<List<SourceSortCriterion>>(
        context: dialogContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Source priority'),
            content: SizedBox(
              width: 430,
              height: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Drag criteria into the order you want. #1 has the highest priority.'),
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
                          title: Text(criterion.label, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                onPressed: () => Navigator.pop(
                  dialogContext,
                  [...SourceProviderService.defaultPriority],
                ),
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
      backgroundColor: const Color(0xFF11141C),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 960),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final sorted = widget.sources.sortResults(results, priority);
          final best = sorted.isEmpty ? null : sorted.first;
          final color = Theme.of(context).colorScheme;
          final priorityText = priority.map((e) => e.label.toLowerCase()).join(' → ');

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
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${results.length} result${results.length == 1 ? '' : 's'} returned • showing all',
                                style: TextStyle(color: color.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => customizePriority(sheetContext, setSheetState),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Sort priority'),
                        ),
                        const SizedBox(width: 10),
                        if (best != null)
                          FilledButton.icon(
                            onPressed: () => Navigator.pop(sheetContext, best),
                            icon: const Icon(Icons.bolt_rounded),
                            label: Text('Quick Play ${best.quality ?? ''}'.trim()),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: color.primaryContainer.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.sort_rounded, size: 18, color: color.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Priority: $priorityText',
                              style: TextStyle(color: color.primary, fontSize: 12, fontWeight: FontWeight.w800),
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
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            leading: CircleAvatar(
                              radius: 25,
                              child: Text(
                                result.quality?.replaceAll('P', '') ?? '—',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
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
                                '${result.provider}${result.isMagnet ? ' • PikPak cloud source' : ' • direct URL'}',
                              ),
                            ),
                            trailing: index == 0
                                ? const Chip(label: Text('Best'))
                                : const Icon(Icons.chevron_right_rounded),
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
  }'''
s = s[:start] + new_method + s[end:]
p.write_text(s, encoding='utf-8')

# Patch Sources settings with reorderable four-level priority.
p = Path('lib/screens/sources_screen.dart')
s = p.read_text(encoding='utf-8')
s = s.replace('  SourceSortMode _sortMode = SourceSortMode.seeders;\n', '  List<SourceSortCriterion> _priority = [...SourceProviderService.defaultPriority];\n')
s = s.replace('    final sortMode = await widget.sources.getSortMode();\n', '    final priority = await widget.sources.getPriorityOrder();\n')
s = s.replace('      _sortMode = sortMode;\n', '      _priority = priority;\n')
old_method = """  Future<void> _setSortMode(SourceSortMode mode) async {\n    setState(() => _sortMode = mode);\n    await widget.sources.setSortMode(mode);\n  }\n"""
new_method = """  Future<void> _setPriority(List<SourceSortCriterion> priority) async {\n    setState(() => _priority = priority);\n    await widget.sources.setPriorityOrder(priority);\n  }\n"""
s = s.replace(old_method, new_method)
start = s.index('  Widget _sortCard(BuildContext context) {')
end = s.index('\n\n  Widget _advancedProviderCard', start)
new_sort = r'''  Widget _sortCard(BuildContext context) {
    final color = Theme.of(context).colorScheme;
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
                    : () => _setPriority([...SourceProviderService.defaultPriority]),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Reset best'),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            'Drag to choose exactly how sources are ranked. Default is release quality → resolution → seeders → file size.',
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
                  color: const Color(0xFF151923),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: const Color(0xFF292F40)),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: color.primaryContainer,
                    child: Text('${index + 1}', style: const TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  title: Text(criterion.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                  trailing: const Icon(Icons.drag_indicator_rounded),
                ),
              );
            },
          ),
        ],
      ),
    );
  }'''
s = s[:start] + new_sort + s[end:]
# Explain broad Torrentio behavior in engine card.
s = s.replace("'Integrated into Pikora. Your saved endpoint is reused automatically — no need to add it again after updates.'", "'Integrated into Pikora. Limited Lite/limit profiles are automatically supplemented with a broad result request, then merged and de-duplicated.'")
p.write_text(s, encoding='utf-8')

# Patch PikPak auto rendition selection: favor official default/safe 1080p for huge remuxes.
p = Path('lib/services/pikpak_transfer_service.dart')
s = p.read_text(encoding='utf-8')
s = s.replace("  static const _smoothBitrateCeiling = 30 * 1000 * 1000;", "  static const _smoothBitrateCeiling = 24 * 1000 * 1000;\n  static const _ultraHugeThreshold = 40 * 1024 * 1024 * 1024;")
start = s.index('  String? _selectMediaUrl(Map<String, dynamic> decoded) {')
end = s.index('\n\n  int _smoothMediaScore(', start)
new_select = r'''  String? _selectMediaUrl(Map<String, dynamic> decoded) {
    final medias = decoded['medias'];
    if (medias is! List || medias.isEmpty) return null;

    final entries = medias
        .whereType<Map<String, dynamic>>()
        .where((media) => _mediaUrl(media) != null)
        .where((media) => media['need_more_quota'] != true)
        .where((media) => !media.containsKey('is_visible') || media['is_visible'] != false)
        .toList(growable: false);
    if (entries.isEmpty) return null;

    Map<String, dynamic>? origin;
    Map<String, dynamic>? defaultMedia;
    for (final media in entries) {
      if (origin == null && media['is_origin'] == true) origin = media;
      if (defaultMedia == null && media['is_default'] == true) defaultMedia = media;
    }

    final fileSize = _parseInt(decoded['size']) ?? 0;
    final originBitRate = origin == null ? 0 : _mediaBitRate(origin);
    final originHeight = origin == null ? 0 : _mediaHeight(origin);
    final heavyOrigin = fileSize >= _hugeFileThreshold ||
        originBitRate >= _smoothBitrateCeiling ||
        (originHeight >= 2160 && fileSize >= _largeUhdThreshold);

    if (heavyOrigin) {
      final transcodes = entries.where((media) => media['is_origin'] != true).toList();
      if (transcodes.isNotEmpty) {
        // For very large UHD remuxes, prioritize a cloud 1080p rendition. This
        // mirrors the "smooth first" behavior users see in the PikPak client
        // and avoids decoding/streaming a 70GB+ DV/HEVC origin inside Flutter.
        final targetMaxHeight = fileSize >= _ultraHugeThreshold ? 1080 : 2160;
        final preferred = transcodes.where((media) {
          final h = _mediaHeight(media);
          final br = _mediaBitRate(media);
          return (h <= 0 || h <= targetMaxHeight) &&
              (br <= 0 || br <= _smoothBitrateCeiling);
        }).toList();

        final pool = preferred.isNotEmpty ? preferred : transcodes;
        pool.sort((a, b) => _safeMediaScore(b, targetMaxHeight).compareTo(
              _safeMediaScore(a, targetMaxHeight),
            ));
        final smooth = _mediaUrl(pool.first);
        if (smooth != null) return smooth;
      }
    }

    // Normal files follow PikPak's own preferred rendition first.
    if (defaultMedia != null) return _mediaUrl(defaultMedia);
    if (origin != null) return _mediaUrl(origin);
    return _mediaUrl(entries.first);
  }

  int _safeMediaScore(Map<String, dynamic> media, int targetMaxHeight) {
    final height = _mediaHeight(media);
    final bitRate = _mediaBitRate(media);
    final codec = _mediaCodec(media);
    var score = 0;
    if (media['is_default'] == true) score += 500000000;
    if (height > 0 && height <= targetMaxHeight) score += height * 100000;
    if (bitRate > 0 && bitRate <= _smoothBitrateCeiling) score += bitRate ~/ 1000;
    if (codec.contains('264') || codec.contains('avc')) score += 80000000;
    return score;
  }

  String _mediaCodec(Map<String, dynamic> media) {
    final video = media['video'];
    if (video is Map<String, dynamic>) {
      return (video['codec'] ?? video['codec_name'] ?? '').toString().toLowerCase();
    }
    return '';
  }'''
s = s[:start] + new_select + s[end:]
p.write_text(s, encoding='utf-8')

# Patch PlaybackService to use patched package defaults + Debrify-vetted Large/Extended profile without cache-pause.
p = Path('lib/services/playback_service.dart')
s = p.read_text(encoding='utf-8')
s = re.sub(r"PlaybackService\(\) : player = Player\(\) \{.*?\n  \}\n", "PlaybackService() : player = Player() {\n    // Keep the patched media_kit_video platform defaults. On Windows the\n    // patched controller uses mpv's native auto hardware decoder path.\n    controller = VideoController(player);\n  }\n", s, count=1, flags=re.S)
s = s.replace("""    const properties = <String, String>{\n      'cache': 'yes',\n      'demuxer-thread': 'yes',\n      'demuxer-max-bytes': '512MiB',\n      'demuxer-max-back-bytes': '32MiB',\n      'demuxer-readahead-secs': '300',\n      'cache-secs': '300',\n      'cache-pause': 'yes',\n      'cache-pause-wait': '3',\n      'network-timeout': '60',\n      'stream-lavf-o':\n          'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',\n    };\n""", """    const properties = <String, String>{\n      // Debrify-vetted Large + Extended profile. Deliberately do not force\n      // cache-pause/cache-pause-wait: those can turn ordinary read-ahead into\n      // repeated visible stalls on fast cloud VOD.\n      'demuxer-max-bytes': '256MiB',\n      'demuxer-readahead-secs': '120',\n      'cache-secs': '120',\n      'network-timeout': '90',\n      'stream-lavf-o':\n          'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',\n    };\n""")
s = s.replace('/// The 512 MiB forward packet budget is intentionally much larger than the\n  /// old 256 MiB profile. mpv continuously reads ahead while playback runs, up\n  /// to about five minutes when bitrate and the byte ceiling permit it. If the\n  /// CDN briefly falls behind, cache-pause waits for a small cushion before\n  /// resuming instead of repeatedly stuttering frame-by-frame.\n', '/// Uses Debrify\'s vetted Large/Extended cloud-VOD profile: two minutes of\n  /// read-ahead plus reconnect tolerance, without forcing cache-pause.\n')
p.write_text(s, encoding='utf-8')

# Bump version and changelog.
p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8').replace('version: 0.4.0+16', 'version: 0.4.1+17')
p.write_text(s, encoding='utf-8')

p = Path('CHANGELOG.md')
s = p.read_text(encoding='utf-8')
entry = '''## v0.4.1 — source ranking, broader Torrentio results & smoother huge-file playback\n\n- Fixed Torrentio resolution detection by parsing stream `name`, `title`, and filename hints together; Torrentio commonly places resolution in `name` rather than `title`.\n- Added release-source classification (`REMUX`, `BluRay`, `WEB-DL`, `WEBRip`, `HDTV`, `DVD`, `CAM`).\n- Default source ranking is now strict **release quality → resolution → seeders → file size**.\n- Added fully customizable drag-to-reorder source priority in both the source picker and Source Engine settings.\n- Limited Torrentio Lite / `limit=` profiles are automatically supplemented with a broad request and merged/de-duplicated, so legacy one-result-per-quality profiles no longer starve Pikora's result list.\n- Huge PikPak remuxes now prefer a cloud transcode, with 70GB-class files biased toward a safer 1080p rendition before falling back to the raw origin.\n- Restored patched media_kit's native Windows decoder defaults instead of forcing `auto-safe`.\n- Replaced the always-on 512MiB/300s/cache-pause profile with Debrify's vetted Large + Extended network profile (256MiB/120s + reconnect), avoiding repeated visible cache-pause stalls.\n\n'''
s = s.replace('# Pikora Changelog\n\n', '# Pikora Changelog\n\n' + entry)
p.write_text(s, encoding='utf-8')
