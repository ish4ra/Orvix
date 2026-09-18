# AI Sinhala subtitles (Beta)

Orvix translates English text subtitles to natural Sri Lankan Sinhala across Windows, macOS, Android mobile and Android TV.

## Current design

- When **AI Sinhala subtitles** is enabled in Settings, English subtitles are never rendered automatically. An English track may remain selected internally only as a hidden timing source.
- Orvix prepares a release-matched subtitle timeline when possible and translates an initial buffer before later playback reaches it.
- Translation uses a sliding window around the current playback position instead of translating the entire movie or episode in the background. This reduces quota/rate-limit pressure and keeps upcoming cues ready.
- Seeking immediately prioritizes translation around the new playback position, so jumping forward does not create a permanent untranslated gap.
- Failed translation windows are retried instead of being skipped forever.
- If release-matched OpenSubtitles preparation fails but the source has an English text subtitle track, Orvix uses a live AI translation fallback from that hidden track.
- Image-based PGS/VobSub tracks can provide timing calibration but cannot provide text for the live fallback.
- Manually selecting a native subtitle or **Off** overrides AI Sinhala for that playback session; the persistent Settings preference is used again on the next playback.

## Cloud function

`translate-subtitle-si` requires an authenticated Orvix account and a server-side `GEMINI_API_KEY` secret. The key is never shipped in the app.

The function supports both buffered `segments` translation and single-cue `text` translation used by the live fallback.
