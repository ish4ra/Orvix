# Supabase security model

How each part of the Orvix Supabase backend is meant to be reached, what the
repository enforces, and what lives only in the production project. Keep this
in step with `supabase/migrations/` and `supabase/functions/`.

Migrations and Edge Functions are **not** deployed by any workflow. Each one is
applied to the production project by hand.

## Tables

All public tables have row level security on. "RPC-only" and "service only"
tables have no policies on purpose: anon and authenticated have no direct
privileges, so the Supabase advisor's "RLS enabled, no policy" notice is
expected for them and must not be "fixed" with a policy.

| Table | Access model | anon | authenticated | Notes |
|---|---|---|---|---|
| `orvix_user_state` | Direct (Data API), own row | none | select/insert/update/delete, policies `auth.uid() = user_id` (with check on insert/update) | cascades from `auth.users` |
| `orvix_user_credentials` | RPC-only | none | none | production-only, see below |
| `orvix_tv_login_sessions` | RPC-only | none | none | cascades from `auth.users` |
| `orvix_tv_login_approval_attempts` | RPC-only | none | none | cascades from `auth.users` |
| `supporters` | Public read of visible rows | select (`is_public and is_active`) | same | writes only from supporter webhooks (service role) |
| `orvix_admins` | Service only | none | none | currently unused; `orvix-admin` checks a fixed owner id |
| `orvix_analytics_*` | Service only (`orvix-telemetry`, `orvix-admin`) | none | none | `user_id` is set null when the account is deleted |

Known gap: the public `supporters` read is table-wide, so it also returns
internal columns such as `provider_user_id` (a SHA-256 of the email for Ko-fi
supporters with an email). The app selects `provider_user_id` to hide
provider test rows, so narrowing the grant to the displayed columns would
break the Supporters screen. First hide those rows without that column (for
example by marking them private), ship an app that no longer selects it, and
retire the versions that do; then `revoke select on public.supporters from
anon, authenticated` and grant `select` on only the displayed columns.

`supabase/tests/security/run.sh` checks this table (including TRUNCATE, which
row level security does not cover) on top of Supabase's default privileges.

## Functions

| Function | Security | Identity | EXECUTE |
|---|---|---|---|
| `start_tv_login_session(uuid, text)` | definer, `search_path=public` | none (pre-auth) | anon, authenticated |
| `poll_tv_login_session(uuid, uuid)` | definer | device code + nonce | anon, authenticated |
| `cancel_tv_login_session(uuid, uuid)` | definer | device code + nonce | anon, authenticated |
| `approve_tv_login_session(text)` | definer | `auth.uid()` (required) | authenticated |
| `begin/complete/release_tv_login_exchange`, `claim_tv_login_session` | definer | device code + nonce / exchange token | service_role |
| `delete_orvix_account_data(uuid)` | invoker | user id from the verified JWT in `delete-account` | service_role |
| `load_orvix_credentials()`, `save_orvix_credentials(p_payload)` | production-only | `auth.uid()` | authenticated |
| `set_orvix_user_state_updated_at()` | invoker trigger | — | not callable through the API |

Pre-auth TV functions are callable by anon by design. The device code and nonce
are random UUIDs that only the TV holds (the QR code carries only the six-letter
user code), so they grant only the status of that one login. Turning an
approval into a session needs the service-role `tv-login-exchange` function,
leases the login with a one-time exchange token and marks it consumed.

## Edge Functions

| Function | Caller | `verify_jwt` | Authorization inside |
|---|---|---|---|
| `delete-account` | signed-in app | on | `auth.getUser`, `sub` must match, password `amr` less than 10 minutes old; body ignored |
| `tv-login-exchange` | signed-out TV | off | device code + nonce, two-phase lease |
| `tv-login-link` | browser | off | static page; approval goes through `approve_tv_login_session` |
| `orvix-telemetry` | app (any) | off | optional JWT links `user_id` (verified with `auth.getUser`); redacts error text |
| `orvix-admin` | owner dashboard | off | `auth.getUser` and a fixed owner id |
| `supporters-github-webhook` | GitHub | off | HMAC-SHA256 signature |
| `supporters-bmc-webhook` | Buy Me a Coffee | off | HMAC-SHA256 signature |
| `supporters-kofi-webhook` | Ko-fi | off | verification token |
| `translate-subtitle-si`, `transcribe-audio-si`, `subdl-transcript`, `opensubtitles-exact` | app | on (legacy anon JWT) | none beyond the public anon key |

`verify_jwt` is a deployment setting; the values above are what the code and
its comments expect, not a reading of the production project.

## Production-only objects

| Object | Status |
|---|---|
| `orvix_user_credentials`, `load_orvix_credentials`, `save_orvix_credentials` and their encryption key | Created in production; not in migrations. Contract and read-only inspection: `supabase/tests/credentials_contract/`. Capture the real definitions (without the key) before recreating them anywhere. |
| Auth settings (email confirmation, secure password change, secure email change, OTP length, email templates) | Dashboard-managed. The app depends on: email confirmation with a six-digit code, recovery codes, "secure password change" (reauthentication nonce), password sign-in for the account-deletion proof. |
| Edge Function secrets (`GEMINI_API_KEY`, `OPENSUBTITLES_API_KEY`, `SUBDL_API_KEY`, webhook secrets) | Function environment only. |

## Running the database checks

Against an empty scratch PostgreSQL database (they refuse a Supabase project
and roll back):

```sh
supabase/tests/security/run.sh         "postgresql://localhost:5432/scratch"
supabase/tests/tv_login/run.sh         "postgresql://localhost:5432/scratch"
supabase/tests/account_deletion/run.sh "postgresql://localhost:5432/scratch"
deno test --allow-read supabase/functions/
```
