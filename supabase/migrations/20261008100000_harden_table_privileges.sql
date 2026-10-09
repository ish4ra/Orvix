-- Makes the intended client access to Orvix tables explicit.
--
-- Supabase's default privileges grant ALL (including TRUNCATE, which row
-- level security does not cover) on new public tables, sequences and
-- functions to anon and authenticated. Row level security already limits
-- what the Data API can do with these tables; these revokes remove the
-- privileges no client path uses, so a future policy or exposed function
-- cannot widen access by accident. Nothing a current client uses is revoked.
--
--   orvix_user_state   signed-in users read and write their own row through
--                      the Data API (policies in 20260917161500). anon has no
--                      policy and no use for the table.
--   supporters         public read of visible rows (policy in
--                      20260930025000). Writes come only from the supporter
--                      webhooks, which use the service role.
--   sequences          the identity sequences of the RPC- and service-only
--                      tables. 20261007190000 revoked USAGE and SELECT on the
--                      analytics sequences but left UPDATE (setval).
--
-- orvix_user_credentials is not touched: it predates these migrations and is
-- reached only through its own RPCs.

revoke all on table public.orvix_user_state from anon;
revoke truncate, references, trigger on table public.orvix_user_state
  from authenticated;

revoke insert, update, delete, truncate, references, trigger
  on table public.supporters from anon, authenticated;

revoke all on sequence
  public.orvix_tv_login_approval_attempts_id_seq,
  public.orvix_analytics_events_id_seq,
  public.orvix_analytics_errors_id_seq
  from anon, authenticated;
