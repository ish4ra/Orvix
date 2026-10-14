# Private (owner-only) in-app updates

Private test builds are GitHub **Draft Releases**. Drafts are never public:
the app cannot read them, and they have no public download URLs. The
`orvix-internal-update` Supabase Edge Function reads them for authorized
accounts and returns only metadata plus a short-lived download link.

```
app (signed in) ──POST {action, platform}──▶ orvix-internal-update
   1. Supabase session      → 401 when missing or expired
   2. admin check           → 403 unless the user id is in public.orvix_admins
   3. GitHub token present  → 503 internal_updates_unconfigured
   4. GET /releases (token) → 502 github_unavailable + github_status
   5. drafts with a verified asset for the platform
      → { releases, drafts_visible, skipped }
```

## Why no private update appeared on v0.7.9 (diagnosis)

The v0.7.9 client treats every private-channel failure as "no update" and
gives up after 8 seconds. Four server-side conditions produce exactly the
owner's symptom. None of them can be checked from the repository or CI,
because the production project, its secrets and its tables are not
reachable from there.

1. **The owner account is not in `public.orvix_admins`.** No migration adds
   anyone to this table. `docs/SUPABASE_SECURITY.md` lists it as "currently
   unused": the Control Center (`orvix-admin`) checks a fixed owner id
   instead. The update function, however, only accepts accounts listed in
   `orvix_admins`. Unless the owner was added by hand, the function returns
   403, and the app (on purpose) says nothing to a non-admin.
2. **The GitHub token cannot see drafts.** GitHub lists draft releases only
   to callers with push access to the repository. With a fine-grained token
   that has *Contents: Read-only*, the call to `/releases` succeeds but
   returns no drafts (`drafts_visible: 0`).
3. **The function deployed in production is older than PR #91.** Such a
   function returns `{releases: []}` with no diagnostics.
4. **A cold start plus the GitHub listing took longer than the client's 8
   seconds.** v0.7.10-beta.3 waits 20 seconds and reports a timeout as a
   timeout.

v0.7.10-beta.2 and later show which of these happened in **Settings › App
updates › Check for updates**. Sign in with the owner account first.

| Message | Meaning | Fix |
|---|---|---|
| (nothing extra, "up to date") | 403: the account is not an admin, **or** the user is signed out | Step 1 below |
| "the server sees no draft releases" | Token cannot list drafts (cause 2) | Step 2 below |
| "server runs an older orvix-internal-update" | Old deployment (cause 3) | Step 3 below |
| "GitHub refused the draft lookup (HTTP 401/403/404)" | Token invalid, expired or not scoped to `ish4ra/Orvix` | Step 2 below |
| "the server has no GitHub access configured" | Secret missing | Step 2 below |
| "Account update check: the server did not answer in time / has no update function deployed / failed (HTTP n)" | Timeout, function missing (404) or crashed | Step 3 below |
| "no newer build for this device (n drafts without an installer for it)" | The draft has no asset for this platform, or GitHub has not computed its SHA-256 digest yet | Re-upload the asset with `tools/publish_orvix_release.sh` |

## Owner setup (do not paste secrets into chat, issues or PRs)

1. **Allow the owner account.** In the Supabase SQL editor of the
   production project, run:
   ```sql
   insert into public.orvix_admins (user_id)
   select id from auth.users where email = '<owner sign-in email>'
   on conflict (user_id) do nothing;
   ```
   Then check that `select count(*) from public.orvix_admins;` returns at
   least 1. The table is service-role only (RLS on, no grants to `anon` or
   `authenticated`), so this changes nothing for other users.
2. **GitHub token.** Create a fine-grained personal access token with:
   - resource owner `ish4ra`;
   - repository access limited to **only** `ish4ra/Orvix`;
   - repository permission **Contents: Read and write**. GitHub shows
     drafts only to callers with push access. The function only ever
     sends GET requests.
   - a short expiry, renewed when it runs out.

   Store it as a function secret, never in the app, a workflow or the repo:
   ```sh
   supabase secrets set ORVIX_INTERNAL_GITHUB_TOKEN --project-ref <ref>   # paste when prompted
   ```
   If a write-capable token is not acceptable, the alternative is to stop
   using drafts as storage (for example a private assets repository). That
   is an architecture change and is not made here.
3. **Deploy the current function:**
   ```sh
   supabase functions deploy orvix-internal-update --project-ref <ref>
   ```
   Keep JWT verification on. The function checks the session itself as
   well.
4. **Verify.** On the owner device, run Settings › App updates › Check for
   updates. Expect "Orvix 0.7.10-beta.N is available" and "Private test
   build for this device". On a non-admin account, the same screen must
   show only the public result.

## What v0.7.9 installs need

A v0.7.9 install cannot be changed. It finds a private build only when all
of these hold:
- it is signed in to the owner account (it checks at start-up and right
  after sign-in);
- the function answers within 8 seconds;
- the account is in `orvix_admins`;
- the token lists drafts;
- the draft carries `Orvix-v<version>-Android-TV.apk` or
  `-Android-Mobile.apk` with a SHA-256 digest.

Once beta.3 is installed, its own diagnostics and 20-second timeout apply.
