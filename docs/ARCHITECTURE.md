# Orvix Architecture

Orvix is a Flutter/Dart multi-cloud media hub. Windows is the current shipping target; Android and Android TV are planned to reuse the same domain/services layer later.

## Product layers

```text
UI
├─ Home / Discover
├─ Search
├─ Movie / TV details
├─ Seasons / Episodes
├─ Local Library / Watchlist / Continue Watching
├─ Clouds
│  ├─ PikPak
│  └─ TorBox
├─ Sources
└─ Player

Domain / services
├─ CatalogService
├─ SourceProviderService
├─ MediaStateService
├─ CloudPreferencesService
├─ PikPakService
├─ PikPakTransferService
├─ TorBoxService
└─ PlaybackService

Platform
├─ Secure credential/token storage
├─ HTTP client
├─ Shared preferences
├─ media_kit / libmpv
└─ Windows window integration
```

## Multi-cloud playback flow

1. The user selects a movie or episode.
2. Orvix reads the preferred cloud (`PikPak` or `TorBox`).
3. If that cloud is connected, Orvix checks it for an existing playable match.
4. If no suitable cloud item exists, Orvix queries user-configured source providers.
5. The chosen source is submitted to the preferred cloud.
6. Orvix polls the cloud task until the selected video is ready.
7. Orvix resolves a playable URL and hands it to the built-in player.
8. Resume/Continue Watching state is stored locally.

The source-provider layer remains user-configured. Orvix does not ship a hard-coded piracy index or preconfigured infringing source list.

## PikPak provider

PikPak support includes authentication/captcha handling, secure token/device state, cloud browsing, title/episode matching, cloud-task submission and playable rendition selection.

PikPak relies on community-observed/undocumented endpoints, so this integration may need maintenance when PikPak changes its API behavior.

## TorBox provider

TorBox support includes:

- API-key authentication
- device authorization
- account metadata
- torrent library listing
- web-download listing
- magnet submission
- direct HTTP/HTTPS resource submission
- task polling
- playable video selection
- generated download/playback URLs

Tokens are stored through secure storage rather than plain preferences.

## Catalog and state

Catalog metadata is independent from cloud storage. A title can appear in Home/Search even if it does not exist in either connected cloud.

Local state includes Library, Watchlist, Continue Watching and Home customization preferences.

## Playback

Playback uses `media_kit` / libmpv with reviewed desktop stability patches pinned in `pubspec.yaml`.

The desktop player supports common media containers/codecs, seeking, playback speed, volume/mute, fullscreen, embedded audio/subtitle tracks, external subtitle files, resume state and next-episode handling.

## Windows packaging

The Windows runner is generated from the Flutter project with project name `orvix`. `flutter_launcher_icons` generates the Windows icon from `assets/branding/orvix_icon.png`.

GitHub Actions then:

1. runs Flutter analysis,
2. builds the Windows release,
3. creates a portable ZIP,
4. builds `installer/orvix.iss` with Inno Setup,
5. uploads both artifacts,
6. publishes them to a GitHub Release for a matching version tag.

## Legacy prototype

The root Go files and `ui/` directory belong to the older v0.2 prototype. They are retained for reference and are not the target architecture for new Orvix features.
