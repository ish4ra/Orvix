<p align="center">
  <img src="assets/branding/orvix_icon.png" alt="Orvix" width="118" />
</p>

<h1 align="center">Orvix</h1>

<p align="center">
  <strong>A cinematic, cross-platform media hub built around discovery, flexible source resolution, cloud/debrid workflows, P2P playback, smart subtitles, and a native-feeling player experience.</strong>
</p>

<p align="center">
  <a href="https://github.com/ish4ra/Orvix/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/ish4ra/Orvix?include_prereleases&sort=semver&style=for-the-badge"></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white">
  <img alt="Dart" src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-x64-0078D4?style=for-the-badge&logo=windows11&logoColor=white">
  <img alt="Android" src="https://img.shields.io/badge/Android-Mobile%20%2B%20TV-3DDC84?style=for-the-badge&logo=android&logoColor=white">
</p>

<p align="center">
  <a href="https://github.com/ish4ra/Orvix/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/ish4ra/Orvix?style=flat-square"></a>
  <a href="https://github.com/ish4ra/Orvix/forks"><img alt="Forks" src="https://img.shields.io/github/forks/ish4ra/Orvix?style=flat-square"></a>
  <a href="https://github.com/ish4ra/Orvix/issues"><img alt="Issues" src="https://img.shields.io/github/issues/ish4ra/Orvix?style=flat-square"></a>
  <img alt="Repo size" src="https://img.shields.io/github/repo-size/ish4ra/Orvix?style=flat-square">
  <img alt="Last commit" src="https://img.shields.io/github/last-commit/ish4ra/Orvix?style=flat-square">
</p>

<p align="center">
  <a href="#-what-is-orvix">Overview</a> •
  <a href="#-platform-status">Platforms</a> •
  <a href="#-feature-map">Features</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-source-engine">Sources</a> •
  <a href="#-playback-engine">Playback</a> •
  <a href="#-subtitles--ai-sinhala">Subtitles</a> •
  <a href="#-building-from-source">Build</a> •
  <a href="#-roadmap">Roadmap</a>
</p>

---

## 🎬 What is Orvix?

**Orvix** is an experimental multi-platform media application built with **Flutter/Dart**. It is designed to bring the parts of a modern media workflow into one interface:

- cinematic movie and TV discovery
- fast title search and rich metadata
- seasons, episodes, cast artwork and title information
- configurable Stremio-compatible source providers
- playability-oriented source ranking
- free P2P/torrent playback experiments
- PikPak and TorBox cloud workflows
- native in-app playback
- Android ExoPlayer/Media3 routing with MPV fallback in current beta development
- Windows libmpv-based playback
- subtitle discovery and track management
- OpenSubtitles integration
- experimental AI-powered Sinhala subtitle translation
- local Library, Watchlist and Continue Watching state
- customizable Home shelves
- Orvix account integration backed by Supabase
- automated multi-platform release pipelines

The goal is not to be a thin video-player wrapper. Orvix is being developed as a **complete media browsing, source-resolution, playback and subtitle platform** with separate services for catalog data, account state, source ranking, cloud providers, playback and subtitle intelligence.

> [!IMPORTANT]
> Orvix is under active development. The v0.7.5 line is a prerelease/beta track, and behavior can differ between Windows, Android Mobile and Android TV while playback paths are being stabilized.

---

## 🚀 Current development track

The repository has evolved rapidly from the original prototype into the current Flutter application.

**Current public prerelease track:** `v0.7.5-beta.x`

The v0.7.5 beta series has included work on:

- Android Mobile and Android TV builds
- native/free P2P playback experiments
- playability-first free-source ranking
- Android ExoPlayer-first playback
- automatic MPV fallback where appropriate
- TV-specific navigation and source browsing
- IMDb-popularity-based Trending shelves
- richer metadata and cast presentation
- season and episode artwork
- metadata/source prefetching
- OpenSubtitles v3 integration plus legacy fallback
- cinematic title-branded startup/loading screens
- expanded regression and smoke-test coverage

