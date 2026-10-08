# Orvix privacy policy

_Last updated: 2026-10-08_

Orvix is a networked media application. It talks to the Orvix account backend, to GitHub, and to the metadata, source, subtitle, and cloud services that you use through it. This page explains what leaves your device, when, and where it goes.

It describes the Orvix app as published in this repository ([ish4ra/Orvix](https://github.com/ish4ra/Orvix)) for Windows, macOS, Android, and Android TV. Builds from other places are not covered.

Orvix is maintained by [@ish4ra](https://github.com/ish4ra). Questions about this policy can be raised on the repository's GitHub issue tracker. For anything you don't want to post publicly, contact the maintainer through their GitHub profile.

## Summary

- **Every time Orvix runs**, it sends usage analytics and crash diagnostics to the Orvix backend. These include a random installation ID, the app version, your platform and device type, and your language setting. Orvix also checks GitHub for updates and loads catalogs from public metadata services.
- **When you use a feature**, Orvix sends what that feature needs to the service behind it. Examples: titles you look up, the IMDb ID of what you play, your cloud/debrid tokens to that provider, subtitle text for AI translation.
- **Your Orvix account is optional.** Without one, your library, watchlist, progress, and settings stay on your device.
- **Orvix does not ask for location permission** and does not read GPS data. It does not show ads.

## 1. Sent automatically

These requests happen without you turning anything on.

### Usage analytics and error diagnostics (Orvix backend)

Orvix sends small telemetry messages to the Orvix backend, which runs on [Supabase](https://supabase.com). They are sent when the app starts, every 60 seconds while it is in the foreground, when it moves to the background or resumes, when it closes, and when you sign in or out.

Each message can contain:

- a random **installation ID** created on first launch and a random **session ID** created each time the app starts;
- platform (for example Windows, Android Mobile, Android TV), operating system version string, language/region setting (for example `en-US`), app version and build number;
- device type (Desktop, Mobile, TV) and, on Android, device manufacturer and model;
- whether the app is in the foreground;
- event names such as "app resumed" or "signed in";
- for app errors: error type, error message, and stack trace.

If you are signed in to an Orvix account, the backend links these records to your account ID.

The backend records a **two-letter country code** for each installation. It reads the country from the network request when the hosting platform provides one. Otherwise it sends your IP address to the third-party lookup service [country.is](https://country.is) to look up the country. The analytics records keep only the country code, not the IP address. Request logs kept by the hosting providers themselves (Supabase and its infrastructure) are outside what this repository controls.

There is currently no in-app switch to turn analytics off.

### Update checks (GitHub)

Orvix checks the [GitHub releases of ish4ra/Orvix](https://github.com/ish4ra/Orvix/releases) for newer versions, using the GitHub API and the public release feed. When you accept an update, the new installer or APK is downloaded from GitHub. GitHub receives normal request information such as your IP address and the `Orvix-Updater` user agent.

### Catalogs and metadata

To show Home rows, title pages, and search results, Orvix requests public catalog and metadata data from [Cinemeta](https://www.stremio.com) (Stremio), [IMDb](https://www.imdb.com), and [AIOMetadata](https://elfhosted.com) (ElfHosted). These services receive the IMDb IDs of the titles being shown and, when you search, your search text.

### Skip intro / recap segments

While you watch, Orvix asks [IntroDB](https://introdb.app) for intro and recap timestamps by sending the title's IMDb ID and, for episodes, the season and episode number. This is on by default and can be turned off in Settings.

## 2. Sent only when you use a feature

### Orvix account

Creating an account and signing in uses Supabase Authentication. Your **email address** and **password** go to the Orvix backend. Supabase sends verification and password-reset emails to that address.

While you are signed in, Orvix syncs these to your account so they follow you to other devices:

- watchlist, library, and continue-watching progress;
- Home row layout and preferred cloud provider;
- app settings that Orvix stores under its own settings names. This includes the random analytics installation ID, and it excludes your source add-on list and Torrentio address, which stay on the device.

**Android TV QR sign-in:** the TV creates a short-lived sign-in session on the Orvix backend. You approve it from a signed-in phone or computer.

**Deleting your account:** the in-app account deletion removes your account, your synced data, your synced provider credentials, and your TV sign-in sessions. Analytics records already linked to the account are unlinked from it, but are not removed by this step.

### Cloud provider credentials sync

If you are signed in and connect TorBox, Real-Debrid, Premiumize, or PikPak, Orvix uploads that provider's sign-in data to your Orvix account so other devices signed in to the same account can use it:

- TorBox, Real-Debrid, Premiumize: the access token or API key;
- PikPak: access token, refresh token, username, and user ID. PikPak's device ID and CAPTCHA token stay on the device.

The upload is sent over HTTPS to a credential store tied to your account. That store is designed to encrypt the data at rest. Its server-side code is not part of this public repository. Disconnecting a provider removes its credentials from your account. Without an Orvix account, provider credentials are kept only on the device.

### Cloud and debrid providers

When you connect [TorBox](https://torbox.app), [Real-Debrid](https://real-debrid.com), [Premiumize](https://www.premiumize.me), or [PikPak](https://mypikpak.com), Orvix talks to that provider directly with your credentials. It sends what is needed to list your files, check availability, add torrents, magnet links or web links you choose, and get playback links. Each provider handles this under its own terms and privacy policy.

### Source providers

When you look for sources for a title, Orvix sends the title's **IMDb ID** (and season/episode for series) to each enabled Stremio-compatible source provider. Out of the box these are [Torrentio](https://torrentio.strem.fun), [Comet](https://comet.elfhosted.com), and [MediaFusion](https://mediafusion.elfhosted.com), plus any add-on you install. Add-on addresses you enter are used exactly as you entered them, including any settings or keys they contain.

### P2P / torrent playback

When you play a torrent source without a cloud provider, Orvix's local streaming engine joins the BitTorrent network for that torrent. As with any BitTorrent client:

- your **IP address** and the torrent you are downloading are visible to other peers, to trackers, and to the DHT network;
- pieces you have downloaded may be uploaded to other peers while the engine runs.

The player connects to that engine locally on your device (`127.0.0.1`). Temporary torrent cache files are stored locally, and Orvix cleans them up.

### Subtitles

- **OpenSubtitles (Stremio add-on):** for subtitle search, Orvix sends the IMDb ID (and season/episode) to the OpenSubtitles add-on at `strem.io`. For exact matching it can also send the video's **hash, file size, and file name**.
- **OpenSubtitles exact match:** some AI Sinhala lookups send the video hash and file size to the Orvix backend, which queries [OpenSubtitles.com](https://www.opensubtitles.com).
- **SubDL:** some subtitle lookups send the IMDb ID to the Orvix backend, which queries [SubDL](https://subdl.com).

### AI Sinhala subtitles (off by default)

AI Sinhala must be turned on in Settings.

- **Subtitle translation:** English subtitle text for the title you are watching is sent to the Orvix backend. The backend uses [Google Gemini](https://ai.google.dev) to translate it. Translation requires you to enter your own Gemini API key in Settings. Orvix stores that key on the device and sends it with each translation request to the Orvix backend.
- **Audio transcription:** when no usable subtitle exists, Orvix extracts **short audio clips** from the video and sends them, with the title name, to the Orvix backend. The backend uses Google Gemini to transcribe them.

### Supporters and donations

The Supporters screen loads the public supporter list from the Orvix backend and the contributor list from GitHub. Donation buttons open [Ko-fi](https://ko-fi.com), [Buy Me a Coffee](https://buymeacoffee.com), or [GitHub Sponsors](https://github.com/sponsors) in your browser. Orvix does not handle payments.

If you donate, that platform notifies the Orvix backend. The backend stores your supporter display name, avatar, profile link, tier, and dates. New supporters are not shown publicly unless they are marked public.

### Links

Links to the Orvix website, Fosstodon, Lemmy, and GitHub open in your browser and are governed by those sites.

## 3. Kept on your device

- Library, watchlist, continue-watching progress, Home layout, source add-ons, and settings are kept in local app storage.
- Cloud provider credentials and your Gemini API key are kept in the platform's secure storage.
- Image, subtitle, and playback caches are kept locally.
- On Windows, AI Sinhala and crash diagnostics are written to a local log file (`ai-sinhala.log`) in Orvix's app data folder. This file is not uploaded automatically.

Uninstalling Orvix, or clearing its app data, removes this local data. Data already synced to an Orvix account stays there until you delete the account.

## 4. Third-party services

Orvix relies on these services. Each one handles the data it receives under its own privacy policy:

| Service | Used for |
|---|---|
| [Supabase](https://supabase.com) | Orvix backend: accounts, sync, analytics, subtitle and AI functions |
| [GitHub](https://github.com) | Update checks, downloads, contributor list, GitHub Sponsors |
| [Google Gemini](https://ai.google.dev) | AI Sinhala translation and transcription (through the Orvix backend) |
| [country.is](https://country.is) | Country lookup for analytics (through the Orvix backend) |
| [Stremio](https://www.stremio.com) (Cinemeta, OpenSubtitles add-on) | Metadata and subtitle search |
| [IMDb](https://www.imdb.com) | Catalogs and metadata |
| [ElfHosted](https://elfhosted.com) (AIOMetadata, Comet, MediaFusion) | Metadata and source providers |
| [Torrentio](https://torrentio.strem.fun) | Source provider |
| [IntroDB](https://introdb.app) | Intro/recap skip segments |
| [OpenSubtitles](https://www.opensubtitles.com), [SubDL](https://subdl.com) | Subtitles (through the Orvix backend) |
| [TorBox](https://torbox.app), [Real-Debrid](https://real-debrid.com), [Premiumize](https://www.premiumize.me), [PikPak](https://mypikpak.com) | Cloud/debrid playback, only if you connect them |
| BitTorrent peers and trackers | P2P playback, only when you play a P2P source |
| [Ko-fi](https://ko-fi.com), [Buy Me a Coffee](https://buymeacoffee.com) | Donations, only if you choose to donate |

## 5. Retention

Apart from the deletions described above, Orvix does not currently define an automatic retention period for account data, synced data, analytics, error reports, or supporter records. This repository contains no scheduled clean-up for them. If retention periods are introduced, this policy will be updated.

## 6. Changes

This policy is kept in the Orvix repository. Its full change history is available in [git history](https://github.com/ish4ra/Orvix/commits/develop/PRIVACY.md). When Orvix starts sending new kinds of data, this policy will be updated.
