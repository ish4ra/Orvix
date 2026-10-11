# TorrentCheap provider research

Status: **blocked, research and offline adapter only.** TorrentCheap is not a
user-visible provider in Orvix. Nothing in the app constructs the adapter, and
no network transport exists for it.

Tracking issue: #86.

## Summary

TorrentCheap (torrentcheap.com) is a Sri Lanka-operated cloud torrent service.
It downloads a magnet to the user's cloud storage and streams the result in the
browser as transcoded HLS. Technically, its feature set fits Orvix's
cloud-provider model: magnet in, task progress, cloud files, playable stream.
What stops an integration is permission and authentication, not capability:

1. **No third-party API is published.** There are no API docs, API keys,
   OAuth client registration or developer terms.
2. **The Terms of Service forbid reverse-engineering the service.** The
   Acceptable Use section bars users from disrupting, overloading,
   reverse-engineering or gaining unauthorised access to the service or its
   infrastructure. A client built by replaying the website's internal
   `/api/tasks/*` requests is reverse-engineering, however carefully done.
3. **Authentication is browser-bound.** The privacy policy describes sign-in by
   email/password or Google, protected by CAPTCHA and httpOnly session cookies.
   Orvix could only reuse that by collecting user passwords or harvesting
   browser cookies, and it will do neither.

So Orvix stops at the offline adapter described below, as #86 requires when the
provider does not permit independent clients.

## What was checked, and how

