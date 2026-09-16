# Pikora

Pikora is an experimental Windows desktop media client focused on a simple PikPak-connected workflow.

## Current status — v0.2 prototype

The current prototype includes:

- PikPak sign-in flow with captcha/verification handling
- PikPak cloud library listing and title matching
- Movie / TV type-ahead search after 2+ characters
- Recent searches and a local watchlist
- Dark media-center style UI
- Windows x64 build

### Known v0.2 limitation

The v0.2 executable starts a local Pikora backend and launches the UI using **Microsoft Edge in `--app` mode**. This means the v0.2 build currently requires `msedge.exe` to be installed. This is a prototype shortcut, not a fundamental Pikora requirement.

The next desktop build should remove the direct Edge-browser dependency and use a self-contained/native UI approach (or a bundled runtime).

## Build v0.2

Requires Go 1.22+ on Windows, Linux, or macOS.

### Windows

```powershell
go build -ldflags="-H=windowsgui" -o Pikora-v0.2-Windows-x64.exe main_windows.go
```

### Cross-compile for Windows x64

```bash
GOOS=windows GOARCH=amd64 go build -ldflags="-H=windowsgui" -o Pikora-v0.2-Windows-x64.exe main_windows.go
```

## Notes

- PikPak integration uses undocumented/community-observed endpoints and can break when PikPak changes its authentication or API behavior.
- Search metadata in v0.2 uses IMDb's lightweight suggestion endpoint.
- Pikora does not store the user's PikPak password in v0.2.

## Roadmap

- Remove the direct Microsoft Edge dependency
- Improve PikPak verification/login reliability
- Full Home / Movies / TV browsing UI
- Rich movie and TV detail pages
- Seasons and episodes
- Better PikPak file matching and playback
- Continue Watching / persistent library improvements

This repository currently tracks an early prototype and will change frequently.