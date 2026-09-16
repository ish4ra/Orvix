# Pikora

Pikora is a **PikPak-first cinematic media hub**. The goal is a streamlined experience similar in product shape to modern media hubs: browse movies and TV, search instantly, connect a PikPak account, match cloud media, and play from one interface.

## Current development — v0.3 Flutter branch

The original v0.2 Go prototype proved the basic PikPak/catalog idea, but its UI launched Microsoft Edge in app mode. That prototype remains on `main` for reference.

Active development is now on the **`v0.3-flutter`** branch.

Why Flutter/Dart now instead of rewriting later:

- native Windows desktop window — no direct Edge executable dependency
- the same Dart services/domain code can later target Android and Android TV
- cinematic custom UI is much easier to evolve
- the player can move to `media_kit` / libmpv
- Android-specific Kotlin can still be added later only where a native module is genuinely useful

## v0.3 foundation

- Flutter Windows shell
- Home / Search / My PikPak navigation
- popular Movies / TV catalog rails
- live movie/TV suggestions after 2+ typed characters
- PikPak captcha-aware sign-in
- secure token/device storage
- PikPak root cloud library browser
- GitHub Actions Windows build

## Product direction

Pikora is intentionally narrower than multi-provider apps: **PikPak is the primary cloud provider**.

The intended flow is:

```text
Catalog / Search
      ↓
Movie or TV detail
      ↓
Check My PikPak first
      ↓
Resolve an authorized/user-configured source when needed
      ↓
Send source to PikPak
      ↓
Wait for cloud task / cache
      ↓
Play inside Pikora
```

The source layer is pluggable. Pikora will not bundle a hard-coded piracy torrent-site list or preconfigured infringing source configuration. User-configured/self-hosted/authorized integrations can plug into the resolver without changing the core application.

## Inspiration and implementation

Apps such as Debrify demonstrate that this product category works well with Flutter across Windows, Android/Android TV and other platforms, including cloud-provider integrations and a libmpv-based player. Pikora is being implemented as its own PikPak-focused codebase rather than copying Debrify source directly.

Debrify is AGPL-3.0-only. Copying its implementation would bring AGPL corresponding-source obligations, so Pikora uses it only as a product/architecture reference unless the project explicitly chooses AGPL-compatible reuse later.

## Build v0.3

Checkout the Flutter branch:

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

The GitHub Actions workflow also produces a Windows build artifact automatically for pushes to `v0.3-flutter`.

## Roadmap

See:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/ROADMAP.md`](docs/ROADMAP.md)

## Notes

- PikPak integration relies on community-observed/undocumented web endpoints and may require maintenance when PikPak changes authentication or captcha behavior.
- Pikora does not persist the PikPak password by default.
- Catalog metadata is independent from the user's PikPak cloud library.
