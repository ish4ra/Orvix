-- Behavioural contract of the provider credential RPCs, as the Orvix app
-- relies on it (lib/services/orvix_account_service.dart):
--
--   save_orvix_credentials(p_payload) stores p_payload as the signed-in
--   user's COMPLETE credential set. Keys left out are removed; {} clears it.
--   load_orvix_credentials() returns that set ({} or null when empty).
--   Both act only on auth.uid(); anon cannot use them; the payload is
--   encrypted at rest.
--
-- Run through run.sh, which wraps this in a transaction that is rolled back.
-- It creates two throwaway auth users with placeholder values, so it must
-- run against a non-production copy of the schema (see README.md), never
-- against the production project. It never touches another user's row.
--
-- Every check is recorded; the script fails at the end if any check failed,
-- after printing all of them.

create temporary table contract_results (
  seq serial,
  ok boolean not null,
  check_name text not null
) on commit drop;

create function pg_temp.expect_ok(ok boolean, check_name text) returns void
language sql as $$
  insert into contract_results (ok, check_name) values (coalesce(ok, false), check_name);
$$;

-- Acts as a signed-in user for the next statements. Sets both claim forms
-- Supabase's auth.uid() has read over time.
create function pg_temp.act_as(p_user uuid) returns void
language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true),
         set_config('request.jwt.claims',
           case when p_user is null then '{"role":"anon"}'
                else json_build_object('sub', p_user, 'role', 'authenticated')::text
           end, true);
$$;

select gen_random_uuid() as user_a, gen_random_uuid() as user_b \gset

insert into auth.users (id, email) values
  (:'user_a', 'orvix-contract-a@example.invalid'),
  (:'user_b', 'orvix-contract-b@example.invalid');

-- G: the RPCs take no user id at all.
select pg_temp.expect_ok(
  not exists (
    select 1 from pg_proc p, unnest(p.proargtypes) t
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('load_orvix_credentials', 'save_orvix_credentials')
       and t = 'uuid'::regtype),
  'G. neither RPC accepts a user id argument');

-- F / I: grants.
select pg_temp.expect_ok(
  not has_function_privilege('anon', 'public.load_orvix_credentials()', 'execute'),
  'F. anon cannot execute load_orvix_credentials');
select pg_temp.expect_ok(
  not exists (
    select 1 from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = 'save_orvix_credentials'
       and has_function_privilege('anon', p.oid, 'execute')),
  'F. anon cannot execute save_orvix_credentials');
select pg_temp.expect_ok(
  has_function_privilege('authenticated', 'public.load_orvix_credentials()', 'execute'),
  'I. authenticated can execute load_orvix_credentials');
select pg_temp.expect_ok(
  not has_table_privilege('anon', 'public.orvix_user_credentials', 'select'),
  'I. anon has no direct read access to the credentials table');
select pg_temp.expect_ok(
  (select relrowsecurity from pg_class
    where oid = 'public.orvix_user_credentials'::regclass)
  or not has_table_privilege('authenticated', 'public.orvix_user_credentials', 'select'),
  'E. authenticated cannot read the table directly without row level security');
select pg_temp.expect_ok(
  not exists (
    select 1 from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('load_orvix_credentials', 'save_orvix_credentials')
       and p.prosecdef
       and not exists (select 1 from unnest(p.proconfig) c
                        where c like 'search_path=%')),
  'I. SECURITY DEFINER credential RPCs pin their search_path');

-- User A stores two providers.
select pg_temp.act_as(:'user_a');
set local role authenticated;
select public.save_orvix_credentials(
  '{"contract_torbox":"orvix-contract-marker-a-torbox","contract_rd":"orvix-contract-marker-a-rd"}');
select coalesce(public.load_orvix_credentials()::text, '{}') as a_first \gset
reset role;

select pg_temp.expect_ok(
  :'a_first'::jsonb = '{"contract_torbox":"orvix-contract-marker-a-torbox","contract_rd":"orvix-contract-marker-a-rd"}'::jsonb,
  'load returns exactly what save stored');

-- H: the stored row does not hold the values in plain text. Only this
-- throwaway user's row is looked at.
select pg_temp.expect_ok(
  (select count(*) from public.orvix_user_credentials where user_id = :'user_a') = 1,
  'H. the credential set is stored in orvix_user_credentials, one row per user');
