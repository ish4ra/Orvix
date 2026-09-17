from pathlib import Path

p = Path('lib/screens/player_screen.dart')
text = p.read_text(encoding='utf-8')
old_getter = "(_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-15000, 15000);"
new_getter = "(_autoSyncOffsetMs + _manualSyncOffsetMs).clamp(-15000, 15000).toInt();"
old_next = "final next = (_manualSyncOffsetMs + deltaMs).clamp(-15000, 15000);"
new_next = "final next = (_manualSyncOffsetMs + deltaMs).clamp(-15000, 15000).toInt();"
if old_getter not in text or old_next not in text:
    raise SystemExit('Expected smart-sync int clamp markers were not found')
text = text.replace(old_getter, new_getter, 1).replace(old_next, new_next, 1)
p.write_text(text, encoding='utf-8')
