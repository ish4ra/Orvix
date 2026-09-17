from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {text.count(old)}")
    return text.replace(old, new, 1)


def sub_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return updated


# ---------------------------------------------------------------------------
# Account sync UX: visible progress + timeout instead of looking frozen forever.
# ---------------------------------------------------------------------------
account_path = Path('lib/screens/account_screen.dart')
account = account_path.read_text(encoding='utf-8')
account = replace_once(
    account,
    "  bool _busy = false;\n  bool _signUp = false;\n",
    "  bool _busy = false;\n  bool _syncing = false;\n  bool _signUp = false;\n",
    'account syncing field',
)

new_sync = r'''  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _busy = true;
      _syncing = true;
      _message = 'Syncing your Orvix data…';
    });
    try {
      await OrvixAccountService.mergeCloudIntoLocal()
          .timeout(const Duration(seconds: 20));
      if (mounted) {
        final now = DateTime.now();
        final minute = now.minute.toString().padLeft(2, '0');
        setState(() => _message = 'Sync complete • ${now.hour}:$minute');
        widget.onAuthChanged();
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _message =
              'Cloud sync timed out after 20 seconds. Your local data is safe; try again when the connection is stable.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Sync failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _syncing = false;
        });
      }
    }
  }
'''
account = sub_once(
    account,
    r"  Future<void> _syncNow\(\) async \{.*?\n  \}\n\n  Future<void> _signOut",
    new_sync + "\n  Future<void> _signOut",
    'account sync method',
)

account = replace_once(
    account,
    """            FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Sync now'),
            ),
""",
    """            FilledButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: _syncing
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(_syncing ? 'Syncing…' : 'Sync now'),
            ),
""",
    'account sync button',
)
account_path.write_text(account, encoding='utf-8')


# ---------------------------------------------------------------------------
# Stremio metadata: modern addons frequently use meta.links for cast/director.
# Parse those links instead of relying only on deprecated cast/director fields.
# ---------------------------------------------------------------------------
model_path = Path('lib/models/media_item.dart')
model = model_path.read_text(encoding='utf-8')
model = replace_once(
    model,
    """    final rawGenres = json['genres'];
    final genres = rawGenres is List
        ? rawGenres
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
""",
    """    final rawGenres = json['genres'];
    final legacyGenres = rawGenres is List
        ? rawGenres
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final linkedGenres = _linkNames(json['links'], const {'genre'});
    final genres = legacyGenres.isNotEmpty ? legacyGenres : linkedGenres;
""",
    'metadata genres links fallback',
)
model = replace_once(
    model,
    """    final cast = _stringList(json['cast']);
    final directors = _stringList(json['director'] ?? json['directors']);
""",
    """    final legacyCast = _stringList(json['cast']);
    final linkedCast = _linkNames(json['links'], const {'actor', 'cast'});
    final cast = legacyCast.isNotEmpty ? legacyCast : linkedCast;

    final legacyDirectors =
        _stringList(json['director'] ?? json['directors']);
    final linkedDirectors =
        _linkNames(json['links'], const {'director'});
    final directors =
        legacyDirectors.isNotEmpty ? legacyDirectors : linkedDirectors;
""",
    'metadata cast director links fallback',
)
model = replace_once(
    model,
    """  static List<String> _stringList(dynamic value) {
""",
    """  static List<String> _linkNames(dynamic value, Set<String> categories) {
    if (value is! List) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final entry in value) {
      if (entry is! Map) continue;
      final category = entry['category']?.toString().trim().toLowerCase() ?? '';
      if (!categories.contains(category)) continue;
      final name = entry['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (seen.add(key)) out.add(name);
    }
    return out;
  }

  static List<String> _stringList(dynamic value) {
""",
    'metadata link helper',
)
model_path.write_text(model, encoding='utf-8')


# ---------------------------------------------------------------------------
# Details page: fill the large empty area with metadata and pinned-source state.
# ---------------------------------------------------------------------------
details_path = Path('lib/screens/details_screen.dart')
details = details_path.read_text(encoding='utf-8')
details = replace_once(
    details,
    """                  SliverToBoxAdapter(child: _hero(item)),
                  if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
""",
    """                  SliverToBoxAdapter(child: _hero(item)),
                  SliverToBoxAdapter(child: _metadataSection(item)),
                  if (item.kind == MediaKind.series && item.episodes.isNotEmpty)
""",
    'details metadata section sliver',
)

metadata_method = r'''  Widget _metadataSection(MediaItem item) {
    final hasCredits = item.cast.isNotEmpty || item.directors.isNotEmpty;
    final hasFacts = item.country?.trim().isNotEmpty == true ||
        item.certification?.trim().isNotEmpty == true ||
        item.genres.isNotEmpty;
    final pinKey = widget.sources.sourceTargetKey(item);

    return FutureBuilder<String?>(
      future: widget.sources.getPinnedSourceIdentity(pinKey),
      builder: (context, snapshot) {
        final pinned = snapshot.data;
        if (!hasCredits && !hasFacts && (pinned == null || pinned.isEmpty)) {
          return const SizedBox.shrink();
        }

        final provider = pinned == null || pinned.isEmpty
            ? null
            : pinned.split('|').first.trim();
        final providerLabel = provider == null || provider.isEmpty
            ? null
            : '${provider[0].toUpperCase()}${provider.substring(1)}';

        return Padding(
          padding: const EdgeInsets.fromLTRB(40, 18, 40, 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pinned != null && pinned.isNotEmpty) ...[
                  Container(
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
                              const Text(
                                'Pinned source',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item.kind == MediaKind.series
                                    ? '${providerLabel ?? 'Pinned provider'} is preferred across this series when a matching release is available.'
                                    : '${providerLabel ?? 'Pinned provider'} is preferred for this title.',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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

'''
details = replace_once(
    details,
    "  Widget _episodeSection(MediaItem item) {\n",
    metadata_method + "  Widget _episodeSection(MediaItem item) {\n",
    'details metadata widget',
)
details_path.write_text(details, encoding='utf-8')
