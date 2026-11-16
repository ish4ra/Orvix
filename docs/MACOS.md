# macOS builds

The macOS project is generated in CI (`flutter create --platforms=macos`) and
then configured by scripts in `tools/`. Nothing under `macos/` is committed.

| Step | Script | What it does |
|---|---|---|
| Branding | `tools/generate_desktop_branding.py --macos` | Installs the macOS icon set from `tools/macos_icon/` and names the app "Orvix" |
| Network access | `tools/configure_macos_build.py` | Keeps the App Sandbox and adds the two network entitlements |
| Free P2P engine | `tools/bundle_macos_stream_engine.sh` | Puts the universal stream engine into the built app and signs it as the app's sandboxed helper |
| Check | `tools/verify_macos_app.py` | Identity, architectures, bundled libraries, signature, entitlements, icon, Free P2P engine |

Both `ci.yml` and `prerelease.yml` run all of them for the public app, so a
pull request builds what a release builds.

## Free P2P engine

Free P2P on macOS is played through a local stream engine that the app starts
as a child process: `Contents/Resources/orvix-stream-server`. The app talks to
it on `127.0.0.1:11470`, and MPV plays from that address.

**What went wrong.** The workflows used to build this engine and copy it into
the app. That was lost in the consolidation (`d27df80`), and macOS builds
since then had no engine at all. Every source check then failed at the first
step (the engine could not be started), which the source list shows as
ENGINE ERROR on every source and "No source delivered live data".

**How it is built now.** The job `macos-engine` in both workflows runs
`tools/build_macos_stream_engine.sh` once on an Apple Silicon and once on an
Intel machine:

- the upstream stream server at a pinned commit (tag `v0.1.8`, see
  `licenses/stream-server`), prepared by `tools/patch_macos_stream_engine.py`;
- linked statically against libtorrent 2.0.11 and OpenSSL, so it depends on
  nothing but macOS (the build fails otherwise);
- cached, so it is rebuilt only when those two scripts change.

The patch changes only the headless start-up: no FFmpeg requirement, listen
on `127.0.0.1` only (port from `ORVIX_STREAM_SERVER_PORT`, default 11470, no
HTTPS listener), no device discovery or update checks, and exit when the app
that started it goes away, so a crashed app cannot leave an engine holding
the port.

**How it is checked.** Before an engine is used, on both architectures:

1. `tools/macos_stream_engine_smoke_test.sh`: it starts and answers its
   health check, a second engine runs next to it on another port, it listens
   on the loopback address only, the port is free after it stops, and it
   exits when its parent exits.
2. `tools/macos_sandbox_engine_test.sh`: a minimal sandboxed app with the
   same entitlements as Orvix starts the engine as a child process, exactly
   as Orvix does, and gets an answer. It then asks the engine for the first
   bytes of a freely shareable torrent (Sintel); that part depends on peers
   being reachable from the build machine and only reports.

Then every macOS app build joins the two engines with `lipo`, signs the
result with the sandbox and inherit entitlements, signs the app again with
the entitlements it had, and `tools/verify_macos_app.py
--require-stream-engine` fails the build, and therefore the release, when
the engine is missing, not executable, not universal or not signed that way.

**Two Orvix apps on one Mac** currently share one engine: the app expects it
on port 11470, and the second app uses the engine the first one started.
Both can play. If the first app quits, or leaves a title the other is still
playing from the same source, the other's stream stops until it resolves the
source again. The engine already supports a port of its own per app; the app
does not use that yet.

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
4. A Free P2P source plays, seeking works, and no `orvix-stream-server`
   process is left after quitting the app (`pgrep -fl orvix-stream-server`).
5. The in-app update check finds a newer release and the downloaded ZIP is
   revealed in Finder.
6. An existing installation keeps its settings after updating.

Known gaps:

- **Free P2P playback has not been seen working on a Mac yet.** The engine
  is bundled and proven to start and answer inside the sandbox in CI; playing
  a torrent through the app needs a real Mac.
- The engine is linked against the build machine's OpenSSL, which is built
  for that machine's macOS version. It is expected to run on older macOS
  versions but that is untested.
- **Intel** is built but cannot be run in CI (the build machines are Apple
  Silicon).
- The minimum macOS version is whatever the current Flutter template sets
  (12.0 with Flutter 3.50; the CI check prints `LSMinimumSystemVersion`).
  The "Require macOS 10.15+" step in `prerelease.yml` only edits a Podfile
  and does not lower it.
- The AI translation key is stored with the default keychain options, which
  ad-hoc signed builds may not be allowed to use.