| Source | Result |
| --- | --- |
| Direct fetch of torrentcheap.com (site, scripts, `/terms-and-conditions`, `/privacy-policy`) | **Not possible from the build environment.** Its network policy denied the host, so the shipped frontend JavaScript was not inspected. |
| Web search for API, developer docs or third-party client terms | None found. |
| Search-indexed Terms & Conditions | Service is free "right now", provided "as is", operated from Sri Lanka, updated 13 Sep 2026. Acceptable Use forbids reverse-engineering. The excerpt was truncated, so other automation clauses may exist. |
| Privacy policy (via #86) | Google sign-in, CAPTCHA, httpOnly cookies, logs submitted magnets and technical data. |
| Owner's Firefox Network screenshots (via #86 and the task brief) | Endpoint paths and status codes, listed below. No payloads, headers or response bodies. |

## Endpoint evidence

All paths are on `www.torrentcheap.com` and were seen in the website's own
traffic. **No request or response schema is confirmed.** Status codes come
from the owner's screenshots.

| Observed request | Status | Confirmed | Still unknown |
| --- | --- | --- | --- |
| `POST /api/tasks/get-meta-details` | 200 | JSON body has a `magnet` key. The response lets the UI list selectable files (7 files, ~2.67 GB in the test). | Response schema, file index/id format, errors for bad magnets. |
| `POST /api/tasks/accept-user-task` | 200 | Sent on "Add to downloads". | Payload (selection format), response (task id?), errors for the task limit and quota. |
| `GET /api/tasks/ongoing-count` | 200 | Active task count. | Response shape. Whether it carries progress (assume not). |
| `POST /api/tasks/get-my-tasks` | 200 | Active task list. | Schema, states, progress units, pagination. |
| `POST /api/tasks/get-task-history` | 200 | Completed tasks appear here. | Schema, retention, whether failures appear. |
| `POST /api/.../list-my-files-at` | 200 | Cloud folder browsing. | **Full path unconfirmed.** Folder id format, pagination, file metadata. |
| `GET .../list?videoPlayHash=…&userFileHash=…` | 200 (JSON) | Part of the playback flow. | Full path, response, whether it returns the HLS URL, and what the two hashes are. Neither is assumed to be a credential. |
| HLS on `s08.torrentcheap.com`, path `/files/video-stream/…/master.m3u8` | 200, `application/vnd.apple.mpegurl`, `Access-Control-Allow-Origin: *` | Master playlist with `480p.m3u8`, `800p.m3u8`, `audio.m3u8`, `thumbnails.vtt`, fMP4 init segments and `.m4s` segments. | Whether the playlist needs a cookie, Referer or signed query; URL lifetime; whether segments are authorized separately. |

Not observed at all: login/token endpoints, logout, task deletion, file
deletion, account quota, original-file download links, subtitle tracks.

The common `/api/tasks/*` POST pattern suggests a same-origin backend called
by the site's frontend with its session cookie. Whether it also checks CSRF
tokens, Origin or the CAPTCHA session was not determined: the frontend could
not be fetched, and probing it with a user's cookies is what the Terms forbid.

## Streaming

- Playback is **transcoded HLS** (480p and 800p video renditions plus a
  separate audio rendition). There is no evidence of original-file streaming
  or HTTP Range access to the original bytes.
- That has consequences for Orvix:
  - Embedded subtitle tracks from the original file are probably lost.
  - The AI Sinhala moviehash lookup cannot match transcoded bytes. The PikPak
    transfer service avoids transcoded renditions for the same reason.
  - The best quality seen is 800p.
- `Access-Control-Allow-Origin: *` only matters to browsers. It says nothing
  about whether the CDN checks cookies, signed parameters or Referer.
- **MPV playback has not been tested on any platform.** A legitimate
  authenticated test was not possible. mpv/media_kit plays fMP4 HLS master
  playlists in general, and `PlaybackService.open` already accepts
  `httpHeaders`. Whether TorrentCheap's CDN serves an outside client is
  unknown.

## What is implemented

Three files, none imported by the app:

- `lib/services/torrentcheap_models.dart`: provider-neutral models for
  magnet files, tasks, cloud entries, playback sources and typed errors. No
  field claims to be a confirmed JSON key.
- `lib/services/torrentcheap_service.dart`:
  - `TorrentCheapGateway`: an abstract contract with one method per observed
    capability (metadata, create task, active count, active tasks, history,
    folder listing, resolve playback).
  - `TorrentCheapService`: the orchestration on top of the gateway.
    - Magnet validation, with hex and base32 info hashes.
    - Selection validation, and an advisory five-task limit.
    - Reuse of a completed task with the same info hash, to avoid spending quota twice.
    - Status lookup across active tasks and history.
    - Polling with stall and timeout detection.
    - Paginated folder listing with loop protection.
    - Recursive video selection.
    - Playback resolution: https and `*.torrentcheap.com` only, with one re-resolve when a link is near expiry.
    - Error mapping that never echoes transport text.
    - Log redaction of magnets, URL queries, stream ids and credential headers.
  - It is disabled unless built with `--dart-define=ORVIX_EXPERIMENTAL_TORRENTCHEAP=true`. Even then it stays unavailable, because no gateway implementation exists.
- `lib/services/torrentcheap_hls.dart`: a master-playlist parser (variants,
  resolution labels, audio and subtitle renditions), plus a one-request probe.
  The probe checks status and content type, and maps 401/403, 404/410 and 429
  to typed errors before anything reaches the player.

Tests: `test/torrentcheap_service_test.dart` and `test/torrentcheap_hls_test.dart`
(39 tests). They use a fake gateway and `MockClient`, with synthetic hashes,
ids and playlists. No real torrent, account or stream URL is in the repository.

Deliberately **not** done:

- No HTTP gateway against `/api/tasks/*`. There are no confirmed schemas, and
  the Terms forbid reverse-engineering.
- No login screen and no credential storage.
- No `CloudProvider` enum entry, settings UI or source-flow hook.
- No change to the player, PikPak, TorBox, Real-Debrid, Premiumize, P2P,
  subtitles or the updater.

## What would unblock it

All of these are needed before a real gateway is written:

1. **Written permission from the operator** for third-party clients (the site's
   Contact page), plus a documented, non-browser auth model: an API key,
   OAuth or device-code flow. Not password replay and not cookie reuse.
2. **Confirmed schemas** for each operation above, captured from a consenting
   test account using a public-domain magnet (for example Big Buck Bunny). They
   then become the gateway's mock fixtures.
3. **Header names (not values)** on the `master.m3u8` request, to learn whether
   it needs Cookie, Authorization, Referer or a signed query.
4. **An authorized MPV test** of one stream on Windows, Android Mobile and
   Android TV. It covers start, seek, pause/resume, 480p/800p switching, A/V
   sync, and behavior once the URL expires.
5. **Written limits:** storage per user, the task limit, bandwidth, retention
   and rate limits. The 100 GB and 5 tasks seen on one account, and the 50 GB
   on the marketing page, are not documented guarantees.

## Recommendation

Do not list TorrentCheap among Orvix's recommended providers. It has no
sanctioned client interface, its auth is browser-bound, it serves transcoded
800p output only, and its plan terms are undocumented and "free right now".
Revisit this if the operator publishes or grants an API.
