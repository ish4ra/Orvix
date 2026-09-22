# Orvix Stream Server Mod

Orvix currently pins upstream `stremio-native/stream-server` at:

`f585ab6eda9b1411034548c131bb0dc30c6f5f9e` (v0.1.8 lineage)

## Why this mod exists

The upstream embedded-subtitle API discovers and extracts subtitles from the
largest video file in a torrent. That is unsafe for TV season packs: Orvix may
be playing file index 4 while the largest-file heuristic probes file index 0.

The Orvix mod preserves all upstream routes and adds exact selected-file
subtitle support:

- `/subtitlesTracks?subsUrl=http://127.0.0.1:11470/<hash>/<fileIdx>`
  probes embedded subtitles from that exact `fileIdx`.
- Embedded results point to
  `/<hash>/<fileIdx>/embedded/<trackId>/subtitles.vtt`.
- `/orvix/capabilities` advertises `exactFileEmbeddedSubtitles: true` so the
  client never mistakes an unmodified upstream server for the exact-file mod.
- The exact extraction route passes both the selected video file index and
  subtitle track ID to the existing FFmpeg-based extractor.
- Requests without a selected file index keep upstream largest-file behavior
  for compatibility.

The mod is applied at build time by
`tools/patch_orvix_stream_server.py`. The script uses exact source anchors and
fails closed if the pinned upstream source changes.

## First target

Windows x64 is the first validation target because the current AI Sinhala
failure was reproduced there. Android keeps its existing Stremio native
library until the exact-file behavior is proven on Windows.

## License

Upstream stream-server is MIT licensed. Orvix retains the upstream license and
documents the modifications in `licenses/stream-server/NOTICE.md`.

## Reproducible Windows build

`.github/workflows/orvix-stream-server-windows.yml` clones the pinned upstream
commit, applies the source patch, builds the Windows x64 server with the same
libtorrent feature direction as the upstream release, smoke-tests the Orvix
capability endpoint, and publishes a pinned binary under the
`stream-server-orvix-v0.1.8.1` prerelease tag.

The Orvix app should only enable exact embedded AI subtitle extraction when the
capability endpoint and exact-response marker are both present.
