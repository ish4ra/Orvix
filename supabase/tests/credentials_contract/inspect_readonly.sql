-- Read-only inspection of the provider credential store:
-- public.orvix_user_credentials, public.load_orvix_credentials() and
-- public.save_orvix_credentials(p_payload).
--
-- These objects were created in the production project outside the repo
-- migrations. This script only reads catalog metadata. It never selects a
-- credential payload, never reads Vault secrets and never writes, so it is
-- safe to run against production, for example:
--
--   psql "$PRODUCTION_DB_URL" --no-psqlrc -f inspect_readonly.sql
--
-- or by pasting it into the Supabase SQL editor.
--
-- Section 1 prints the function source. If that source contains a literal
-- encryption key (instead of reading it from Vault at run time), do not
-- paste the output anywhere public: the literal key is itself the finding.

begin transaction read only;

\echo '== 1. Function definitions (A/B: replace or merge, H: encryption)'
select p.oid::regprocedure as function,
       pg_get_functiondef(p.oid) as definition
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('load_orvix_credentials', 'save_orvix_credentials');

\echo '== 2. Signatures and execution context (G: no user id argument)'
select p.oid::regprocedure as function,
       pg_get_function_identity_arguments(p.oid) as arguments,
       pg_get_function_result(p.oid) as returns,
       case when p.prosecdef then 'SECURITY DEFINER' else 'SECURITY INVOKER' end
         as security,
       pg_get_userbyid(p.proowner) as owner,
       coalesce(array_to_string(p.proconfig, ', '), '(no SET options)')
         as settings,
       exists (
         select 1 from unnest(p.proargtypes) t where t = 'uuid'::regtype
       ) as takes_uuid_argument
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('load_orvix_credentials', 'save_orvix_credentials');

\echo '== 3. Who may execute them (F: anon, I: grants no broader than needed)'
select p.oid::regprocedure as function,
       r.rolname as role,
       has_function_privilege(r.rolname, p.oid, 'execute') as can_execute
  from pg_proc p
 cross join (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('load_orvix_credentials', 'save_orvix_credentials')
 order by 1, 2;

select p.oid::regprocedure as function,
       coalesce(array_to_string(p.proacl, ', '), '(default: PUBLIC may execute)')
         as acl
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('load_orvix_credentials', 'save_orvix_credentials');

\echo '== 4. Table shape (column names and types only)'
select a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) as type,
       a.attnotnull as not_null
  from pg_attribute a
 where a.attrelid = to_regclass('public.orvix_user_credentials')
   and a.attnum > 0 and not a.attisdropped
 order by a.attnum;

select con.conname, pg_get_constraintdef(con.oid) as definition
  from pg_constraint con
 where con.conrelid = to_regclass('public.orvix_user_credentials');

\echo '== 5. Row level security and direct table access (E)'
select c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
  from pg_class c
 where c.oid = to_regclass('public.orvix_user_credentials');

select policyname, roles, cmd, qual, with_check
  from pg_policies
 where schemaname = 'public' and tablename = 'orvix_user_credentials';

select r.rolname as role,
       has_table_privilege(r.rolname, 'public.orvix_user_credentials', 'select') as can_select,
       has_table_privilege(r.rolname, 'public.orvix_user_credentials', 'insert') as can_insert,
       has_table_privilege(r.rolname, 'public.orvix_user_credentials', 'update') as can_update,
       has_table_privilege(r.rolname, 'public.orvix_user_credentials', 'delete') as can_delete
  from (values ('anon'), ('authenticated')) r(rolname)
 where to_regclass('public.orvix_user_credentials') is not null;

\echo '== 6. Encryption building blocks installed (H)'
select extname, extversion, extnamespace::regnamespace as schema
  from pg_extension
 where extname in ('pgcrypto', 'pgsodium', 'supabase_vault')
 order by extname;

\echo '== 7. Row count only (no payloads)'
select count(*) as stored_credential_rows
  from public.orvix_user_credentials;

rollback;
