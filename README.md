# Orvix

Orvix is a **PikPak-first cinematic media hub** for browsing movies and TV, connecting your PikPak cloud, resolving user-configured sources, and playing media inside one app.

## Active development — v0.3 Flutter branch

The original v0.2 Go prototype proved the catalog/PikPak idea, but its UI depended on Microsoft Edge app mode. That prototype remains on `main` for reference.

Active development is now on **`v0.3-flutter`**. Orvix is being built in Flutter/Dart so Windows, Android and Android TV can share the catalog, PikPak, source-resolution and playback code. Android-specific Kotlin can be added later only where native services are genuinely useful.

## Current v0.3 foundation

- native Flutter Windows UI — **no Microsoft Edge browser dependency**
- cinematic dark Home with Popular Movies, Popular TV, Top Rated, Continue Watching and My Watchlist
- Movies + TV instant search after 2 typed characters
- rich movie/TV detail screens with TV seasons and episodes
- PikPak captcha-aware sign-in, secure token/device storage and cloud-library browsing
- automatic title/episode matching against the connected PikPak library
- user-configured **Stremio-compatible source providers**
- quality-ranked source results with Quick Play
- provider result → PikPak cloud-task bridge
- real PikPak task phase/progress polling when a task ID is returned
- automatic transition to playback when the cloud file is ready
- built-in **media_kit / libmpv** player
- play/pause, seek, ±10s, playback speed, volume and mute controls
- embedded audio/subtitle track selection
- local SRT/ASS/SSA/VTT subtitle loading
- Windows fullscreen support and keyboard shortcuts
- resume position / Continue Watching persistence
- next-episode countdown and autoplay-next flow
- GitHub Actions Windows x64 release build

## Playback flow

```text
Home / Search
      ↓
Movie or TV detail
      ↓
Movie Play / Episode Play
      ↓
Check connected PikPak library
      ↓
Found? ── yes ──→ Resolve PikPak streaming URL ──→ libmpv player
      │
      no
      ↓
Ask user-configured source providers
      ↓
Choose / Quick Play source
      ↓
Send source to PikPak
      ↓
Poll PikPak task phase + real progress when available
      ↓
Resolve prepared cloud file
      ↓
libmpv player
      ↓
TV: next-episode countdown → resolve next episode
```

Orvix does not bundle a hard-coded torrent-site/indexer list or a preconfigured infringing source configuration. Source providers are added by the user and should only be used for content and services they are authorized to access.

## Source providers

The Sources screen accepts a Stremio-compatible addon base URL or `manifest.json` URL. Orvix stores the configured provider list locally and can query its standard stream endpoint for a selected movie or episode.

The resolver understands direct HTTP/HTTPS stream URLs and Stremio stream results containing an `infoHash`, which can be represented as a magnet resource for the connected PikPak account.

## Built-in player

Orvix uses `media_kit` / libmpv. The current desktop player includes broad container/codec support through libmpv, seeking, playback-speed control, volume/mute, fullscreen, embedded audio/subtitle switching, external subtitle files, keyboard shortcuts, resume progress and next-episode handling.

Current shortcuts:

- `Space` — play/pause
- `←` / `→` — seek 10 seconds
- `M` — mute/unmute
- `F` or `F11` — fullscreen
- `Esc` — leave fullscreen / go back

## Build v0.3

```bash
git checkout v0.3-flutter
flutter pub get
flutter create --platforms=windows --project-name orvix .
flutter run -d windows
```

Release build:

```bash
flutter build windows --release
```

GitHub Actions produces a Windows x64 ZIP artifact for pushes to `v0.3-flutter`.

## Roadmap

Immediate desktop milestones:

1. harden PikPak login/captcha against real accounts and edge cases
2. improve automatic multi-file title/episode matching
3. subtitle styling/sync and optional subtitle-provider integration
4. playback history and better Continue Watching management
5. source-provider health/status, ordering and per-provider controls
6. richer PikPak Transfers screen with active/completed/error tasks
7. Windows installer, app icon, signing/release packaging and auto-update strategy

After the Windows flow is stable:

- Android phone build from the shared Flutter/Dart codebase
- Android TV / D-pad-first layout
- Android background/media-session/PiP integration
- Kotlin modules only for Android features that genuinely need native APIs

## Inspiration and licensing

Apps such as Debrify demonstrate this product category across desktop, mobile and TV. Orvix is its own PikPak-focused implementation rather than a copy of Debrify source. Debrify is AGPL-3.0-only, so its source is treated as an architecture/product reference unless Orvix explicitly adopts AGPL-compatible reuse later.

## Notes

- PikPak integration relies on community-observed/undocumented web endpoints and may require maintenance if PikPak changes authentication, captcha or drive APIs.
- Orvix does not persist the PikPak password by default.
- Catalog metadata is independent from the user's PikPak cloud library.
