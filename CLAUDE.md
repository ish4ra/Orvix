# CLAUDE.md — Orvix

Rules for Claude Code sessions in this repository. They exist to stop working Orvix behavior from being broken by accident. `AGENTS.md` also applies; where the two overlap, follow the stricter rule.

## Repository reality (verify before relying on it)

- **Branch roles:**
  - `main` is formally the stable branch, according to `AGENTS.md`.
  - `develop` is the canonical prerelease integration branch.
  - The current, modern application lives on `develop`. That makes **`develop` the active development source of truth** for current implementation work, unless the repository state later shows otherwise.
  - Check `develop` at the start of every task, for example: `git fetch origin develop`, `git log origin/develop -5`, `pubspec.yaml` version.
- **Never assume `main` holds current code.** `main` is far behind `develop`, has diverged from it, and holds old (0.7.2-era) app code plus docs and licence changes.
- **Historical code:** `main`, old `orvix-v0.*` branches, `release/*` branches and old tags must never be treated as the current source of truth.
  - You may inspect them, or deliberately use them to recover from a regression, when that is justified.
  - Any recovered code must be checked against current `develop`, and the reason for using it must be stated.
  - Never replace a newer fix with older code.
- **One Flutter codebase, four products:**
  - Android Mobile
  - Android TV: compile-time flag `--dart-define=ORVIX_TV=true`, see `lib/services/platform_profile.dart`
  - Windows: `windows/` is committed
  - macOS
- **Android and macOS projects are generated in CI, not committed.** CI runs `flutter create`, then the scripts in `tools/` patch the result: manifest, Kotlin, Gradle, signing, branding, native libraries. Changing Android or macOS behavior usually means editing `tools/*.py` or `tools/*.sh`, not an `android/` or `macos/` folder.
- **Mobile and TV builds differ** in manifest, scripts, dart-define, navigation and focus, player and subtitle rendering, P2P tuning, and update asset.
- **Fragile areas with past cross-platform regressions:** the player, subtitles, aspect ratio and black-bar crop, and AI Sinhala, all in `player_screen.dart` and `details_screen.dart`. Some comments there do not match the code's actual behavior, so trust the code, not the comments.
- **Pinned native pieces:**
  - media_kit Debrify fork commit in `pubspec.yaml`
  - Windows stream-server release tag
  - Stremio Android native libraries
  - FFmpeg bundling
  - full-libmpv JAR hashes

  Do not bump or replace any of them unless asked.
- **Workflows** (only two exist):
  - `.github/workflows/ci.yml` validates and builds. It never publishes.
  - `.github/workflows/prerelease.yml` is the only workflow that publishes.
- **CI builds and release builds are not configured identically.** Signing, branding, bundled engines, the installer and some Android patch steps differ between them. When build behavior is in question, compare the matching jobs in both files step by step.
- **The release system is currently version-specific.** Each release cuts `release/all-v<version>`, edits `prerelease.yml`'s trigger branch and concurrency group, and bumps `pubspec.yaml`. `prerelease.yml` also hard-codes historical baseline versions. Do not rewrite this system casually.
- **`pubspec.yaml` is the version source of truth.**
  - Format: `X.Y.Z-stage.N+BUILD`. Tag = `v` plus the version without `+BUILD`.
  - `+BUILD` must increase on every release.
  - `+BUILD` is also the Android versionCode of every Android APK, and must stay above 4205 (the highest versionCode the old ABI-specific APKs used); `prerelease.yml` fails otherwise. See `tools/verify_android_apk.py`.
  - The in-app updater reads GitHub releases (prereleases included), matches on asset names, and compares versions.

## Scope rules

1. Before any task, inspect the current `develop` state and the exact implementation involved.
2. **Investigating is not permission to modify.** Report findings and wait.
3. Change only the code your explicit request requires. Prefer the smallest safe change.
4. **Never silently fix unrelated issues** you notice along the way. List them separately in your report. Do not put unrelated fixes in the same change.
5. Keep the existing architecture unless the user explicitly asks for a redesign or refactor.
6. **Out of bounds unless explicitly in scope:** subtitle behavior, player behavior, aspect ratio and resize, AI Sinhala, P2P/torrent engine, debrid and cloud providers, auth and TV QR login, the updater, and navigation and focus.
7. **Never revert an existing working fix** while working on something new. Before editing, trace the affected code path and read the recent history of the files you will touch (`git log -p -- <file>`), including the regression tests that guard them.
8. **Treat Android Mobile, Android TV, Windows and macOS as separate regression surfaces.** A fix for one platform must not change another. If it unavoidably does, say so explicitly.
9. **Do not change any of the following without explicit approval:**
   - application IDs
   - signing identity or certificate
   - update compatibility (asset names, tag format, version parsing, installer AppId and paths)
   - database schema or migrations
   - authentication backend
   - Supabase or other production backend configuration
   - pinned native dependencies

