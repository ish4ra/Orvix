# AI Sinhala subtitles (Beta)

Orvix can translate the currently selected text subtitle track to natural Sri Lankan Sinhala while playback is running.

## Design

- The player keeps the original embedded/external subtitle track selected so `media_kit` continues to provide timed subtitle cues.
- When **Sinhala (AI Beta)** is enabled, Orvix hides the normal subtitle renderer, listens to the current subtitle cue, sends only the cue plus a small amount of previous-dialogue context to an authenticated Supabase Edge Function, and renders the Sinhala result itself.
- Translations are cached in memory for the current playback session so repeated cues do not generate another AI request.
- If translation is delayed or unavailable, the original subtitle cue remains visible as a fallback instead of leaving the screen blank.
- The first beta translates embedded tracks and local SRT/VTT/ASS/SSA files already selectable in the player. Automatic OpenSubtitles discovery/download is planned as the next phase.

## Cloud function

`translate-subtitle-si` requires an authenticated Orvix account and a server-side `GEMINI_API_KEY` secret. The key is never shipped in the desktop app.

The function uses a low-temperature translation prompt designed for short subtitle dialogue and returns only the translated Sinhala text.
