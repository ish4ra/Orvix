from pathlib import Path

p = Path('lib/services/pikpak_transfer_service.dart')
s = p.read_text(encoding='utf-8')
start = s.index('  _ResourceEnvelope _extractResourceEnvelope(String resource) {')
end = s.index('  Future<_Session> _session() async {', start)
replacement = r'''  _ResourceEnvelope _extractResourceEnvelope(String resource) {
    final trimmed = resource.trim();
    if (!trimmed.toLowerCase().startsWith('magnet:')) {
      return _ResourceEnvelope(resource: trimmed);
    }

    try {
      final question = trimmed.indexOf('?');
      if (question < 0 || question == trimmed.length - 1) {
        throw const PikPakTransferException(
          'Invalid magnet source returned by provider.',
        );
      }

      final rawParts = trimmed.substring(question + 1)
          .split('&')
          .where((part) => part.trim().isNotEmpty)
          .toList(growable: false);

      int? fileIndex;
      String? fileName;
      int? videoSize;
      String? infoHash;
      final cleanParts = <String>[];

      for (final part in rawParts) {
        final equals = part.indexOf('=');
        final rawKey = equals < 0 ? part : part.substring(0, equals);
        final rawValue = equals < 0 ? '' : part.substring(equals + 1);
        final key = Uri.decodeQueryComponent(rawKey).toLowerCase();
        final value = Uri.decodeQueryComponent(rawValue);

        switch (key) {
          case 'x-orvix-file-idx':
          case 'x-pikora-file-idx':
            fileIndex ??= _parseInt(value);
            continue;
          case 'x-orvix-file-name':
          case 'x-pikora-file-name':
            fileName ??= _nonEmpty(value);
            continue;
          case 'x-orvix-video-size':
          case 'x-pikora-video-size':
            videoSize ??= _parseInt(value);
            continue;
        }

        if (key == 'xt') {
          final lower = value.toLowerCase();
          if (lower.startsWith('urn:btih:')) {
            final hash = value.substring('urn:btih:'.length).trim();
            final valid = RegExp(
              r'^(?:[A-Fa-f0-9]{40}|[A-Za-z2-7]{32}|[A-Fa-f0-9]{64})$',
            ).hasMatch(hash);
            if (valid) infoHash = hash;
          }
        }

        cleanParts.add(part);
      }

      if (infoHash == null) {
        throw const PikPakTransferException(
          'Invalid magnet source: no usable BTIH hash was returned. Choose another source.',
        );
      }

      final clean = 'magnet:?${cleanParts.join('&')}';
      final selection = fileIndex == null && fileName == null && videoSize == null
          ? null
          : _TorrentSelection(
              fileIndex: fileIndex,
              fileName: fileName,
              videoSize: videoSize,
            );
      return _ResourceEnvelope(resource: clean, selection: selection);
    } on PikPakTransferException {
      rethrow;
    } catch (_) {
      throw const PikPakTransferException(
        'Invalid magnet source returned by provider. Choose another source.',
      );
    }
  }

'''
s = s[:start] + replacement + s[end:]
s = s.replace(
    '// Source-provider metadata is kept only in memory. It lets Pikora follow the',
    '// Source-provider metadata is kept only in memory. It lets Orvix follow the')
p.write_text(s, encoding='utf-8')

p = Path('lib/services/source_provider_service.dart')
s = p.read_text(encoding='utf-8')
s = s.replace("static const _priorityKey = 'orvix_source_priority_v5';",
              "static const _priorityKey = 'orvix_source_priority_v6';")
marker = "    var visible = out;\n    if (!showLowQuality) {"
replacement = """    // Apply the quality floor BEFORE cache ranking. Cache is the first
    // ranking criterion only among sources that survive the normal quality
    // filter, so cached CAM/DVD/sub-720p rows cannot jump ahead of good HD
    // sources merely because they are cached.
    var visible = out;
    if (!showLowQuality) {"""
s = s.replace(marker, replacement)
p.write_text(s, encoding='utf-8')

p = Path('pubspec.yaml')
s = p.read_text(encoding='utf-8').replace('version: 0.5.2+22', 'version: 0.5.3+23')
p.write_text(s, encoding='utf-8')

p = Path('installer/orvix.iss')
s = p.read_text(encoding='utf-8').replace('#define MyAppVersion "0.5.2"', '#define MyAppVersion "0.5.3"')
p.write_text(s, encoding='utf-8')

p = Path('CHANGELOG.md')
s = p.read_text(encoding='utf-8')
entry = '''# Orvix Changelog\n\n## v0.5.3 — PikPak magnet reliability\n\n- Fixed Orvix source metadata not being stripped from magnet links before they were sent to PikPak.\n- Preserves genuine magnet parameters exactly, validates the BTIH hash, and rejects malformed provider magnets instead of letting PikPak save tiny `magnet...` text files.\n- Resets source priority to Cache → Quality → Resolution → Size → Seeders.\n- Low-quality filtering still runs before cache ranking, so cached CAM/DVD/sub-720p results do not outrank good HD sources.\n- Added generated Flutter metadata to `.gitignore` to prevent build output from polluting the repository again.\n\n'''
if s.startswith('# Orvix Changelog\n\n'):
    s = entry + s[len('# Orvix Changelog\n\n'):]
else:
    s = entry + s
p.write_text(s, encoding='utf-8')

p = Path('.gitignore')
s = p.read_text(encoding='utf-8')
extra = '\n.dart_tool/\n.flutter-plugins\n.flutter-plugins-dependencies\nwindows/flutter/ephemeral/\n'
if '.dart_tool/' not in s:
    s = s.rstrip() + extra
p.write_text(s, encoding='utf-8')