## Validation

- Add or update focused regression tests in `test/` when a bug is fixed or a behavior is locked in.
- Run the checks that `ci.yml` runs, at minimum:
  - `flutter pub get`
  - `flutter analyze lib --no-fatal-warnings --no-fatal-infos`
  - `flutter test`
  - `cd tools/orvix-media-engine && go test ./...`
- Syntax-check any build helper you touched (`python3 -m py_compile ...`, `bash -n ...`).
- Every affected platform must pass its build validation, either locally where possible or through `ci.yml`. If a platform could not be validated, say so; do not claim it works.
- If a change affects how things are built, confirm the release job in `prerelease.yml` would actually pick it up. Passing CI does not prove that.

## Commits, branches and releases

- Work on a short-lived `fix/*`, `feature/*` or `maintenance/*` branch from `develop`, unless the session assigns a different branch.
- Before any commit, push or release, inspect the full final diff (`git diff origin/develop...HEAD`) and remove anything unrelated.
- **Never force-push.**
- **Never delete** branches, tags, releases, workflows, secrets or production configuration without explicit instruction.
- **Asking for a fix is not permission to release.** Only release when explicitly asked.
- **Asking for a release** means: release only after the requested changes are complete and all required validation has passed. If validation fails, do not publish, and report the failure.
- **Unless the user explicitly says "stable release", every Orvix release is a prerelease/beta** using the existing beta versioning convention (`X.Y.Z-beta.N+BUILD`).
- **Never infer that a beta, dev, fix or feature task should become a stable release.**
- **Use the repository's supported release workflow** for the requested release type. Never improvise a manual GitHub release.
  - Beta/prerelease releases currently go through `prerelease.yml`.
  - If a stable release is explicitly requested and no supported stable-release path exists, stop and report that, unless the task explicitly authorizes repairing or adding that path.
  - Never silently turn a stable release request into a prerelease.
- **Keep the verification in `tools/publish_orvix_release.sh`:** it uploads to a draft, checks every expected asset, then publishes. Never bypass artifact verification.
- Never publish a release just to test CI, and never from an old or historical branch.

## Repository-facing text

- Do not add AI attribution or AI artifacts unless the user explicitly asks for them. This includes:
  - Claude Code branding
  - Claude session links
  - "Generated by Claude Code"
  - bot-style signatures

  It applies to commit messages, PR titles and descriptions, release notes, documentation and source files.
- Keep repository-facing text natural and about the project.
- Do not mention Claude or AI just because Claude did the work.

## Pull request completion

- When the user explicitly authorizes completing a task end-to-end, Claude may:
  1. commit and push;
  2. open the PR;
  3. wait for required CI and reviews;
  4. merge the PR into `develop`.
- **Never merge while required CI or review checks are pending or failing.**
- Never merge a PR that contains unrelated changes.
- If a required check fails or a blocking review finding appears, stop and report the blocker instead of merging.
- After a successful merge, delete the short-lived source branch when it is safe to do so.
- Do not ask the user to merge an approved, fully validated PR by hand, unless GitHub permissions or repository rules prevent automatic merging.

## Efficiency

- Do not rescan the whole repository when the task is scoped. Read only the files, history, tests and workflows relevant to the change.
- Do not spawn multiple exploration agents unless the problem genuinely needs cross-cutting investigation.
- Do not repeat architecture explanations already in `CLAUDE.md` or `AGENTS.md`.
- Keep progress narration minimal. Do the work and return a concise result.
- Match validation to the change:
  - Full multi-platform validation is required for release work and genuinely cross-platform changes.
  - It is not required for documentation-only changes.
- Prefer finishing a well-scoped task end-to-end in one session over stopping repeatedly for approvals that aren't needed.

## Secrets and security

- Never put credentials or secret values in source code, logs, chat output, commit messages, PR text or generated files.
- Report security findings by file path and line and describe the problem. **Never repeat the secret value.**
- If a hard-coded credential or secret is discovered, do not echo, copy, move, reuse or print the value. Report the location and risk without revealing the value.
