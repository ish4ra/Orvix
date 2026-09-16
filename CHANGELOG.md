# Pikora Changelog

This file tracks user-visible changes to Pikora. GitHub Releases are published automatically for new packaged versions starting with v0.3.2.

## v0.3.7 — richer source browser & quality-first ranking

- Source cards now surface parsed seeder counts and file sizes before the release name.
- Default ranking is strict `quality → seeders → file size` priority.
- Added live Quality / Seeders / File size sorting directly inside the source picker; the selected mode is remembered.
- Removed the 30-row source display cap; every unique result returned by configured providers is shown.
- Expanded Stremio/Torrentio parsing for seed-count variants, GiB/TiB sizes, comma decimals, behavior hints, and alternate size fields.
- Keeps identical resources from different configured providers as separate rows so provider-specific metadata is preserved.

## v0.3.6 — Smooth huge-file streaming

- Added PikPak Auto rendition selection for huge/high-bitrate files. Files around 24 GiB+ (or UHD/high-bitrate origins) now prefer a visible cloud transcode instead of forcing the raw remux when PikPak provides a suitable rendition.
- Auto mode prefers known transcodes up to 30 Mbps, choosing the highest usable resolution up to 2160p; if PikPak does not provide a suitable transcode, playback falls back to the provider default/origin path.
- Restored mpv `auto-safe` direct hardware decoding on Windows. v0.3.5's `auto-copy-safe` path prevented crashes but could become a throughput bottleneck on 4K HEVC because decoded frames are copied back through system RAM.
- Increased forward packet cache from 256 MiB to 512 MiB and raised cloud VOD read-ahead to 300 seconds where bitrate/byte limits allow.
- Enabled explicit mpv network caching, demuxer prefetching, controlled rebuffer recovery, a 60-second network timeout, and FFmpeg reconnect handling for temporary 5xx/network drops.
- Retains Debrify's patched media_kit/media_kit_video packages for safer Windows native renderer teardown.

## v0.3.5 — 4K stability, safer Windows decode & PikPak file sizes

- Switched Windows playback to mpv `auto-copy-safe` hardware decoding to keep GPU decode while avoiding fragile direct decoder-surface interop on difficult high-bitrate HEVC/Dolby Vision files.
- Added Debrify's vetted `Large` VOD read-ahead values (`256MiB`, `120s`) without the aggressive `cache-pause`/`cache-pause-initial` behavior that regressed startup in v0.3.3.
- Pinned Debrify's patched `media_kit` and `media_kit_video` packages at commit `709eca3a0828f2b5bfdaf153ab6a0c00a89c5f2d`, including its desktop-safe native player/render-context teardown work.
- My PikPak now shows human-readable file sizes next to each file's MIME type.
- Retains v0.3.4's Debrify-aligned PikPak `usage=FETCH&_magic=2021` request and provider-selected media ordering.

## v0.3.4 — Debrify-aligned PikPak playback

- Reworked PikPak rendition selection to follow Debrify/PikPak semantics: `is_default` first, then `is_origin`, then the first usable media link, with `web_content_link` only as fallback.
- Aligned PikPak file-detail requests with Debrify by adding the `_magic=2021` parameter alongside `usage=FETCH`, `thumbnail_size=SIZE_LARGE`, and `with_audit=true` when resolving streaming URLs.
- Removed Pikora's custom "highest transcode up to 1080p" selection that could choose a non-default/broken PikPak rendition.
- Removed always-on mpv cache/reconnect overrides. The default playback path now uses stock media_kit/libmpv behavior, matching Debrify's `Standard` network preset.
- Removed the custom forced `hwdec` VideoController configuration from the default path and returned to the stock controller setup used by Debrify on desktop.
- Added a 12-second startup watchdog: a VOD stream that remains at `0:00 / 0:00` is reported as a stream-start failure instead of showing an endless buffering spinner.
- Kept v0.3.3's exact `fileIdx`/torrent-child routing, so this playback alignment does not reintroduce cross-source or wrong-episode matching.

## v0.3.3 — Exact episode routing & smoother PikPak playback

- Preserves Stremio torrent `fileIdx`, filename hints, and video-size metadata instead of discarding them.
- Resolves the exact video inside PikPak multi-file torrents/season packs after a cloud task completes.
- Prevents a newly selected source from accidentally falling back to an older matching 4K/3D file elsewhere in the PikPak library when the task output is a folder.
- Uses PikPak `original_file_index`, filename, and size to identify the intended child file, with largest-video fallback only inside the selected task output.
- Prefers a visible PikPak transcoded rendition up to 1080p for smooth default playback before falling back to the original/raw file.
- Enables media_kit hardware acceleration explicitly and adds initial/rebuffer cache tuning for cloud VOD.
- CI now cancels superseded Windows builds so rapid incremental commits cannot overwrite an older release's assets.

## v0.3.2 — Catalog clarity & release history

- Re-ranked search results so an exact title match wins over similarly named remakes/spin-offs.
- Added clear `UPCOMING` labeling for unreleased movies and series.
- Upcoming titles are also identified directly in the details metadata.
- Added automated GitHub Release publishing with Windows installer and portable ZIP assets.
- Added this changelog so the project's improvement history is visible in the repository.

## v0.3.1 — Sources & large-file playback

- Integrated the existing Torrentio-compatible provider configuration into Pikora's Sources experience.
- Migrates an existing Torrentio-compatible URL from the old manual provider list automatically.
- Added persistent source sorting by:
  - seeders,
  - file size,
  - quality.
- Added quality, seed-count, and file-size parsing for source results.
- Improved source result cards and Quick Play ordering.
- Changed PikPak playback URL selection to prefer PikPak `medias` streaming links before `web_content_link` fallback.
- Added larger mpv read-ahead/cache settings and reconnect/network timeout tuning for cloud VOD playback.
- Fixed the Windows build after the new Sources UI introduced an unsupported Flutter icon name.

## v0.3.0 — Flutter MVP

- Rebuilt Pikora as a Flutter desktop application.
- Cinematic dark UI for Home, Search, Movies/TV discovery, details, and episodes.
- Cinemeta-powered catalog metadata.
- PikPak sign-in, cloud task handling, library matching, and playback flow.
- Stremio-compatible source-provider support.
- Built-in media_kit/libmpv playback.
- Windows x64 portable build and Inno Setup installer through GitHub Actions.

## Versioning policy

- Patch releases (`0.3.x`) contain fixes and incremental UX/playback improvements.
- Each packaged release should include a Windows installer and portable ZIP.
- User-facing changes should be recorded here before a release is published.
