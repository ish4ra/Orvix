# macOS builds

The macOS project is generated in CI (`flutter create --platforms=macos`) and
then configured by scripts in `tools/`. Nothing under `macos/` is committed.

| Step | Script | What it does |
|---|---|---|
| Branding | `tools/generate_desktop_branding.py --macos` | Installs the macOS icon set from `tools/macos_icon/` and names the app "Orvix" |
| Network access | `tools/configure_macos_build.py` | Keeps the App Sandbox and adds the two network entitlements |
| Check | `tools/verify_macos_app.py` | Identity, architectures, bundled libraries, signature, entitlements, icon |

Both `ci.yml` and `prerelease.yml` run all three for the public app, so a pull
request builds what a release builds.

## Icon

macOS has its own icon. It is drawn on Apple's macOS grid (an 824 px rounded
square on a 1024 px canvas, transparent outside, soft drop shadow) with the
Orvix dark body and the Orvix O taken unchanged from the launcher artwork.
The 16 and 32 px images use a larger O. Android, Android TV, Windows, iOS and
the in-app logo are not affected.

- Source of truth: `tools/macos_icon/AppIcon.appiconset/` (committed).
- Previews: `docs/branding/macos-icon/` (1024, 512, 256, 128, 32 and a sheet
  on a light and a dark background).
- To change it, edit `tools/generate_macos_icon.py`, run it (needs Pillow),
  review the previews and commit the output. Builds copy the committed
  images; they never render the icon.

## Network access

`flutter create` produces a sandboxed app that is allowed nothing else, and a
sandboxed app without `com.apple.security.network.client` cannot open a
connection at all. The workflows used to add the network entitlements; that
step was lost when the workflows were consolidated (commit `d27df80`), and
since then the release workflow has built the app with the template's
entitlements only.
`tools/configure_macos_build.py` puts it back, with the sandbox still on, so
the app's data stays where it was (`~/Library/Containers/com.orvix.orvix`).

## Signing and distribution

Builds are **ad-hoc signed** (`CODE_SIGN_IDENTITY = -`). There is no Apple
Developer ID certificate and no notarization, so Gatekeeper blocks the first
start of a downloaded build and the user has to allow the app once (System
Settings → Privacy & Security → Open Anyway). Removing that step needs a paid
Apple Developer membership, a Developer ID certificate and notarization in
`prerelease.yml`.

The release file stays `Orvix-v<version>-macOS.zip`; the in-app updater
matches on that name.

## Before the next public macOS release

Checked by CI on every build: universal binary (arm64 and x86_64), bundle
identifier and name, sandbox and network entitlements, valid ad-hoc
signature, no library dependency outside macOS and the bundle, the committed
icon in the bundle.

CI also starts the app on its Apple Silicon machine
(`tools/macos_launch_smoke_test.sh`). That machine is a virtual Mac without
hardware-accelerated OpenGL, which the MPV video output requires, and Orvix
opens a video output a few seconds after starting. So in CI the app starts,
loads its libraries, runs for a few seconds and stops there; the test prints
the crash report and accepts only that stop. It does not show that the app
keeps running on a real Mac.

Still to check by hand on a Mac, because CI cannot:

1. The app opens after the Gatekeeper step, stays open, and the icon looks right in the
   Dock, Finder, Launchpad, Spotlight and the app switcher, in light and dark
   mode.
2. The catalog loads and sign-in works (this is the network entitlement).
3. A direct or debrid source plays in the MPV player, with subtitles.
4. The in-app update check finds a newer release and the downloaded ZIP is
   revealed in Finder.
5. An existing installation keeps its settings after updating.

Known gaps:

- **Free P2P does not work on macOS.** The app looks for a bundled stream
  engine in `Contents/Resources`, and no workflow builds or bundles one for
  macOS since the consolidation. The app reports that the engine is missing.
- **Intel** is built but cannot be run in CI (the build machines are Apple
  Silicon).
- The minimum macOS version is whatever the current Flutter template sets
  (12.0 with Flutter 3.50; the CI check prints `LSMinimumSystemVersion`).
  The "Require macOS 10.15+" step in `prerelease.yml` only edits a Podfile
  and does not lower it.
- The AI translation key is stored with the default keychain options, which
  ad-hoc signed builds may not be allowed to use.
