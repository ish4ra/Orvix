# Watch Party: test project and private test builds

How to test Watch Party against a real Supabase project and on real devices
without touching production or the public app. Design and device plan:
[WATCH_PARTY.md](WATCH_PARTY.md).

Nothing here is automatic. The public app, normal CI builds and release
builds are unchanged: Watch Party stays compiled out and they talk to the
production project.

## How a test build differs

| | Public build | Test build |
|---|---|---|
| Supabase project | production (built in) | the test project only |
| Watch Party | compiled out | on |
| App updates | as today | never checked |
| AI Sinhala, audio subtitle fallback, SubDL transcripts | as today | off (they call production functions) |
| Android application id | `com.orvix.orvix` | `com.orvix.orvix.wptest`, shown as "Orvix Test" |
| Windows settings folder | `Orvix\orvix` | `Orvix\orvix-watch-party-test` |
| macOS bundle identifier | `com.orvix.orvix` | `com.orvix.orvix.wptest`, shown as "Orvix Watch Party Test" |
| macOS saved secrets (Keychain) | default service | own service, `orvix-test.<bundle identifier>` |
| Where it goes | GitHub release | workflow artifact, kept 7 days |

Sign-in, account data, telemetry and everything else that uses the app's
Supabase client go to the test project. Functions that are not deployed there
simply fail (telemetry does so silently).

A test build is compiled with `ORVIX_TEST_BUILD=true`,
`ORVIX_SUPABASE_URL` and `ORVIX_SUPABASE_PUBLISHABLE_KEY`
(`lib/services/orvix_backend_config.dart`). The app refuses to start, and the
build fails first, if only some are given, if the address or key is
production's, if the key belongs to another project, or if the key is a
secret or service-role key. A build without `ORVIX_TEST_BUILD` refuses any
override.

## 1. Create the test project (once)

1. Create a new, separate Supabase project. Do not reuse production.
2. Authentication: enable email sign-in, keep **anonymous sign-ins off**. For
   quick testing you can turn off email confirmation in this project only.
3. Realtime: leave it enabled. In Realtime settings turn **off** "Allow
   public access" so only private channels work.
4. Apply the schema and run the checks:

   ```bash
   export ORVIX_STAGING_PROJECT_REF=<test project id>
   ```

   ```bash
   export ORVIX_STAGING_DB_URL='<the test project's Postgres connection string>'
   ```

   ```bash
   supabase/staging/apply.sh
   ```

   The script refuses the production project, applies each migration once
   (safe to run again) and finishes with `supabase/staging/verify.sql`, which
   is read-only and fails if a Watch Party table is reachable by app clients,
   a function is open to signed-out callers, or the Realtime policy is
   missing. It needs `psql`. Never put the connection string in the
   repository or in a GitHub secret; CI does not use it.
5. Deploy only the Edge Functions you need. Android TV signs in by QR code
   only, so TV testing needs these two:

   ```bash
   supabase functions deploy tv-login-link tv-login-exchange --project-ref <test project id>
   ```

   Functions that are not deployed are unavailable in test builds. Do not copy
   production function secrets into the test project unless that function is
   being tested.

## 2. Add two repository secrets (once)

Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `ORVIX_TEST_SUPABASE_URL` | `https://<test project id>.supabase.co` |
| `ORVIX_TEST_SUPABASE_PUBLISHABLE_KEY` | the test project's publishable (or legacy anon) key |

Only the public client key. Never the secret or service-role key; the build
rejects those.

## 3. Build

Actions → **Orvix CI** → Run workflow → pick the branch → tick
**watch_party_test_build**. Besides the normal jobs this runs:

- Watch Party test build (Android mobile) → `orvix-watch-party-test-android-mobile`
- Watch Party test build (Android tv) → `orvix-watch-party-test-android-tv`
- Watch Party test build (Windows) → `orvix-watch-party-test-windows`
- Watch Party test build (macOS) → `orvix-watch-party-test-macos`, plus
  `orvix-watch-party-test-macos-report` (what was checked, and a screenshot
  of both apps started on the build machine)

Download the artifacts from the run page. Without the two secrets these jobs
stop at "Check the test backend configuration".

## 4. Install

- **Android phone / TV:** install the APK (`adb install`, or open it on the
  device). It installs next to the public app. Each CI run signs with a new
  throw-away key, so uninstall "Orvix Test" before installing a newer test
  build. The APK contains all ABIs.
- **Windows:** unzip the artifact and run `orvix.exe`. Close the installed
  Orvix first: both share the single-instance guard and the stream cache, so
  only one runs at a time. The test build is the plain CI build: the bundled
  FFmpeg tools and the stream engine that the release adds are not included,
  so sources that depend on them will not play. Use direct or debrid sources.

- **macOS:** see [macOS](#macos) below.

Then create accounts in the test project (sign up inside the test app) and
follow the device plan in [WATCH_PARTY.md](WATCH_PARTY.md#device-testing-before-enabling).

## macOS

The macOS artifact is a ZIP inside the downloaded ZIP. Unpack both. The folder
holds two apps and `INSTALL.txt`:

- `Orvix Watch Party Test.app` (`com.orvix.orvix.wptest`)
- `Orvix Watch Party Test 2.app` (`com.orvix.orvix.wptest2`): the same build
  under a second identity, so two signed-in participants can run on one Mac.

Both are universal (Apple Silicon and Intel), sandboxed, and **ad-hoc
signed**. They are not signed with an Apple Developer ID and not notarized,
so macOS blocks the first start. Allow each app once: System Settings →
Privacy & Security → Open Anyway (macOS 15 and later), or right-click → Open
(macOS 14 and earlier), or remove the download mark from just these apps:

```bash
xattr -dr com.apple.quarantine "/Applications/Orvix Watch Party Test.app"
```

```bash
xattr -dr com.apple.quarantine "/Applications/Orvix Watch Party Test 2.app"
```

Do not turn Gatekeeper off for the whole Mac.

**Isolation.** macOS keeps a sandboxed app's settings, sign-in, caches and
temporary files under `~/Library/Containers/<bundle identifier>`, so the two
test apps and the public Orvix each have their own. Saved secrets go to the
login keychain under a service name of their own per app. Nothing is shared
with, or written to, the installed Orvix.

**Testing with one Mac.** Sign in to a different test account in each app,
create a room in one, join it from the other, play the same title in both
and drive play, pause and seek from the host. This exercises the real test
backend (RPC, Realtime, chat) and the player following the room. It does
**not** show cross-device behaviour: both players share one machine, one
network path and one clock. Two-device results still need two devices.

Use direct or debrid sources. The P2P engine is not bundled in macOS builds,
and both apps would share its local port.

**What CI checks for the macOS test build:** bundle identifier and name,
arm64 and x86_64 in the app, Flutter and Dart binaries, no library
dependency outside macOS and the bundle, a valid signature with the sandbox
and network entitlements, the Watch Party code and the test project address
compiled in, the committed macOS icon in the bundle, and that both apps start
and keep running on the Apple Silicon build machine. That machine is a
virtual Mac, not a MacBook; nobody looks at the screen and nothing is played.

## Limits

- iOS test builds are not produced.
- Test APKs are debug-signed; they are for private testing only.
- The test project is on the same free-tier limits as any project; pause or
  delete it when testing is over.