select pg_temp.expect_ok(
  not exists (
    select 1 from public.orvix_user_credentials t
     where t.user_id = :'user_a'
       and t::text like '%orvix-contract-marker%'),
  'H. stored credentials are encrypted (placeholders not visible at rest)');

-- A/B: saving a smaller set removes what was left out.
select pg_temp.act_as(:'user_a');
set local role authenticated;
select public.save_orvix_credentials('{"contract_rd":"orvix-contract-marker-a-rd"}');
select coalesce(public.load_orvix_credentials()::text, '{}') as a_second \gset
reset role;

select pg_temp.expect_ok(
  not (:'a_second'::jsonb ? 'contract_torbox'),
  'A. save REPLACES the payload: a provider left out is removed (fails if it MERGES)');
select pg_temp.expect_ok(
  :'a_second'::jsonb = '{"contract_rd":"orvix-contract-marker-a-rd"}'::jsonb,
  'A. the remaining provider is kept unchanged');

-- E / G: user B sees none of A's credentials, and B's writes (even with a
-- user_id inside the payload) never reach A.
select json_build_object('user_id', :'user_a'::text,
                         'contract_torbox', 'orvix-contract-marker-b')::text
  as b_payload \gset
select pg_temp.act_as(:'user_b');
set local role authenticated;
select coalesce(public.load_orvix_credentials()::text, '{}') as b_first \gset
select public.save_orvix_credentials(:'b_payload');
reset role;

select pg_temp.expect_ok(
  :'b_first'::jsonb = '{}'::jsonb,
  'E. another user cannot read the credentials');

select pg_temp.act_as(:'user_a');
set local role authenticated;
select coalesce(public.load_orvix_credentials()::text, '{}') as a_after_b \gset
reset role;

select pg_temp.expect_ok(
  not (:'a_after_b'::jsonb ? 'user_id')
  and :'a_after_b'::jsonb ->> 'contract_torbox' is distinct from 'orvix-contract-marker-b',
  'G. another user cannot write the credentials, even naming the user_id');

-- C/D: an empty set clears the account's credentials.
select pg_temp.act_as(:'user_a');
set local role authenticated;
select public.save_orvix_credentials('{}');
select coalesce(public.load_orvix_credentials()::text, '{}') as a_cleared \gset
reset role;

select pg_temp.expect_ok(
  :'a_cleared'::jsonb = '{}'::jsonb,
  'C/D. save({}) is accepted and load then returns an empty set');

select pg_temp.act_as(:'user_b');
set local role authenticated;
select coalesce(public.load_orvix_credentials()::text, '{}') as b_after_clear \gset
reset role;

select pg_temp.expect_ok(
  :'b_after_clear'::jsonb ? 'contract_torbox',
  'clearing one account leaves other accounts untouched');

-- F at run time: without a session nothing is read or written.
select pg_temp.act_as(null);
set local role anon;
do $$
begin
  begin
    perform public.load_orvix_credentials();
    perform set_config('orvix_contract.anon_load', 'allowed', true);
  exception when others then
    perform set_config('orvix_contract.anon_load', 'refused', true);
  end;
  begin
    perform public.save_orvix_credentials('{"contract_anon":"orvix-contract-marker-anon"}');
    perform set_config('orvix_contract.anon_save', 'allowed', true);
  exception when others then
    perform set_config('orvix_contract.anon_save', 'refused', true);
  end;
end;
$$;
reset role;

select pg_temp.expect_ok(
  current_setting('orvix_contract.anon_load', true) = 'refused',
  'F. anon calling load_orvix_credentials is refused');
select pg_temp.expect_ok(
  current_setting('orvix_contract.anon_save', true) = 'refused',
  'F. anon calling save_orvix_credentials is refused');

-- Report, then fail when anything failed.
select case when ok then 'PASS  ' else 'FAIL  ' end || check_name
  from contract_results order by seq;

do $$
declare
  v_failed int;
begin
  select count(*) into v_failed from contract_results where not ok;
  if v_failed > 0 then
    raise exception '% credential contract check(s) failed', v_failed;
  end if;
end;
$$;
