# Orvix repository maintenance rules

Orvix uses a deliberately small branch and release model.

## Canonical branches

- `main` is the stable branch.
- `develop` is the canonical prerelease integration branch.
- Short-lived `feature/*`, `fix/*`, and `maintenance/*` branches must start from `develop` and merge back into `develop`.
- Never publish a release from an old feature branch.
- Historical branches may be kept for recovery, but they are not valid release sources.

## Release rules

- `pubspec.yaml` is the version source of truth.
- The only active release workflow is `.github/workflows/prerelease.yml`.
- Do not hard-code old feature names, bug names, or release notes into future release titles.
- Do not create one workflow file per alpha/beta release.
- Do not publish a release merely to test CI. Use `.github/workflows/ci.yml`.
- Before a prerelease, CI must pass analyze, Flutter tests, media-engine tests, and platform build validation.
- Do not replace a newer fix with code copied from an older branch or tag.

## Change scope

- Preserve platform-specific scope. A mobile-only UI fix must not silently change Android TV, Windows, or macOS behavior.
- Do not touch playback, P2P, debrid, subtitle, AI Sinhala, updater, or authentication code unless the requested change requires it.
- When fixing a regression, inspect the current implementation and relevant regression tests before editing.
- Add or update regression coverage for bugs that previously returned.

## Automation

- CodeRabbit reviews PRs targeting `develop` or `main`.
- Renovate targets `develop`; dependency PRs must pass the same CI before merge.
- Keep GitHub Actions generic and reusable. Avoid version-specific workflow filenames and stale trigger comments.
