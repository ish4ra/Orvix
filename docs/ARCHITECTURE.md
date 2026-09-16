# Orvix Architecture

Orvix is a PikPak-first media hub. The long-term goal is a single product experience across Windows and Android, with Windows shipping first.

## Direction from v0.3

The v0.2 Go prototype proved the PikPak and catalog flow, but its UI depended on launching Microsoft Edge in app mode. From v0.3 onward, Orvix is being rebuilt in **Flutter/Dart** so the same application code can target Windows first and Android/Android TV later without rewriting the product from scratch.

The design is inspired by the product shape of apps such as Debrify, but Orvix is a clean implementation focused primarily on PikPak rather than a multi-debrid provider matrix.

## Product layers

```text
UI
├─ Home / Discover
├─ Search + 2-character type-ahead
├─ Movie / TV detail
├─ Seasons / Episodes
├─ Watchlist / Continue Watching
├─ PikPak Library
└─ Settings / Account

Domain
├─ CatalogService
├─ SourceResolver
├─ LibraryMatcher
├─ PlaybackCoordinator
└─ WatchStateStore

Providers
├─ Metadata / catalog provider
├─ PikPak account provider
├─ PikPak cloud library provider
└─ Optional user-configured source providers

Platform
├─ Secure credential/token storage
├─ HTTP client
├─ Windows player integration
└─ Android player integration (later)
```

## PikPak flow

1. User signs in from the Orvix UI.
2. Orvix obtains and refreshes PikPak authentication/captcha tokens.
3. Orvix can browse the user's PikPak cloud files and folders.
4. Selecting a movie or episode first checks the user's PikPak cloud for a matching playable file.
5. A source resolver may then query only source providers configured by the user and authorized for their use.
6. If a valid source is available, the provider can hand it to PikPak and Orvix tracks the cloud task until it is playable.
7. Playback opens in Orvix's built-in player.

Orvix will not ship a hard-coded list of piracy torrent sites or bundled infringing source configurations. The source layer is intentionally pluggable so legitimate/self-hosted/user-authorized sources can be added without changing the core application.

## Authentication

PikPak uses device identity plus captcha/shield tokens around sign-in and many drive operations. Orvix stores long-lived tokens and device state in secure storage and refreshes tokens when possible instead of repeatedly asking for the user's password.

The password should not be persisted by default.

## Catalog

The catalog layer is independent of PikPak. This is important: a title can appear in Home/Search even when it is not currently present in the user's PikPak library.

The catalog API must support:

- movies and TV series
- poster/backdrop metadata
- search suggestions after 2+ typed characters
- seasons and episodes
- trending/popular rails
- stable IDs used for watch state and matching

## Playback

The planned player layer is based on `media_kit` / libmpv so the same product can support Windows and Android with:

- MKV/MP4 and common codecs
- selectable audio/subtitle tracks
- external subtitles
- resume position
- next episode
- playback speed
- hardware decoding where supported

## Cross-platform plan

### Windows

Flutter desktop app, self-contained UI. No dependency on the Edge browser executable.

### Android / Android TV

Reuse the Dart domain/services layer and most UI code. Add Android-specific storage, background download and TV/D-pad adaptations only where required.

A separate Kotlin rewrite is therefore not the default plan. Native Kotlin modules can still be added for Android-only capabilities when Flutter plugins are insufficient.

## Legacy

The Go v0.2 prototype remains in the repository for reference while the Flutter v0.3 branch is developed. It is not the target architecture for future releases.
