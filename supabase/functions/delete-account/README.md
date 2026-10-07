# delete-account

Permanently deletes the calling user's Orvix account: their Orvix cloud data
and then their Supabase Auth user. The Account screen on Android Mobile,
Windows and macOS calls it; Android TV does not offer account deletion.

## How a request is checked

1. The `Authorization: Bearer <access token>` header is required. JWT
   verification at the gateway stays on, and the function also validates the
   token with Supabase Auth (`auth.getUser`).
2. The account to delete is always the token's own user. The request body is
   never read, so a client cannot name a different account.
3. The token's session must have confirmed the password in the last
   10 minutes (the `password` entry of its `amr` claim). The app gets such a
   token by signing in again with the current password on a separate,
   short-lived auth client just before calling this function. An older or
   refreshed session, or one that never used a password, gets
   `401 reauthentication_required`.
4. `public.delete_orvix_account_data(user_id)` removes the user's cloud sync
   row, synced (encrypted) credentials and TV login sessions. Then
   `auth.admin.deleteUser` hard-deletes the Auth user, its sessions and
   identities. Foreign keys with `on delete cascade` also remove anything
   written in between.

Responses carry a short error code only:

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | `{"deleted": true}` | The account is gone. |
| 401 | `not_authenticated` | Missing, invalid or mismatched token. |
| 401 | `reauthentication_required` | The password was not confirmed recently. |
| 410 | `account_not_found` | Already deleted (e.g. a retry after a lost response). |
| 500 | `cleanup_failed` | Cloud data could not be removed; the Auth user was kept. |
| 500 | `delete_failed` | The Auth user could not be deleted. |
| 503 | `auth_unavailable`, `server_configuration` | Retry later. |

Logs contain fixed messages only, never tokens, user ids, passwords or
credential data.

Orvix stores no user-owned Supabase Storage objects, so there is nothing to
remove from Storage before deleting the Auth user.

## Deploying

The function needs the migration
`supabase/migrations/20261007120000_account_deletion.sql` first. Until it is
applied the function answers `cleanup_failed` and deletes nothing.

```sh
supabase db push            # or apply the migration in the SQL editor
supabase functions deploy delete-account
```

Do not pass `--no-verify-jwt`. `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
are provided to Edge Functions by Supabase; never put the service role key in
the app or the repository.

## Tests

```sh
deno test --no-remote supabase/functions/delete-account/handler_test.ts
supabase/tests/account_deletion/run.sh "<scratch PostgreSQL URL>"
```

The database checks run against a scratch PostgreSQL database with a small
stand-in for the `auth` schema, inside a transaction that is rolled back. They
refuse to run against a database that already has an `auth` schema, so they
cannot touch a Supabase project.
