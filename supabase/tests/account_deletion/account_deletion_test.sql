-- Checks what deleting an Orvix account removes. Run with run.sh.
\set ON_ERROR_STOP on

select set_config('test.a', '00000000-0000-4000-8000-00000000000a', false);
select set_config('test.b', '00000000-0000-4000-8000-00000000000b', false);

insert into auth.users (id, email) values
  (current_setting('test.a')::uuid, 'a@example.test'),
  (current_setting('test.b')::uuid, 'b@example.test');

create temp table tv_codes (owner text, device_code uuid, device_nonce uuid, user_code text);
grant all on tv_codes to service_role, authenticated;

create function pg_temp.seed(p_owner text) returns void
language plpgsql as $$
declare
  v_user uuid := current_setting('test.' || p_owner)::uuid;
  v_nonce uuid := gen_random_uuid();
  v_start record;
begin
  insert into public.orvix_user_state (user_id, watchlist)
  values (v_user, '[{"id":"tt1"}]')
  on conflict (user_id) do nothing;
  if to_regclass('public.orvix_user_credentials') is not null then
    execute 'insert into public.orvix_user_credentials (user_id, payload)
             values ($1, ''encrypted'') on conflict do nothing' using v_user;
  end if;

  select * into v_start from public.start_tv_login_session(v_nonce, 'Orvix TV');
  insert into tv_codes values (p_owner, v_start.device_code, v_nonce, v_start.user_code);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  assert public.approve_tv_login_session(v_start.user_code), 'TV approval failed';
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

create function pg_temp.owned_rows(p_owner text) returns bigint
language plpgsql as $$
declare
  v_user uuid := current_setting('test.' || p_owner)::uuid;
  v_count bigint;
  v_credentials bigint := 0;
begin
  select (select count(*) from public.orvix_user_state where user_id = v_user)
       + (select count(*) from public.orvix_tv_login_sessions where approved_user_id = v_user)
    into v_count;
  if to_regclass('public.orvix_user_credentials') is not null then
    execute 'select count(*) from public.orvix_user_credentials where user_id = $1'
      into v_credentials using v_user;
  end if;
  return v_count + v_credentials;
end;
$$;

select pg_temp.seed('a');
select pg_temp.seed('b');

insert into public.supporters (provider, provider_user_id, display_name)
values ('github', '42', 'Supporter');

-- Every user-owned table cascades from auth.users.
do $$
begin
  assert not exists (
    select 1 from pg_constraint con
    where con.contype = 'f'
      and con.confrelid = 'auth.users'::regclass
      and con.conrelid::regclass::text in (
        'orvix_user_state', 'orvix_user_credentials', 'orvix_tv_login_sessions')
      and con.confdeltype <> 'c'
  ), 'a foreign key to auth.users does not cascade';
  if to_regclass('public.orvix_user_credentials') is not null then
    assert exists (
      select 1 from pg_constraint con
      where con.contype = 'f'
        and con.conrelid = 'public.orvix_user_credentials'::regclass
        and con.confrelid = 'auth.users'::regclass
    ), 'orvix_user_credentials is not linked to auth.users';
  end if;
end;
$$;

-- Only the service role may run the cleanup function.
do $$
declare
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    execute format('set local role %I', v_role);
    begin
      perform public.delete_orvix_account_data(current_setting('test.b')::uuid);
      raise exception 'role % could run delete_orvix_account_data', v_role;
    exception when insufficient_privilege then
      null;
    end;
    reset role;
  end loop;
end;
$$;

-- Edge Function step 1: explicit cleanup for the caller only.
set role service_role;
select public.delete_orvix_account_data(current_setting('test.a')::uuid);
-- A retry is harmless.
select public.delete_orvix_account_data(current_setting('test.a')::uuid);
do $$
begin
  perform public.delete_orvix_account_data(null);
  raise exception 'a null user id was accepted';
exception when raise_exception then
  if sqlerrm <> 'A user id is required' then raise; end if;
end;
$$;
reset role;

do $$
begin
  assert pg_temp.owned_rows('a') = 0, 'user a still has cloud rows after cleanup';
  assert pg_temp.owned_rows('b') = case
    when to_regclass('public.orvix_user_credentials') is null then 2 else 3 end,
    'user b lost rows during user a cleanup';
end;
$$;

-- Rows written for user a between the cleanup and the Auth deletion (another
-- device syncing) are removed by the cascade.
select pg_temp.seed('a');

-- Edge Function step 2: the Auth admin API deletes the user.
delete from auth.users where id = current_setting('test.a')::uuid;

do $$
declare
  v_code record;
begin
  assert pg_temp.owned_rows('a') = 0, 'user a still has cloud rows after Auth deletion';
  assert pg_temp.owned_rows('b') = case
    when to_regclass('public.orvix_user_credentials') is null then 2 else 3 end,
    'user b lost rows during user a deletion';
  assert (select count(*) from public.supporters) = 1, 'supporters changed';

  -- No TV approved for user a can be claimed any more.
  for v_code in select * from tv_codes where owner = 'a' loop
    assert not exists (
      select 1 from public.claim_tv_login_session(v_code.device_code, v_code.device_nonce)
    ), 'a deleted user''s TV login could still be claimed';
    assert not exists (
      select 1 from public.orvix_tv_login_sessions where device_code = v_code.device_code
    ), 'a deleted user''s TV login session remains';
  end loop;

  -- User b's TV login still works.
  for v_code in select * from tv_codes where owner = 'b' loop
    assert (select user_id from public.claim_tv_login_session(v_code.device_code, v_code.device_nonce))
      = current_setting('test.b')::uuid, 'user b''s TV login broke';
  end loop;
end;
$$;

-- A stale access token for the deleted user cannot recreate cloud rows.
do $$
begin
  insert into public.orvix_user_state (user_id) values (current_setting('test.a')::uuid);
  raise exception 'cloud state was recreated for a deleted user';
exception when foreign_key_violation then
  null;
end;
$$;

do $$
begin
  if to_regclass('public.orvix_user_credentials') is not null then
    begin
      insert into public.orvix_user_credentials (user_id, payload)
      values (current_setting('test.a')::uuid, 'encrypted');
      raise exception 'credentials were recreated for a deleted user';
    exception when foreign_key_violation then
      null;
    end;
  end if;
end;
$$;

select 'account deletion checks passed' as result;
