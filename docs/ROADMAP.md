# Orvix Roadmap

## v0.5 — Multi-cloud desktop release

### Product / UI

- [x] Flutter/Dart desktop application
- [x] Orvix rebrand in the active Flutter UI
- [x] Orvix icon asset
- [x] cinematic Home/Search/details experience
- [x] local Library
- [x] Watchlist and Continue Watching
- [x] customizable Home rows
- [x] user-configured Stremio-compatible source providers
- [x] built-in media_kit/libmpv player

### PikPak

- [x] captcha-aware sign-in foundation
- [x] secure token/device storage
- [x] cloud library browsing
- [x] cloud-first playback matching
- [x] source-to-cloud task bridge
- [x] task polling and playback handoff

### TorBox

- [x] TorBox service layer
- [x] API-key authentication
- [x] device authorization flow
- [x] torrent + web-download library browsing
- [x] magnet/direct-link submission
- [x] task polling
- [x] playable-file selection
- [x] playback URL handoff
- [x] preferred-cloud setting
- [ ] validate all TorBox flows against production accounts and edge cases
- [ ] improve exact episode/file matching for large season packs

### Windows packaging

- [x] Flutter Windows release build
- [x] Orvix icon generation configuration
- [x] Inno Setup definition
- [x] portable ZIP packaging workflow
- [x] installer EXE packaging workflow
- [x] tag-based GitHub Release publishing path
- [ ] validate a clean end-to-end packaged v0.5 artifact
- [ ] code signing when a certificate is available
- [ ] decide/update strategy for automatic updates

### Repository cleanup

- [x] active development branch: `orvix-v0.5.0-dev`
- [x] remove one-time upgrade-patch behavior from active validation CI
- [ ] add/update v0.5 user-facing changelog section
- [ ] archive or remove obsolete Pikora/Go prototype files when no longer needed
- [ ] decide when Orvix becomes the default branch/repository identity

## v0.6 — Desktop polish

- [ ] richer transfer/task management
- [ ] cloud-provider health/status indicators
- [ ] improved error reporting and recovery
- [ ] subtitle styling/sync improvements
- [ ] player mini controls
- [ ] optional crash/error reporting
- [ ] auto-update strategy

## v1.0 — Android / Android TV

- [ ] Android phone/tablet build
- [ ] Android TV layout and D-pad navigation
- [ ] Android secure credentials
- [ ] background transfers/downloads
- [ ] Android media session / picture-in-picture
- [ ] TV-friendly player controls

Native Kotlin modules should be introduced only for Android-specific capabilities where Flutter plugins are insufficient.
