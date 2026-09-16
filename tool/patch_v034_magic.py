from pathlib import Path

p = Path('lib/services/pikpak_transfer_service.dart')
text = p.read_text(encoding='utf-8')
old = """      queryParameters: const {
        'usage': 'FETCH',
        'thumbnail_size': 'SIZE_LARGE',
        'with_audit': 'true',
      },"""
new = """      queryParameters: const {
        'usage': 'FETCH',
        '_magic': '2021',
        'thumbnail_size': 'SIZE_LARGE',
        'with_audit': 'true',
      },"""
if old not in text:
    raise SystemExit('PikPak file-details query marker not found')
p.write_text(text.replace(old, new, 1), encoding='utf-8')

p = Path('pubspec.yaml')
text = p.read_text(encoding='utf-8')
if 'version: 0.3.4+9' not in text:
    raise SystemExit('unexpected pubspec version')
p.write_text(text.replace('version: 0.3.4+9', 'version: 0.3.4+10', 1), encoding='utf-8')

p = Path('CHANGELOG.md')
text = p.read_text(encoding='utf-8')
needle = '- Reworked PikPak rendition selection to follow Debrify/PikPak semantics: `is_default` first, then `is_origin`, then the first usable media link, with `web_content_link` only as fallback.\n'
extra = '- Aligned PikPak file-detail requests with Debrify by adding the `_magic=2021` parameter alongside `usage=FETCH`, `thumbnail_size=SIZE_LARGE`, and `with_audit=true` when resolving streaming URLs.\n'
if extra not in text:
    if needle not in text:
        raise SystemExit('v0.3.4 changelog marker not found')
    text = text.replace(needle, needle + extra, 1)
p.write_text(text, encoding='utf-8')
