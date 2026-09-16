# Orvix

Orvix is a **multi-cloud cinematic media hub** built with Flutter. It combines movie/TV discovery, user-configured source providers, PikPak and TorBox cloud accounts, and built-in media playback in one native application.

## Active development — v0.5

Current development is on **`orvix-v0.5.0-dev`**. The older Go prototype on `main` remains only as historical reference; the active product is the Flutter/Dart application under `lib/`.

Current package version: **0.5.0**.

## Current v0.5 foundation

- native Flutter Windows UI
- cinematic dark Orvix branding and Windows icon asset
- Movies + TV discovery and instant search
- movie/series detail pages with seasons and episodes
- local Library, Watchlist and Continue Watching state
- customizable Home rows
- user-configured Stremio-compatible source providers
- source quality/ranking controls
- PikPak sign-in, library browsing and cloud-transfer flow
- TorBox API-key and device-login connection flows
- TorBox torrent/web-download library browsing
- selectable preferred cloud: PikPak or TorBox
- source → preferred cloud transfer bridge
- cloud-task progress polling and playback handoff
- built-in `media_kit` / libmpv player
- audio/subtitle track selection, external subtitles, resume and fullscreen controls
- Windows x64 portable ZIP and Inno Setup installer pipeline

## Playback flow

```text
Home / Search
      ↓
Movie or TV detail
      ↓
Movie Play / Episode Play
      ↓
Check preferred connected cloud
      ↓
Already available? ── yes ──→ Resolve playable URL ──→ libmpv player
      │
      no
      ↓
Query user-configured source providers
      ↓
Choose / Quick Play source
      ↓
Send resource to PikPak or TorBox
      ↓
Poll cloud task until playable
      ↓
Resolve selected video file
      ↓
libmpv player
```

Orvix does not bundle a hard-coded torrent-site/indexer list or a preconfigured infringing source configuration. Source providers are user-configured and should be used only for content and services the user is authorized to access.

## Tech stack

- Flutter / Dart
- Material 3
- `media_kit` / libmpv
- `flutter_secure_storage`
- `shared_preferences`
- `http`
- `cached_network_image`
- `window_manager`
- Inno Setup for Windows installer packaging
- GitHub Actions for Windows validation/build artifacts

Orvix currently pins reviewed Debrify media_kit patches for desktop player stability; see `pubspec.yaml` for the exact commit.

## Windows development build

```bash
git checkout orvix-v0.5.0-dev
flutter create --platforms=windows --project-name orvix .
flutter pub get
dart run flutter_launcher_icons
flutter run -d windows
```

Release build:

```bash
flutter build windows --release
```

The Windows GitHub Actions pipeline creates both a portable ZIP and an Inno Setup installer. A tag matching the `pubspec.yaml` version, for example `v0.5.0`, can publish those assets as a GitHub Release.

## Repository layout

```text
lib/                 active Flutter application
assets/branding/     Orvix visual assets
installer/           Windows Inno Setup definition
docs/                architecture and roadmap
.github/workflows/   validation and Windows packaging
ui/ + *.go           legacy v0.2 prototype retained for reference
```

## Current focus before v0.5 release

1. validate TorBox login, library, transfer and playback flows against real accounts
2. harden cloud matching for season packs and multi-file torrents
3. finish Windows packaging/release validation
4. update user-facing changelog and release notes
5. remove or archive legacy prototype code once it is no longer useful for reference

## Future platforms

The Flutter services/domain layer is intended to support Android phone/tablet and Android TV later. Platform-specific Kotlin should be added only where native Android integration is actually required.
