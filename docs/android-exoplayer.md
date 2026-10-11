# Android ExoPlayer (Media3)

Orvix's Android player engines are MPV (media_kit/libmpv) and ExoPlayer
(Android Media3). This page describes how ExoPlayer is wired, which engine
each Android product uses, what the player supports, and the conditions for
moving Android Mobile to ExoPlayer.

## Engine defaults

| Product | Auto (no saved choice) | Manual choices |
| --- | --- | --- |
| Android TV | ExoPlayer | ExoPlayer, MPV |
| Android Mobile | MPV (temporary) | ExoPlayer, MPV |
| Windows, macOS, iOS | MPV (unchanged) | — |

- With AI Sinhala on, Free P2P playback uses MPV whatever the choice (the
  progressive native-cue pipeline lives in the MPV player). AI Sinhala does
  not run on cloud/debrid sources played from a title page, so those follow
  the normal engine choice (ExoPlayer under TV Auto).
- Android TV and Android Mobile store their choices separately
  (`orvix_player_engine_android_tv_v2`, `orvix_player_engine_android_mobile_v2`).
  A choice saved by v0.7.9 or earlier (`orvix_player_engine_v1`) is still
  honoured on both until the user picks again; it is never rewritten.
- The defaults live in `AndroidPlayerDefaults` in
  `lib/services/player_engine_preferences_service.dart`.
- No automatic engine switch: when ExoPlayer cannot play a stream its error
  screen offers **Try MPV**, **Retry** and **Details**. The existing
  MPV-to-ExoPlayer startup hand-off on Android Mobile Auto is unchanged and
  is not used when ExoPlayer was tried first.

### Moving Android Mobile to ExoPlayer (not done yet)

This is one separately reviewed change: set `AndroidPlayerDefaults.mobileAuto`
to `PlayerEngineKind.exoPlayer`, update the Settings caption and the
`player_engine_router_test.dart` expectation, and ship it as its own beta.
Manual MPV stays available. Do it only after the owner confirms, on real
phones, that ExoPlayer:

1. starts and keeps playing Free P2P (including slow swarms), Real-Debrid,
   TorBox, PikPak and Premiumize sources that MPV plays;
2. opens in landscape fullscreen and returns to the normal app afterwards,
   including after Back, Home and returning to the app;
3. shows embedded, OpenSubtitles and file subtitles, with style and timing
   changes taking effect;
4. switches audio tracks;
5. shows Fit, Fill and Zoom correctly on 16:9, 2.39:1 and 4:3 sources;
6. seeks reliably and recovers from buffering;
7. leaves MPV playback unchanged when MPV is chosen.

## Playback path

```
source → URL (Free P2P: http://127.0.0.1:11470/<hash>/<file>;
              cloud/debrid: local range bridge http://127.0.0.1:<port>/media/…)
       → AndroidExoPlayerScreen → OrvixExoController (Dart)
       → "orvix/exo_player" method channel
       → OrvixExoPlayerChannel / OrvixExoSession (tools/android/OrvixExoPlayer.kt)
       → DefaultHttpDataSource (+ TransferListener) → DefaultMediaSourceFactory
       → ExoPlayer (MediaCodec decoders, decoder fallback on)
       → Flutter SurfaceProducer texture → Texture widget
```

The Android project is generated in CI; `tools/configure_android_build.py`
copies the Kotlin bridge into it, adds `media3-exoplayer:1.9.2` (the same
version `video_player_android` uses, which also brings the HLS, DASH and
SmoothStreaming modules) and passes the activity so the bridge can keep the
screen on while playing.

## Startup and errors

- Free P2P: Media3 retries slow reads for as long as the player is open
  (`PatientLoadErrorPolicy`); the screen reopens the same stream after errors
  a slow swarm causes and only fails on real evidence (a non-transient error,
  or the torrent engine not answering on two checks).
- Remote streams: there is **no fixed startup deadline**. Media3's
  connect/read timeouts and retry policy decide when a source is dead. After
  20 s the loading text says the source is slow; the user can wait or go Back.
- Stages shown while loading: connecting (no bytes yet) → loading video
  (bytes arriving) → starting playback (decoder ready) → playing.
- Errors are classified as network, source (HTTP status), format, decoder,
  audio output, DRM or lifecycle (`ExoErrorClassifier`).

### Diagnostics

Player settings → Playback info shows the engine, source kind, stage, codec,
decoder names, bytes received, HTTP status, first-frame time, dropped frames,
retried loads and the last error, and copies a report. The same timeline is
written to logcat with the `[orvix-exo]` prefix:

```
adb logcat | grep orvix-exo
```

Neither contains URLs, request headers, info hashes, magnets or tokens.

## Subtitles

| Format | ExoPlayer | Notes |
| --- | --- | --- |
| SRT, WebVTT (embedded in MKV/MP4) | Yes | Styled by Orvix |
| ASS/SSA (embedded) | Text only | Positioning, fonts and effects of the file are not rendered; Orvix's style is used |
| TTML, CEA-608/708 | Yes | Text |
| PGS, VobSub (DVD), DVB | Yes | Shown as images at the file's position; text style does not apply |
| External SRT, WebVTT, ASS/SSA files, OpenSubtitles | Yes | Parsed and timed in Dart; ASS as text |
| AI Sinhala | MPV only | Free P2P with AI Sinhala on is routed to MPV |

Style settings (all applied to the rendered subtitles, saved between
sessions): size, font (Default, Sans serif, Serif, Monospace, Condensed,
Casual — all fall back to the bundled Noto Sans Sinhala), weight, text color
and opacity, edge style (none, outline, drop shadow, raised, depressed), edge
color, outline thickness, shadow intensity, line background on/off, color and
opacity, window color and opacity, distance from the bottom, alignment, line
spacing, reset. Size, line background and position are shared with MPV.

Timing: ±0.25 s steps, positive is later, kept across seeks and reopened
streams, Reset timing returns to 0. Audio delay is not offered.

## Picture

Fit (whole picture), Fill (covers the screen and crops, never stretches),
Zoom (Fit enlarged by an adjustable 105–200 %). The decoded size includes the
pixel aspect ratio, so anamorphic video keeps its shape; rotation metadata is
applied. The mode and zoom level are saved.

## Known limitations

- ExoPlayer uses the device's hardware decoders. Formats a device cannot
  decode (for example H.264 High 10 "Hi10P", some HEVC Main 10 profiles on
  older devices, TrueHD/DTS on many phones) fail with a "format not
  supported" error or play without that audio track; MPV decodes them in
  software.
- MKV files whose index sits at the end need the end of the file before
  playback starts; on a torrent this can add a short delay that MPV does not
  have.
- ASS/SSA styling and positioning are not rendered.
- Automated tests cover the Dart player, the routing and the native/Dart
  contract; Media3 itself is only exercised on real devices.
