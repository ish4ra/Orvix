# Provider credential store contract

`public.orvix_user_credentials`, `public.load_orvix_credentials()` and
`public.save_orvix_credentials(p_payload)` were created directly in the
production Supabase project. They are **not** in `supabase/migrations`, and
their source (including how the payload is encrypted) is not in this
repository. The only repo knowledge of them is:

- the app's calls in `lib/services/supabase_orvix_account_backend.dart`
  (`rpc('load_orvix_credentials')`, `rpc('save_orvix_credentials',
  params: {'p_payload': <map>})`);
- `supabase/migrations/20261007120000_account_deletion.sql`, which requires a
  `user_id` column, links it to `auth.users` with `on delete cascade`, and
  deletes the row in `delete_orvix_account_data`;
- `supabase/tests/account_deletion/production_credentials.sql`, a minimal
  stand-in table (`user_id`, `payload text`, `updated_at`, row level security
  on).

Do not recreate these objects from guesses. Capture the real definitions
first (step 1 below).

## The contract the app relies on

| | Behaviour |
|---|---|
| A | `save_orvix_credentials(p)` stores `p` as the signed-in user's **complete** credential set. Keys left out are removed. It does not merge. |
| C | `save_orvix_credentials({})` is accepted and clears the set. Disconnecting the last provider sends exactly `{}`. |
| D | `load_orvix_credentials()` returns the stored set as a JSON object, or `{}`/`null` when there is none. |
| E, G | Both act only on `auth.uid()`. Neither takes a user id, and nothing in the payload can address another account. |
| F, I | `anon` cannot execute either RPC. `authenticated` can. The table has no direct `anon`/`authenticated` access, or is protected by row level security. |
| H | The payload is encrypted at rest. The key is not in the database row or in the function source. |
| — | Unknown keys are the client's business: the app reads the whole set, keeps keys it does not know, and saves the whole set back. |

The app also defends itself: after a save that drops keys, it reads the set
back. If a dropped key is still there (a merging store), it reports the
disconnect as not synced and keeps the removal pending. The old credential is
then never restored on that device. See `_syncCredentials` in
`lib/services/orvix_account_service.dart`.

## Verifying production

1. **Read-only inspection (safe on production).** Run
   `inspect_readonly.sql` in the Supabase SQL editor or with
   `psql "<production URL>" -f inspect_readonly.sql`. It runs in a read-only
   transaction and reads only catalog metadata. It never selects payloads or
   Vault secrets. It prints:
   - the function source, which answers A/C and H;
   - the signatures and SECURITY DEFINER/INVOKER settings (G);
   - the grants (F, I);
   - table RLS, policies and direct privileges (E);
   - which encryption extensions are installed.

   If the function source contains a literal key, treat that as a finding and
   do not paste the output anywhere public.

2. **Behavioural check (never on production).** `contract_test.sql`
   creates two throwaway auth users with placeholder values, so it only runs
   against a non-production copy:
   ```sh
   supabase db dump --linked -f /tmp/orvix_schema.sql   # schema only (the default), no data
   supabase start                                            # local stack
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f /tmp/orvix_schema.sql
   # If the functions read a Vault secret, create one with the same name and
   # a dummy value in the local stack only.
   supabase/tests/credentials_contract/run.sh "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
   ```
   `run.sh` refuses the production project ref. Everything runs in a
   transaction that is rolled back. Every check prints `PASS`/`FAIL`, and the
   run fails when any check fails.

3. **If A or C fails** (the store merges, or rejects `{}`), the fix belongs in
   a migration that replaces `save_orvix_credentials` with the same signature,
   ownership, grants and key handling as the captured definition. Only the
   merge becomes a replace (and `{}` either stores an empty set or deletes the
   row). Until then the app keeps removals pending instead of resurrecting
   credentials.

## Checking this kit

`selfcheck.sh` runs `contract_test.sql` in an empty scratch PostgreSQL
database against two **test doubles** in `doubles/`. These are not the
production code. The run must pass for a replacing store and fail for a
merging one:

```sh
supabase/tests/credentials_contract/selfcheck.sh "postgresql://localhost:5432/scratch"
```
