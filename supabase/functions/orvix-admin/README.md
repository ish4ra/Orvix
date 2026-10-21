# orvix-admin (Control Center)

Owner-only analytics for Orvix. The function answers `POST {"action":"dashboard"}`
for the single owner account (fixed user id in `index.ts`) and returns `403` to
everyone else before any data is read. `GET` redirects to the public Orvix page.

| File | Role |
|---|---|
| `index.ts` | Wiring: Supabase reads, GitHub fetch, owner check |
| `handler.ts` | HTTP rules (CORS, methods, auth gate, errors) |
| `dashboard.ts` | Builds the payload; each part can fail on its own |
| `activity.ts` | Usage metrics from telemetry rows |
| `releases.ts` | GitHub release paging, caching and download totals |
| `platforms.ts` | Platform normalization and release-asset classification |
| `versions.ts` | SemVer ordering (`beta.9 < beta.10 < beta.100`) |
| `dashboard.html` | The Control Center page (static, hosted separately) |

```sh
deno test --allow-read --no-remote supabase/functions/orvix-admin/
```

CI runs these tests (`.github/workflows/ci.yml`, "Test analytics Edge Functions").

## What the numbers mean

The definitions are also returned in the payload (`definitions`) and shown as
tooltips on the page.

| Metric | Source | Meaning |
|---|---|---|
| Online now | `orvix_analytics_sessions` | Foreground, not ended, heartbeat < 3 min old. Heartbeats are every 60 s while the app is on screen. Not "watching". |
| Active 5 min / 24 h / 7 d / 30 d | `orvix_analytics_installations.last_seen_at` | Installations that sent any telemetry in the window. 24 h is rolling, not a calendar day. |
| Installations (all time) | installations table | Random install IDs. Reinstall or cleared data = new ID; phone and TV = two IDs. Not people, not hardware devices. |
| Signed-in accounts 30d | `user_id` on active installations | Accounts only; signed-out use is invisible here. |
| Sessions | sessions table | Launch, or return after 30 min in the background (clients from this change on; older clients keep one session per launch). |
| Daily active installations | sessions of the last 30 days | Distinct installations per UTC day. |
| Countries | `country_code` on active installations | Approximate network country. VPNs/proxies change it. `Unknown` is part of the total. |
| Platforms | `platform` on active installations | The Orvix *build* (TV build = Android TV), normalized; unrecognized labels are `Unknown`. |
| Versions | `app_version` on active installations | Latest version each installation reported, SemVer order, with the GitHub channel of that version. |
| All-time version reach | sessions table | Distinct installations that ran each version at least once. |
| GitHub downloads | GitHub REST API | `download_count` of app assets in public releases. Includes re-downloads, in-app update downloads and CI/test downloads. **Not installations or users.** Drafts and the `orvix-stream-server` component are listed but not counted. |

Every count carries a state: `ok`, `stale` (no telemetry for 6 h), `no_data`
(tables empty) or `unavailable` (query failed). A failed query is never shown
as `0`.

What is **not** measurable from this data and is not shown: unique people,
unique hardware devices, installs that never launched, historical installs
before telemetry existed (first shipped in v0.7.9-beta.63), and whether a
person is watching something. GitHub download counts cannot be converted into
any of these.

## Deploying (owner, manual)

Nothing in CI deploys Supabase. In order:

1. Apply `supabase/migrations/20261021120000_analytics_dashboard_indexes.sql`
   (one additive index; optional but recommended).
2. Deploy both functions from the repository root:
   `supabase functions deploy orvix-telemetry --no-verify-jwt` and
   `supabase functions deploy orvix-admin --no-verify-jwt`.
   Both run with `verify_jwt` off today (`docs/SUPABASE_SECURITY.md`); the
   owner check inside `orvix-admin` is what protects the data. Confirm the
   production setting before deploying and keep it unchanged.
3. Optional: set a GitHub token for the function to avoid GitHub's shared
   unauthenticated rate limit (60 requests/hour per egress IP):
   `supabase secrets set ORVIX_GITHUB_TOKEN=<fine-grained, read-only, Orvix repo, Contents: read>`.
   With repository access, draft releases become visible to the owner page
   (listed as Draft / Private, never in totals). Without the secret everything
   works; GitHub data is cached for 10 minutes and served as stale on errors.
4. Replace the hosted Control Center page with `dashboard.html`. It calls
   `https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/orvix-admin`
   directly, so it works from any origin. An older copy of the page keeps
   working against the new function (the legacy fields are still returned).
5. Check: sign in, confirm the "Backend and telemetry health" panel shows
   every section OK, and that "Latest telemetry" is minutes old.

Rollback: redeploy the previous function version from Git; the migration is
an index and can stay.
