# tv-login-exchange

Turns an approved Android TV QR login into a Supabase session for the TV.

## The TV login flow

1. The TV calls `start_tv_login_session(device_nonce)` with a random nonce it
   keeps to itself. It gets a random `device_code` and a six-letter
   `user_code`, and shows a QR code for `tv-login-link?code=<user_code>`. The
   nonce is never part of the QR code.
2. A signed-in phone approves the code with `approve_tv_login_session`
   (authenticated users only, wrong codes rate limited per account). The
   approval is valid for two minutes.
3. The TV polls `poll_tv_login_session(device_code, device_nonce)`. When it
   sees `approved`, it calls this function with the same two values.
4. This function leases the login (`begin_tv_login_exchange`), creates a
   session for the approving user, then marks the login used
   (`complete_tv_login_exchange`). If creating the session fails, the lease is
   released (`release_tv_login_exchange`) so the TV can retry; a lease that is
   never finished expires after 60 seconds. A session created by a lease that
   can no longer be completed is signed out again and never returned.
5. The TV stores the session (`setSession` with the refresh token).

When the TV refreshes or cancels its code it calls `cancel_tv_login_session`,
so approving an old QR code does nothing.

## Responses

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | session tokens | The TV is signed in. Single use. |
| 400 | `invalid_request` | Missing or malformed `device_code` / `device_nonce`. |
| 409 | `not_approved_or_expired` | Not approved, expired, cancelled, already used, or a wrong nonce. |
| 409 | `exchange_in_progress` | Another exchange holds the lease; retry shortly. |
| 503 | `session_generation_failed`, `temporarily_unavailable`, `server_configuration` | Retry later; the approval is kept. |

Logs contain fixed messages only, never codes, nonces, tokens or user ids.

## Deployment

Apply `supabase/migrations/20261007150000_harden_tv_device_login.sql` first,
then deploy this function:

```
supabase functions deploy tv-login-exchange --no-verify-jwt
supabase functions deploy tv-login-link --no-verify-jwt
```

`--no-verify-jwt` is required: the TV is signed out and calls with the
project's publishable key, which is not a JWT, and the QR page is opened by a
browser without a token. The device code and nonce authenticate the TV.

The previous version of this function used `claim_tv_login_session`, which the
migration keeps, so the old function keeps working until this one is deployed.

## Tests

```
deno test supabase/functions/tv-login-exchange/handler_test.ts
deno test supabase/functions/tv-login-link/page_test.ts
supabase/tests/tv_login/run.sh "postgresql://localhost:5432/scratch"
```
