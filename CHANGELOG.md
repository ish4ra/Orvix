# Pikora Changelog

This file tracks user-visible changes to Pikora. GitHub Releases are published automatically for new packaged versions starting with v0.3.2.


## v0.3.4 — Debrify-aligned PikPak playback

- Reworked PikPak rendition selection to follow Debrify/PikPak semantics: `is_default` first, then `is_origin`, then the first usable media link, with `web_content_link` only as fallback.
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
