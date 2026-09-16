# Orvix Roadmap

## v0.3 — Flutter desktop foundation

- [x] Move product direction to Flutter/Dart
- [ ] Remove the Edge executable dependency completely
- [ ] Native Flutter Windows window and dark media UI
- [ ] PikPak captcha-aware sign-in
- [ ] Secure token/device storage
- [ ] PikPak cloud library browser
- [ ] Home / Search / Library / Settings navigation
- [ ] Search suggestions after 2+ characters
- [ ] Movie / TV detail screen foundation
- [ ] Windows GitHub Actions build artifact

## v0.4 — Media library experience

- [ ] Trending/popular movie and TV rails
- [ ] Genres and infinite scrolling
- [ ] Seasons and episodes
- [ ] Better title/episode-to-cloud-file matching
- [ ] Watchlist
- [ ] Continue Watching
- [ ] Local watch history
- [ ] Built-in media_kit/libmpv player
- [ ] Audio/subtitle track selection

## v0.5 — Source provider framework

- [ ] Provider interface for user-configured/authorized sources
- [ ] Check PikPak cloud first
- [ ] Send an authorized resolved URL/magnet to PikPak
- [ ] Track transfer/cache state
- [ ] Auto-select the matching video from completed tasks
- [ ] One-click play when the cloud item becomes ready
- [ ] Stremio-compatible catalog metadata support

Orvix will not bundle a hard-coded piracy index or preconfigured infringing source list. Source integrations must be user-configured and used only with content the user is authorized to access.

## v0.6 — Windows polish

- [ ] Installer
- [ ] Auto update
- [ ] App icon and splash
- [ ] Keyboard shortcuts
- [ ] Player mini controls
- [ ] Crash/error reporting opt-in
- [ ] Signed release path when a certificate is available

## v1.0 — Android / Android TV

The Dart services/domain layer is intended to be reused.

- [ ] Android phone/tablet build
- [ ] Android TV layout and D-pad navigation
- [ ] Secure Android credentials
- [ ] Background transfers/downloads
- [ ] Android media session / picture-in-picture
- [ ] TV-friendly player controls

Native Kotlin code should be introduced only for Android-specific features where Flutter plugins are not sufficient, rather than rewriting the whole application.