The latest published prerelease assets can be found on the **[Releases](https://github.com/ish4ra/Orvix/releases)** page.

---

## 🖥️ Platform status

| Platform | Status | Playback direction | Distribution |
|---|---|---|---|
| **Windows x64** | 🟢 Active | `media_kit` / libmpv | Portable ZIP + Inno Setup installer |
| **Android Mobile** | 🟡 Active Beta | ExoPlayer/Media3 first, MPV fallback where appropriate | APK + ABI-specific APKs in beta releases |
| **Android TV** | 🟡 Active Beta | TV-safe Android playback path + P2P experiments | Dedicated Android TV APK |
| **macOS** | ⚪ Not currently shipping | Planned/research | No current public package |

### Release philosophy

Orvix currently favors rapid prerelease testing over pretending every platform is already production-stable.

Windows remains the most mature desktop target. Android Mobile and Android TV are being tested aggressively because their decoder, networking, P2P and remote-control behavior differs significantly from desktop.

---

## ✨ Feature map

### Discovery & metadata

- cinematic dark Home experience
- Movies and TV discovery
- instant search
- exact-title-oriented search ranking
- popular/trending shelves
- IMDb-backed top-rated/trending work in recent builds
- movie and series detail pages
- seasons and episodes
- episode thumbnails
- title logos/backdrops where available
- cast artwork and richer metadata
- upcoming-title labeling
- metadata prefetch and caching
- source prefetch experiments to reduce delay after opening a title

### Personal media state

- local **Library**
- **Watchlist**
- **Continue Watching**
- resume position tracking
- TV episode-aware progress
- configurable Home shelves
- persistent UI preferences
- per-title and series source pinning in supported flows

### Sources

- Stremio-compatible source-provider architecture
- multi-provider querying
- merged source results
- duplicate handling
- quality detection
- resolution detection
- release-source detection
- codec/format metadata
- file-size parsing
- seeder parsing
- cache indicators where provider metadata exposes them
- configurable source result limits
- source pinning
- Quick Play prioritization
- free-source playability-first ranking in the v0.7.5 beta line
- filtering for problematic 3D/SBS-style releases
- preferred release-group support in earlier/current source-engine work
- exact episode/file metadata preservation for season packs

### Cloud / remote media workflows

- **PikPak** integration
- **TorBox** integration
- secure token storage
- account/library browsing
- preferred-cloud selection
- cloud-first matching
- magnet submission
- direct-link submission where supported
- transfer/task polling
- playable-file resolution
- season-pack child-file selection
- playback handoff to the built-in player

### Playback

- built-in native-feeling player UI
- Windows libmpv path
- Android ExoPlayer/Media3 path in current beta development
- MPV fallback where appropriate
- seeking
- playback position/resume
- playback speed
- volume and mute
- fullscreen
- embedded audio-track selection
- embedded subtitle-track selection
- external subtitle support
- next-episode workflow
- buffering/startup failure handling
- title-branded cinematic loading/startup treatment in v0.7.5 beta
- lighter mid-playback rebuffer UI
- large-file/cloud playback tuning
- patched desktop `media_kit` dependencies for stability

### Subtitles

- embedded text subtitle support
- external SRT/VTT/ASS/SSA support
- OpenSubtitles-based subtitle discovery work
- OpenSubtitles v3 integration in recent beta builds
- official legacy OpenSubtitles addon fallback in the v0.7.5 beta line
- subtitle de-duplication
- exact-video subtitle matching work using file metadata/hash where available
- subtitle timing/sync calibration work
- manual sync fallback controls in relevant builds
- experimental AI Sinhala translation

### Account & backend

- Supabase-backed Orvix account layer
- authenticated backend calls
- secure client credential/token handling
- server-side AI translation key management
- account/session services separated from UI

---

## 🧠 Architecture

Orvix intentionally separates **presentation**, **domain/services**, **provider integration**, **playback**, **state** and **backend** concerns.

```text
┌─────────────────────────────────────────────────────────────────┐
│                         ORVIX CLIENT                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Presentation                                                   │
│  ├─ Home / Trending / Discovery                                 │
│  ├─ Search                                                      │
│  ├─ Movie / TV Details                                          │
│  ├─ Seasons / Episodes                                          │
│  ├─ Library / Watchlist / Continue Watching                     │
│  ├─ Sources                                                     │
│  ├─ Account / Settings                                          │
│  └─ Player                                                      │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Domain & Services                                              │
│  ├─ CatalogService                                              │
│  ├─ SourceProviderService                                       │
│  ├─ MediaStateService                                           │
│  ├─ HomePreferencesService                                      │
│  ├─ CloudPreferencesService                                     │
│  ├─ PikPakService / PikPakTransferService                       │
│  ├─ TorBoxService                                               │
│  ├─ PlaybackService                                             │
│  ├─ OrvixAccountService                                         │
│  └─ AI Sinhala subtitle services                                │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Playback / Resolution                                          │
│  ├─ Cloud-resolved HTTP media                                   │
│  ├─ Direct HTTP media                                           │
│  ├─ Free P2P experiments                                        │
│  ├─ Windows: media_kit / libmpv                                 │
│  └─ Android: ExoPlayer/Media3 → MPV fallback                    │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Platform & Infrastructure                                      │
│  ├─ Secure storage                                              │
│  ├─ Shared preferences                                          │
│  ├─ HTTP                                                        │
│  ├─ Supabase                                                    │
│  ├─ GitHub Actions                                              │
│  └─ Windows / Android packaging                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

For a deeper architecture document, see **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## 🔎 Discovery pipeline

A simplified title-browsing flow looks like this:

```text
Home / Search
     │
     ▼
Catalog metadata
     │
     ├──────────────► Popular / Trending / Top Rated shelves
     │
     ▼
Title details
     │
     ├─ metadata
     ├─ cast
     ├─ backdrop/logo
     ├─ seasons
     └─ episodes
     │
     ▼
Prefetch/cache selected metadata
     │
     ▼
Sources / Play
```

Catalog data is intentionally separate from the user's cloud library. A title can be discoverable even when it does not already exist in PikPak or TorBox.

---

## 🧲 Source Engine

The Source Engine is one of the most heavily iterated parts of Orvix.

It is designed around a **provider abstraction** rather than one hard-wired source parser.

### Provider model

```text
Configured Stremio-compatible providers
          │
          ├──────────────┐
          │              │
          ▼              ▼
     Provider A      Provider B      ...
          │              │
          └──────┬───────┘
                 ▼
           Normalize results
                 │
                 ▼
            Parse metadata
      ┌──────────┼──────────┐
      ▼          ▼          ▼
  quality      seeders     size
  codec        cache       filename
  source       HDR         file index
      └──────────┬──────────┘
                 ▼
         Filter / de-duplicate
                 │
                 ▼
          Rank for the user
                 │
        ┌────────┴────────┐
        ▼                 ▼
   Source browser      Quick Play
```

### Ranking strategies

Orvix has experimented with multiple ranking models because the "largest 4K file" is often **not** the best real-world playback choice.

Historical/current ranking work includes:

- release-quality priority
- resolution priority
- seed-count priority
- file-size priority
- cache-first priority
- user-reordered priorities
- "Smooth" ranking for more practical playback
- **playability-first free P2P ranking** in the latest beta line

The latest P2P direction deliberately avoids treating resolution as more important than whether a source can realistically start and sustain playback.

### Source metadata

When exposed by the provider, Orvix can work with metadata such as:

- release name / filename
- 2160p / 1080p / 720p classification
- REMUX / BluRay / WEB-DL / WEBRip / HDTV / DVD / CAM classification
- HEVC/x265 and other codec hints
- HDR hints
- audio hints
- seeders
- file size
- torrent infohash
- torrent file index
- Stremio `bingeGroup`
- provider/cache hints

This metadata is also important for exact episode routing in season packs.

---

## 🌐 Free P2P playback experiments

The v0.7.5 prerelease line includes a dedicated free P2P playback effort.

The key problem is not simply "can a torrent be opened?" It is whether a particular source can become playable fast enough on the actual device and network.

The P2P path therefore focuses on:

- torrent infohash handling
- torrent file-index routing
- filename-aware file selection
- swarm health
- peers
- real download speed
- startup timeout behavior
- playability-oriented source ranking
- Android Mobile vs Android TV differences
- player handoff correctness
- avoiding unnecessary pre-player buffering stages
- keeping ordinary buffering UI separate from startup/loading UI

```text
Source result
     │
     ▼
Torrent metadata
     │
     ├─ infohash
     ├─ trackers
     ├─ file index
     └─ filename hint
     │
     ▼
Native/local P2P engine
     │
     ├─ peer discovery
     ├─ file selection
     └─ local HTTP stream
     │
     ▼
Player routing
     │
     ├─ Android: ExoPlayer/Media3 first
     └─ MPV fallback where appropriate
```

> [!NOTE]
> P2P behavior depends on the swarm, peer availability, selected file, device codec support and network conditions. A source working on one device does not automatically prove that the same source will behave identically on another.

---

## ☁️ Multi-cloud architecture

Orvix also supports a cloud-first playback path.

### Supported cloud services in the current codebase

| Provider | Authentication | Library | Add source | Task polling | Playback URL |
|---|---:|---:|---:|---:|---:|
| **PikPak** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **TorBox** | ✅ | ✅ | ✅ | ✅ | ✅ |

### High-level flow

```text
Movie / Episode
      │
      ▼
Read preferred cloud
      │
      ▼
Check connected cloud for an existing match
      │
      ├── found ─────────► resolve playable file
      │                         │
      │                         ▼
      │                       Player
      │
      └── not found
              │
              ▼
      Query Source Engine
              │
              ▼
       User chooses source
              │
              ▼
   Submit to PikPak / TorBox
              │
              ▼
         Poll task state
              │
              ▼
      Select exact video file
              │
              ▼
        Resolve media URL
              │
              ▼
             Player
```

### Season-pack correctness

Multi-file torrents are one of the easiest places for a media app to play the **wrong episode**.

Orvix has therefore added work around preserving and using:

- torrent `fileIdx`
- filenames
- source size
- provider metadata
- cloud child-file metadata
- season/episode hints

The goal is to resolve the intended child file instead of blindly choosing the largest video in a torrent.

---

## ▶️ Playback Engine

Playback is intentionally platform-aware.

### Windows

Windows playback is built around:

- `media_kit`
- `media_kit_video`
- libmpv
- patched desktop stability fixes pinned to a reviewed Debrify commit

The patches currently pinned in `pubspec.yaml` address native lifetime/render-context stability concerns relevant to desktop playback.

### Android

Recent v0.7.5 beta work routes Android playback through:

1. **ExoPlayer / Media3 first**
2. **MPV fallback where appropriate**

This allows Orvix to use Android's strongest native media path while retaining an alternate engine for streams that behave better outside the primary route.

### Player capabilities

The player work includes:

- seek
- pause/resume
- volume
- mute
- fullscreen
- playback speed
- resume position
- embedded audio tracks
- embedded subtitle tracks
- external subtitle tracks
- next-episode flow
- startup watchdog/error states
- buffering states
- P2P startup health
- cloud VOD playback
- title-branded startup visuals

---

## 🎞️ Cinematic startup/loading experience

Recent v0.7.5 beta builds added title-aware startup visuals.

When available, the loading experience can use the selected title's:

- logo
- backdrop
- branding context

The goal is to make playback startup feel like part of the title experience rather than a generic spinner.

The branded loading treatment is intended for **startup / engine handoff**, while ordinary mid-playback buffering remains lightweight so playback is not constantly covered by a large overlay.

---

## 💬 Subtitles & AI Sinhala

Subtitle handling is another major Orvix workstream.

### Standard subtitles

Orvix supports work around:

- embedded subtitle tracks
- local/external subtitle files
- SRT
- VTT
- ASS
- SSA
- manual track selection
- OpenSubtitles discovery
- release matching
- subtitle deduplication
- sync calibration
- manual sync fallback

### OpenSubtitles direction

Recent prerelease work includes:

- OpenSubtitles v3
- the official legacy OpenSubtitles addon as a fallback
- deduplication between subtitle providers
- matching subtitles against the selected video instead of only the title name

Where the stream allows the required access, matching can make use of release information such as:

- file hash
- file size
- filename
- movie/episode metadata

When exact release metadata is unavailable, Orvix can fall back to title/episode-based matching.

---

## 🇱🇰 AI Sinhala subtitles — experimental

Orvix includes an experimental **AI Sinhala** subtitle pipeline aimed at natural Sri Lankan Sinhala rather than literal word-for-word translation.

The architecture is deliberately server-backed so the AI provider secret is not embedded in the client application.

```text
Selected English text subtitle
           │
           ▼
   Subtitle timing/cues
           │
           ▼
Orvix subtitle preparation
           │
           ▼
Authenticated Supabase Edge Function
           │
           ▼
      Gemini translation
           │
           ▼
 Sinhala subtitle output/cache
           │
           ▼
      Player renderer
```

The feature has gone through multiple iterations:

- live cue translation
- session caching
- original-text fallback
- prepared/offline-style translation experiments
- exact release matching
- timing calibration
- hidden English timing-reference experiments
- translation buffering ahead of playback
- per-video manual Earlier/Later fallback controls

The long-term priority is **sync correctness first**, translation quality second, and convenience third.

See **[docs/AI_SINHALA_SUBTITLES.md](docs/AI_SINHALA_SUBTITLES.md)** for the original design notes.

---

## 👤 Orvix account layer

Orvix includes a dedicated account service backed by **Supabase**.

The account/backend layer is used to keep sensitive backend logic away from the client and to support authenticated services such as AI subtitle translation.

Relevant concepts include:

- Supabase authentication
- authenticated Edge Function calls
- secure local token storage
- server-side secret handling
- account/session state isolated from screen widgets

The client should never need to ship a Gemini API key directly inside the desktop or Android application.

---

## 🏠 Home experience

The Home screen is designed as a configurable media surface rather than a fixed list.

Depending on the current build and enabled preferences, shelves can include concepts such as:

- Continue Watching
- My Library
- My Watchlist
- Popular Movies
- Popular TV
- Trending
- Top Rated Movies
- Top Rated TV
- IMDb-oriented lists

Home preferences are persistent, and earlier/current work allows rows to be enabled, disabled and reordered.

---

## 📚 Library, Watchlist & Continue Watching

Orvix keeps user media state separate from cloud storage.

That means:

- adding a movie to the Orvix Library does not mean copying it to PikPak
- Watchlist is an app-level state
- Continue Watching is driven by playback progress
- TV progress can be tracked per episode while representing the series cleanly in the UI

This separation makes the UI behave like a media application rather than a raw cloud-file browser.

---

## 🧱 Tech stack

| Area | Technology |
|---|---|
| UI | Flutter |
| Language | Dart |
| Design | Material 3 + custom cinematic UI |
| Desktop player | media_kit / libmpv |
| Android player direction | ExoPlayer / Media3 + MPV fallback |
| Networking | http |
| Images | cached_network_image |
| Secure credentials | flutter_secure_storage |
| Local preferences/state | shared_preferences |
| Backend/Auth | Supabase |
| File interaction | file_picker |
| Desktop window integration | window_manager |
| Windows packaging | Inno Setup |
| Automation | GitHub Actions |
| Legacy prototype | Go |

Selected dependency versions are documented in **[pubspec.yaml](pubspec.yaml)**.

---

## 🗂️ Repository layout

```text
Orvix/
│
├─ lib/
│  ├─ app.dart
│  ├─ main.dart
│  ├─ models/
│  │  └─ media_item.dart
│  ├─ screens/
│  │  ├─ account_screen.dart
│  │  ├─ details_screen.dart
│  │  ├─ home_screen.dart
│  │  ├─ library_screen.dart
│  │  ├─ media_library_screen.dart
│  │  ├─ player_screen.dart
│  │  ├─ search_screen.dart
│  │  ├─ settings_screen.dart
│  │  └─ sources_screen.dart
│  ├─ services/
│  │  ├─ ai_sinhala_preferences_service.dart
│  │  ├─ ai_sinhala_subtitle_service.dart
│  │  ├─ catalog_service.dart
│  │  ├─ cloud_preferences_service.dart
│  │  ├─ home_preferences_service.dart
│  │  ├─ media_state_service.dart
│  │  ├─ orvix_account_service.dart
│  │  ├─ pikpak_service.dart
│  │  ├─ pikpak_transfer_service.dart
│  │  ├─ playback_service.dart
│  │  ├─ source_provider_service.dart
│  │  └─ torbox_service.dart
│  └─ widgets/
│     └─ media_card.dart
│
├─ assets/
│  └─ branding/
│     └─ orvix_icon.png
│
├─ docs/
│  ├─ AI_SINHALA_SUBTITLES.md
│  ├─ ARCHITECTURE.md
│  └─ ROADMAP.md
│
├─ installer/
│  └─ Windows Inno Setup configuration
│
├─ supabase/
│  └─ backend / Edge Function related project files
│
├─ test/
│  └─ Flutter regression tests
│
├─ .github/
│  └─ workflows/
│     └─ validation, packaging and release automation
│
├─ windows/
│  └─ Windows runner/resources
│
├─ ui/ + *.go
│  └─ legacy Orvix/Pikora-era prototype retained for reference
│
├─ pubspec.yaml
├─ CHANGELOG.md
└─ README.md
```

> [!NOTE]
> The root Go files and `ui/` directory are legacy prototype material. New application features belong in the Flutter architecture.

---

## 🔐 Local data & credential handling

Orvix separates ordinary preferences from secrets.

### Typical local preferences

Examples:

- Home shelf order
- Watchlist / Library state
- Continue Watching state
- source ranking preferences
- preferred cloud
- player/UI preferences

### Sensitive values

Authentication tokens and credentials are intended to use **secure storage** rather than plain shared preferences.

Backend AI secrets are kept server-side.

---

## 🧪 Validation & quality gates

Recent release workflows have included combinations of:

- `flutter analyze`
- Flutter test suite
- AI Sinhala backend smoke tests
- OpenSubtitles backend smoke tests
- Windows release build
- Windows P2P engine smoke testing
- Inno Setup packaging
- Android Mobile APK generation
- Android TV APK generation
- native P2P engine verification
- release-asset publishing
- regression coverage around loading/player/subtitle behavior

Orvix is still beta software, but the release process is intentionally moving toward repeatable validation rather than manual-only builds.

---

## 📦 Releases

Go to **[GitHub Releases](https://github.com/ish4ra/Orvix/releases)** for packaged builds and release notes.

Typical prerelease assets may include:

```text
Orvix-Setup-<version>-Windows-x64.exe
Orvix-<version>-Windows-x64.zip

Orvix-<version>-Android-Mobile.apk
Orvix-<version>-Android-Mobile-arm64-v8a.apk
Orvix-<version>-Android-Mobile-armeabi-v7a.apk
Orvix-<version>-Android-Mobile-x86_64.apk

Orvix-<version>-Android-TV.apk
```

Use the platform package that matches your device and the release notes for that build.

---

## 🛠️ Building from source

### Requirements

For the current Flutter codebase, you will generally need:

- Git
- Flutter stable
- a compatible Dart SDK through Flutter
- Visual Studio with **Desktop development with C++** for Windows builds
- Inno Setup only if you want to reproduce the Windows installer packaging
- platform tooling for any Android development branch/build path you are working with

### Clone

```bash
git clone https://github.com/ish4ra/Orvix.git
cd Orvix
```

### Install Flutter dependencies

```bash
flutter pub get
```

### Analyze

```bash
flutter analyze lib --no-fatal-warnings --no-fatal-infos
```

### Run Windows development build

If the Windows runner needs to be regenerated:

```bash
flutter create --platforms=windows --project-name orvix .
flutter pub get
flutter run -d windows
```

### Build Windows release

```bash
flutter build windows --release
```

The packaged release pipeline additionally creates a portable ZIP and an Inno Setup installer.

> [!WARNING]
> The Android beta line has changed quickly during P2P/player development. For Android testing, use the source/tag associated with the beta release you are reproducing rather than assuming every historical Android release can be rebuilt identically from a different commit.

---

## ⚙️ Configuration model

Orvix intentionally keeps provider/account behavior configurable.

Depending on the feature:

- connect a supported cloud provider
- configure compatible source providers
- select source-ranking behavior
- choose a preferred cloud
- select subtitle behavior
- sign in to an Orvix account for authenticated backend features

The application architecture is designed so new provider implementations can be added without rewriting the entire UI or player.

---

## 🧭 Playback decision model

A simplified conceptual decision tree:

```text
User presses Play
      │
      ▼
Is a preferred cloud connected?
      │
   ┌──┴──┐
  yes    no
   │      │
   ▼      ▼
Check   Query source engine
cloud       │
   │        ▼
found?   Source picker / Quick Play
   │        │
 ┌─┴─┐      ├───────────────┐
yes no      │               │
 │   │      ▼               ▼
 │   └──► Cloud transfer   Free/direct/P2P path
 │             │               │
 ▼             ▼               ▼
Resolve     Poll task       Resolve stream
URL            │               │
 └─────────────┴───────┬───────┘
                       ▼
                Platform player
```

Actual behavior varies by build, provider and platform, but the important design principle is that **catalog → source → resolver → player** are separate layers.

---

## 🧩 Why separate services?

Large media applications become difficult to maintain when every screen directly talks to every API.

Orvix instead uses dedicated services so that:

- catalog changes do not require rewriting the player
- a new cloud provider does not require rewriting Home
- subtitle logic can evolve independently
- source ranking can change without replacing provider APIs
- account/backend behavior is not embedded in UI widgets
- platform playback differences can be isolated

This also makes testing and debugging easier because failures can be narrowed down to a stage:

```text
Catalog?
Source discovery?
Ranking?
Cloud transfer?
P2P engine?
Playable URL?
Player engine?
Subtitle selection?
Subtitle timing?
AI translation?
```

That separation is especially important for the Android TV and P2P work, where several layers can fail in different ways while appearing to the user as simply "buffering."

---

## 📈 Project evolution

### Prototype era

- Go-based prototype
- early media/source experiments
- original UI concepts

### Flutter desktop foundation

- complete Flutter rebuild
- cinematic browsing
- source-provider architecture
- PikPak workflow
- libmpv playback
- Windows packaging

### Multi-cloud era

- TorBox integration
- preferred cloud
- richer source ranking
- exact season-pack routing
- Library / Continue Watching improvements

### Subtitle & account era

- Supabase account layer
- AI Sinhala experiments
- OpenSubtitles matching
- subtitle timing work

### Cross-platform / P2P era

- Android Mobile packages
- Android TV packages
- free P2P experiments
- ExoPlayer-first Android routing
- MPV fallback
- TV-specific UX
- playability-first ranking
- richer loading and metadata experience

For detailed historical changes, see **[CHANGELOG.md](CHANGELOG.md)** and the **[Releases](https://github.com/ish4ra/Orvix/releases)** page.

---

## 🗺️ Roadmap

The roadmap is intentionally fluid while the cross-platform playback architecture is being stabilized.

### Near-term

- improve Android TV navigation and focus behavior
- continue P2P reliability work
- improve source playability scoring
- harden ExoPlayer ↔ MPV fallback behavior
- improve startup and failure recovery
- make subtitle selection and timing more reliable
- improve exact OpenSubtitles release matching
- stabilize AI Sinhala translation without sacrificing sync
- reduce metadata/source-loading latency
- improve episode/season UI consistency
- continue Windows/Android release automation

### Medium-term

- stronger provider abstraction
- richer cloud/debrid status and task management
- more robust cross-device state
- improved subtitle styling
- download/background-transfer strategy where appropriate
- Android media-session integration
- picture-in-picture research
- better telemetry/log export for debugging without exposing user secrets

### Long-term

- stable cross-platform v1
- cleaner automatic update strategy
- optional macOS resurrection
- deeper automated testing
- broader provider ecosystem
- production-quality TV experience

The older roadmap document is available at **[docs/ROADMAP.md](docs/ROADMAP.md)**, but active prerelease development may move faster than that document.

---

## 🐛 Reporting playback problems

Playback issues are much easier to fix when the report identifies the exact layer.

A useful report should include:

```text
Platform:
Device:
Orvix version:
Title:
Season / Episode:
Source filename:
Source size:
Seeders / peers:
Provider:
Playback path: cloud / direct / P2P
Player: Exo / MPV / Windows libmpv
What happened:
How long it buffered:
Whether the same source works on another device:
Subtitle track/provider if subtitle-related:
```

For P2P issues, the exact source matters. "Movie X does not play" is less useful than the exact torrent/release and device combination.

---

## 🤝 Contributing

Orvix is evolving quickly, so contributions are most useful when they are focused and reproducible.

Good contribution areas include:

- bug fixes
- source parsing
- ranking heuristics
- TV focus/navigation
- player stability
- subtitle matching/sync
- tests
- documentation
- performance improvements
- cloud-provider reliability

Before making large architectural changes, check the existing service boundaries and release history so new code does not duplicate an already-solved path.

---

## ⚖️ Content, providers & responsibility

Orvix is a media client and integration project.

It does **not** claim ownership of third-party media, metadata, cloud services, subtitle services or provider content.

Users are responsible for:

- complying with the laws that apply to them
- using third-party services according to their terms
- accessing only content they are authorized to access
- configuring providers responsibly

Third-party service names and trademarks belong to their respective owners.

Provider availability can change at any time because Orvix does not control third-party APIs, addons, swarms or cloud services.

---

## 🔒 Security notes

- Do not commit private API keys or user credentials.
- Keep server-only secrets in the backend secret store.
- Treat third-party tokens as sensitive.
- Use secure storage for device-side credentials.
- Review external provider URLs before trusting them.
- Do not assume a community/undocumented API will remain stable.
- Avoid logging secrets in GitHub Actions or debug output.

---

## 📄 Documentation

- **[Architecture](docs/ARCHITECTURE.md)**
- **[AI Sinhala subtitles](docs/AI_SINHALA_SUBTITLES.md)**
- **[Roadmap](docs/ROADMAP.md)**
- **[Changelog](CHANGELOG.md)**
- **[Releases](https://github.com/ish4ra/Orvix/releases)**

---

## 🌟 Project direction

Orvix is being built around a simple idea:

> **One polished media interface should be able to discover a title, understand available sources, choose a practical playback path, hand it to the best player for the device, manage subtitles intelligently, and preserve the user's state — without turning the application into one giant tightly-coupled code path.**

That is why the project contains much more than a player screen: catalog services, provider normalization, ranking logic, cloud integrations, P2P experiments, subtitle intelligence, account/backend services, state management, platform-specific playback behavior, packaging and release automation all have to work together.

<p align="center">
  <strong>Orvix — discover • resolve • play</strong>
</p>

<p align="center">
  <a href="https://github.com/ish4ra/Orvix">Repository</a> •
  <a href="https://github.com/ish4ra/Orvix/releases">Releases</a> •
  <a href="https://github.com/ish4ra/Orvix/issues">Issues</a>
</p>
