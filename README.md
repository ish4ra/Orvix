# Pikora

Pikora is a **PikPak-first cinematic media hub** for browsing movies and TV, connecting your PikPak cloud, resolving user-configured sources, and playing media inside one app.

## Active development — v0.3 Flutter branch

The original v0.2 Go prototype proved the catalog/PikPak idea, but its UI depended on Microsoft Edge app mode. That prototype remains on `main` for reference.

Active development is now on **`v0.3-flutter`**.

Pikora is being built in Flutter/Dart now so Windows, Android and Android TV can share the same catalog, PikPak, source-resolution and playback code. Android-specific Kotlin can be added later where native services are genuinely useful.

## v0.3 features in progress

- native Flutter Windows UI — **no Microsoft Edge browser dependency**
- cinematic dark Home screen with Popular Movies, Popular TV and Top Rated rails
- Movies + TV instant search after 2 typed characters
- rich movie/TV detail screens
- TV seasons and episode lists from Cinemeta metadata
- PikPak captcha-aware sign-in and secure token/device storage
- PikPak folder browsing
- title/episode matching against the connected PikPak library
- user-configured **Stremio-compatible source providers**
- provider result → PikPak cloud-task bridge
- polling while PikPak prepares a newly added item
- automatic transition to playback when the cloud file is ready
- built-in **media_kit / libmpv** player
- GitHub Actions Windows release build

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
Choose returned source
      ↓
Send source to PikPak
      ↓
Wait for PikPak cloud preparation
      ↓
Match the new cloud file
      ↓
Resolve streaming URL
      ↓
libmpv player
```

Pikora does not bundle a hard-coded torrent-site/indexer list or a preconfigured infringing source configuration. Source providers are added by the user and should only be used for content and services they are authorized to access.

## Source providers

The Sources screen accepts a Stremio-compatible addon base URL or `manifest.json` URL. Pikora stores the configured provider list locally and can query its standard stream endpoint for a selected movie or episode.

The resolver currently understands:

- direct HTTP/HTTPS stream URLs
- Stremio stream results containing an `infoHash`, converted into a magnet resource for PikPak

## Built-in player

Pikora uses `media_kit` / libmpv for playback. This provides the foundation for:

- MKV/MP4 and broad codec support
- audio-track selection
- subtitle-track selection
- hardware-accelerated playback where available
- seeking, playback speed and fullscreen controls
- later subtitle search and resume/continue-watching support

## Build v0.3

```bash
git checkout v0.3-flutter
flutter pub get
flutter create --platforms=windows --project-name pikora .
flutter run -d windows
```

Release build:

```bash
flutter build windows --release
```

GitHub Actions also produces a Windows x64 ZIP artifact for pushes to `v0.3-flutter`.

## Roadmap

Immediate desktop milestones:

1. harden PikPak login/captcha and cloud-task polling against real accounts
2. improve automatic title/episode matching and file selection
3. player audio/subtitle picker, subtitle styling, fullscreen polish and keyboard shortcuts
4. Continue Watching, watchlist and playback history
5. source-provider health/status and provider ordering
6. better task/download progress UI
7. Windows installer/release packaging

After the Windows flow is stable:

- Android phone build
- Android TV / D-pad-first layout
- background cloud/download integration where appropriate
- Kotlin platform modules only for Android features that need native APIs

## Inspiration and licensing

Apps such as Debrify demonstrate this product category across desktop, mobile and TV. Pikora is its own PikPak-focused implementation rather than a copy of Debrify source. Debrify is AGPL-3.0-only, so its code is treated as an architecture/product reference unless Pikora explicitly adopts AGPL-compatible reuse later.

## Notes

- PikPak integration relies on community-observed/undocumented web endpoints and may require maintenance if PikPak changes authentication, captcha or drive APIs.
- Pikora does not persist the PikPak password by default.
- Catalog metadata is independent from the user's PikPak cloud library.
