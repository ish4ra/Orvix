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
| `web/` | The Control Center page (static, hosted on the website; see below) |
| `e2e/` | Browser test for the page |

```sh
deno test --allow-read --no-remote supabase/functions/orvix-admin/
```

CI runs these tests (`.github/workflows/ci.yml`, "Test analytics Edge Functions").
They include `web_test.ts`, which checks that the page loads scripts only from
its own origin, that the vendored supabase-js matches its checksums and the
page's SRI hash, and that no secret key is embedded.

The browser test runs the real page and the vendored supabase-js in Chromium
against faked Supabase Auth and function responses (sign-in, wrong password,
network failure, session restore after reload, dashboard render, backend 500,
403 sign-out, sign-out, missing vendor files) and fails on any request to a
host other than the page's own origin and the Supabase project. It needs
Node, Deno and Playwright, so it is run locally, not in CI:

```sh
node supabase/functions/orvix-admin/e2e/dashboard_e2e.cjs
# PLAYWRIGHT_MODULE=/path/to/node_modules/playwright CHROMIUM_PATH=/path/to/chromium if needed
```

## The Control Center page (`web/`)

Supabase serves Edge Function HTML as plain text, so the page is a static
site on the Orvix website. It is currently hosted by GitHub Pages from
`ish4ra/ish4ra.github.io` at `orvix/console/index.html`
(`https://isharalakshan.xyz/orvix/console/`). That live copy predates this
change and still loads `@supabase/supabase-js@2` from esm.sh.

These files are hosted **together, in one directory, with the same relative
layout**:

```
index.html                                  the page
app.js                                      page logic (same-origin module)
vendor/supabase-js/2.45.4/supabase.js       supabase-js browser build (UMD)
vendor/supabase-js/2.45.4/591.supabase.js   lazy chunk of that build (WebSocket fallback, normally never loaded)
vendor/supabase-js/2.45.4/LICENSE           MIT licence of supabase-js
```

`SHA256SUMS` in the vendor directory is for verification and need not be
hosted. Nothing loads from a CDN: `index.html` carries a Content Security
Policy (`script-src 'self'`, `connect-src` limited to the Supabase project)
and pins `supabase.js` with a Subresource Integrity hash, so a missing or
altered file stops the page instead of running something else. The only key
in the page is the public publishable key (the same one the app ships); no
service-role or secret key is involved.

### Updating supabase-js

`tools/vendor_supabase_js.sh` downloads the pinned npm tarball, checks it
against the registry integrity recorded in the script, and extracts the
browser build. No npm install and no package scripts run.

```sh
tools/vendor_supabase_js.sh --check   # rebuild in a temp dir; must match the committed files
```

To move to another version: change `VERSION` and `INTEGRITY` in the script
(`npm view @supabase/supabase-js@<v> dist.integrity`), run it, update the
`vendor/supabase-js/<v>/` path and the `integrity` value it prints in
`web/index.html`, delete the old version directory, and run the Deno and
browser tests.

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
   (one additive index; optional but recommended). See "Index migration"
   below for the lock it takes and how to avoid it.
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
4. Publish the page: in `ish4ra/ish4ra.github.io`, replace
   `orvix/console/index.html` with the files listed under "The Control
   Center page", keeping the layout (`orvix/console/index.html`,
   `orvix/console/app.js`, `orvix/console/vendor/supabase-js/2.45.4/...`).
   The page calls
   `https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/orvix-admin`
   directly, so it works from any origin. An older copy of the page keeps
   working against the new function (the legacy fields are still returned),
   so steps 2 and 4 can happen in either order.
5. Check in a private window: sign in; the browser's network panel shows no
   request to esm.sh; the "Backend and telemetry health" panel shows every
   section OK and "Latest telemetry" is minutes old; reload keeps you signed
   in; Sign out returns to the login.

Rollback: redeploy the previous function version from Git and restore the
previous `orvix/console/index.html`; the migration is an index and can stay.

## Index migration

`20261021120000_analytics_dashboard_indexes.sql` adds one index,
`orvix_analytics_sessions_started_idx` on `orvix_analytics_sessions
(started_at desc)`, used by the dashboard's "sessions in the last 30 days"
count and daily activity read. It changes no data, column, policy or grant,
uses `if not exists` (applying it twice is harmless), and runs inside a
transaction, so it works with transactional runners (`supabase db push`,
the GitHub integration, and `supabase/tests/*/run.sh`, which pass with it on
PostgreSQL 16).

Lock impact: a plain `CREATE INDEX` holds a SHARE lock on
`orvix_analytics_sessions` while it builds. Reads (the dashboard) continue;
inserts and updates wait, and every telemetry message upserts a session row.
On a small table the build takes well under a second. Telemetry requests
that wait longer than the app's 10 second timeout are dropped silently; the
app is never blocked.

Production precautions:

1. Check the size first:
   `select count(*), pg_size_pretty(pg_total_relation_size('public.orvix_analytics_sessions')) from public.orvix_analytics_sessions;`
2. Small table: apply the migration as is, preferably at a quiet hour.
3. Large table, or to avoid blocking writes at all: build the index first in
   the SQL editor, outside a transaction:
   `create index concurrently if not exists orvix_analytics_sessions_started_idx on public.orvix_analytics_sessions (started_at desc);`
   then confirm it is valid:
   `select indisvalid from pg_index where indexrelid = 'public.orvix_analytics_sessions_started_idx'::regclass;`
   A failed concurrent build leaves an invalid index that `if not exists`
   would skip, so drop it (`drop index concurrently public.orvix_analytics_sessions_started_idx;`)
   and retry. Applying the migration afterwards is a no-op.
4. Rollback: `drop index concurrently if exists public.orvix_analytics_sessions_started_idx;`
