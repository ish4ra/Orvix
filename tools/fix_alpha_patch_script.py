from pathlib import Path

path = Path('tools/apply_alpha_subtitle_hardening.py')
text = path.read_text(encoding='utf-8')

old_join = ".join('\\n')"
new_join = ".join('\\\\n')"
if old_join not in text:
    raise SystemExit('join escape marker not found')
text = text.replace(old_join, new_join, 1)

old_timer = '''player = player.replace(
    "    _startupTimer?.cancel();\\n",
    "    _startupTimer?.cancel();\\n    _nativeSubtitleClockTimer?.cancel();\\n",
    1,
)'''
new_timer = '''player = player.replace(
    "    _startupTimer?.cancel();\\n    _completedSubscription?.cancel();\\n",
    "    _startupTimer?.cancel();\\n    _nativeSubtitleClockTimer?.cancel();\\n    _completedSubscription?.cancel();\\n",
    1,
)'''
if old_timer not in text:
    raise SystemExit('timer patch marker not found')
text = text.replace(old_timer, new_timer, 1)

path.write_text(text, encoding='utf-8')
print('Fixed patch script escaping and timer cleanup target.')
