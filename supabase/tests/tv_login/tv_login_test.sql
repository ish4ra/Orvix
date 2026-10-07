-- Checks the TV device login boundary. Run with run.sh.
\set ON_ERROR_STOP on

select set_config('test.a', '00000000-0000-4000-8000-00000000000a', false);
select set_config('test.b', '00000000-0000-4000-8000-00000000000b', false);

insert into auth.users (id, email) values
  (current_setting('test.a')::uuid, 'a@example.test'),
  (current_setting('test.b')::uuid, 'b@example.test');

create temp table logins (name text primary key, device_code uuid, device_nonce uuid, user_code text);
grant all on logins to anon, authenticated, service_role;

create function pg_temp.start(p_name text) returns void
language plpgsql as $$
declare
  v_nonce uuid := gen_random_uuid();
  v_start record;
begin
  select * into v_start from public.start_tv_login_session(v_nonce, 'Test TV');
  insert into logins values (p_name, v_start.device_code, v_nonce, v_start.user_code);
end;
$$;

create function pg_temp.login(p_name text) returns logins
language sql as $$ select * from logins where name = p_name $$;

create function pg_temp.sign_in(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', current_setting('test.' || p_user), true) $$;

create function pg_temp.sign_out() returns void
language sql as $$ select set_config('request.jwt.claim.sub', '', true) $$;

create function pg_temp.poll(p_name text, p_nonce uuid default null) returns text
language sql as $$
  select status from public.poll_tv_login_session(
    (pg_temp.login(p_name)).device_code,
    coalesce(p_nonce, (pg_temp.login(p_name)).device_nonce))
$$;

create function pg_temp.begin_exchange(p_name text, p_nonce uuid default null)
returns table(state text, user_id uuid, exchange_token uuid)
language sql as $$
  select * from public.begin_tv_login_exchange(
    (pg_temp.login(p_name)).device_code,
    coalesce(p_nonce, (pg_temp.login(p_name)).device_nonce))
$$;

-- Codes: six letters from the 32-letter alphabet, unique among stored rows.
select pg_temp.start('format');
do $$
declare
  v_code text := (pg_temp.login('format')).user_code;
begin
  assert v_code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$', 'unexpected user code ' || v_code;
  assert pg_temp.poll('format') = 'pending', 'a new login is not pending';
end;
$$;

-- An expired row holding a code does not block new logins, and rows expired
-- for over an hour are removed.
update public.orvix_tv_login_sessions
set expires_at = now() - interval '2 hours'
where device_code = (pg_temp.login('format')).device_code;
select pg_temp.start('after-cleanup');
do $$
begin
  assert not exists (
    select 1 from public.orvix_tv_login_sessions
    where device_code = (pg_temp.login('format')).device_code
  ), 'an old expired login was not cleaned up';
end;
$$;

-- A wrong nonce reveals nothing.
select pg_temp.start('main');
do $$
begin
  assert pg_temp.poll('main', gen_random_uuid()) is null, 'poll with a wrong nonce returned a status';
end;
$$;

-- Function privileges: the TV (anon) may start, poll and cancel; approving
-- needs a signed-in account; the exchange is for the service role only.
do $$
declare
  v_check record;
begin
  for v_check in
    select * from (values
      ('anon', 'public.start_tv_login_session(uuid, text)', true),
      ('anon', 'public.poll_tv_login_session(uuid, uuid)', true),
      ('anon', 'public.cancel_tv_login_session(uuid, uuid)', true),
      ('anon', 'public.approve_tv_login_session(text)', false),
      ('authenticated', 'public.approve_tv_login_session(text)', true),
      ('anon', 'public.claim_tv_login_session(uuid, uuid)', false),
      ('authenticated', 'public.claim_tv_login_session(uuid, uuid)', false),
      ('service_role', 'public.claim_tv_login_session(uuid, uuid)', true),
      ('anon', 'public.begin_tv_login_exchange(uuid, uuid)', false),
      ('authenticated', 'public.begin_tv_login_exchange(uuid, uuid)', false),
      ('service_role', 'public.begin_tv_login_exchange(uuid, uuid)', true),
      ('anon', 'public.complete_tv_login_exchange(uuid, uuid)', false),
      ('authenticated', 'public.complete_tv_login_exchange(uuid, uuid)', false),
      ('service_role', 'public.complete_tv_login_exchange(uuid, uuid)', true),
      ('anon', 'public.release_tv_login_exchange(uuid, uuid)', false),
      ('authenticated', 'public.release_tv_login_exchange(uuid, uuid)', false),
      ('service_role', 'public.release_tv_login_exchange(uuid, uuid)', true)
    ) as t(role_name, signature, allowed)
  loop
    assert has_function_privilege(v_check.role_name, v_check.signature, 'execute') = v_check.allowed,
      format('%s EXECUTE on %s should be %s', v_check.role_name, v_check.signature, v_check.allowed);
  end loop;

  -- And the call itself is refused.
  set local role anon;
  begin
    perform public.begin_tv_login_exchange((pg_temp.login('main')).device_code, (pg_temp.login('main')).device_nonce);
    raise exception 'anon could run begin_tv_login_exchange';
  exception when insufficient_privilege then
    null;
  end;
  reset role;
  assert not exists (select 1 from public.orvix_tv_login_sessions
    where device_code = (pg_temp.login('main')).device_code and exchange_token is not null),
    'a refused call changed the login';
end;
$$;

-- An authenticated role without a user id is refused.
do $$
begin
  set local role authenticated;
  perform pg_temp.sign_out();
  begin
    perform public.approve_tv_login_session((pg_temp.login('main')).user_code);
    raise exception 'approval without a user id succeeded';
  exception when insufficient_privilege then
    null;
  end;
  reset role;
end;
$$;

-- Before approval nothing can be exchanged, and a user code alone is useless.
set role service_role;
do $$
begin
  assert (select state from pg_temp.begin_exchange('main')) = 'unavailable',
    'a pending login could be exchanged';
  assert not exists (select 1 from public.claim_tv_login_session(
    (pg_temp.login('main')).device_code, (pg_temp.login('main')).device_nonce)),
    'a pending login could be claimed';
end;
$$;
reset role;

-- Approval: case and separators do not matter; a second approval fails.
set role authenticated;
select pg_temp.sign_in('a');
do $$
declare
  v_code text := (pg_temp.login('main')).user_code;
begin
  assert public.approve_tv_login_session(lower(substr(v_code, 1, 3)) || '-' || lower(substr(v_code, 4))),
    'a valid code was not approved';
  assert not public.approve_tv_login_session(v_code), 'an approved code was approved twice';
end;
$$;
select pg_temp.sign_out();
reset role;

do $$
declare
  v_row public.orvix_tv_login_sessions;
begin
  select * into v_row from public.orvix_tv_login_sessions
  where device_code = (pg_temp.login('main')).device_code;
  assert v_row.approved_user_id = current_setting('test.a')::uuid, 'approval stored the wrong user';
  assert v_row.expires_at <= now() + interval '2 minutes', 'an approved login keeps a long expiry';
  assert pg_temp.poll('main') = 'approved', 'the TV does not see the approval';
end;
$$;

-- Two-phase exchange: a wrong nonce gets nothing; one lease at a time.
set role service_role;
create temp table leases (name text, user_id uuid, exchange_token uuid);
do $$
declare
  v_lease record;
begin
  assert (select state from pg_temp.begin_exchange('main', gen_random_uuid())) = 'unavailable',
    'a wrong nonce could lease the login';

  select * into v_lease from pg_temp.begin_exchange('main');
  assert v_lease.state = 'leased', 'an approved login could not be leased';
  assert v_lease.user_id = current_setting('test.a')::uuid, 'the lease returned the wrong user';
  insert into leases values ('first', v_lease.user_id, v_lease.exchange_token);

  assert (select state from pg_temp.begin_exchange('main')) = 'busy',
    'a second exchange could lease a leased login';
  assert not exists (select 1 from public.claim_tv_login_session(
    (pg_temp.login('main')).device_code, (pg_temp.login('main')).device_nonce)),
    'the legacy claim took a leased login';

  -- A failed session creation releases the lease; the approval survives.
  perform public.release_tv_login_exchange(
    (pg_temp.login('main')).device_code, (select exchange_token from leases where name = 'first'));
  select * into v_lease from pg_temp.begin_exchange('main');
  assert v_lease.state = 'leased', 'a released login could not be leased again';
  insert into leases values ('second', v_lease.user_id, v_lease.exchange_token);

  -- The stale lease cannot complete; the current one can, once.
  assert not public.complete_tv_login_exchange(
    (pg_temp.login('main')).device_code, (select exchange_token from leases where name = 'first')),
    'a released lease completed the exchange';
  assert public.complete_tv_login_exchange(
    (pg_temp.login('main')).device_code, (select exchange_token from leases where name = 'second')),
    'the current lease could not complete';
  assert not public.complete_tv_login_exchange(
    (pg_temp.login('main')).device_code, (select exchange_token from leases where name = 'second')),
    'the exchange completed twice';

  -- Replay after success.
  assert (select state from pg_temp.begin_exchange('main')) = 'unavailable',
    'a consumed login could be leased again';
  assert not exists (select 1 from public.claim_tv_login_session(
    (pg_temp.login('main')).device_code, (pg_temp.login('main')).device_nonce)),
    'a consumed login could be claimed';
end;
$$;
reset role;

do $$
begin
  assert pg_temp.poll('main') = 'consumed', 'a used login is not reported as used';
end;
$$;

-- A lease that is never completed or released expires and can be retried.
select pg_temp.start('stale-lease');
set role authenticated;
select pg_temp.sign_in('b');
select public.approve_tv_login_session((pg_temp.login('stale-lease')).user_code);
select pg_temp.sign_out();
reset role;
set role service_role;
select state from pg_temp.begin_exchange('stale-lease');
reset role;
update public.orvix_tv_login_sessions
set exchange_expires_at = now() - interval '1 second'
where device_code = (pg_temp.login('stale-lease')).device_code;
set role service_role;
do $$
begin
  assert (select state from pg_temp.begin_exchange('stale-lease')) = 'leased',
    'an abandoned lease blocked the login';
end;
$$;
reset role;

-- An expired approval cannot be exchanged.
select pg_temp.start('expired');
set role authenticated;
select pg_temp.sign_in('b');
select public.approve_tv_login_session((pg_temp.login('expired')).user_code);
select pg_temp.sign_out();
reset role;
update public.orvix_tv_login_sessions
set expires_at = now() - interval '1 second'
where device_code = (pg_temp.login('expired')).device_code;
set role service_role;
do $$
begin
  assert (select state from pg_temp.begin_exchange('expired')) = 'unavailable',
    'an expired login could be leased';
  assert not exists (select 1 from public.claim_tv_login_session(
    (pg_temp.login('expired')).device_code, (pg_temp.login('expired')).device_nonce)),
    'an expired login could be claimed';
end;
$$;
reset role;
do $$
begin
  assert pg_temp.poll('expired') = 'expired', 'an expired login is not reported as expired';
end;
$$;

-- An expired code cannot be approved.
select pg_temp.start('expired-code');
update public.orvix_tv_login_sessions
set expires_at = now() - interval '1 second'
where device_code = (pg_temp.login('expired-code')).device_code;
set role authenticated;
select pg_temp.sign_in('b');
do $$
begin
  assert not public.approve_tv_login_session((pg_temp.login('expired-code')).user_code),
    'an expired code was approved';
end;
$$;
select pg_temp.sign_out();
reset role;

-- A code the TV replaced (cancelled) cannot be approved; only the right
-- nonce can cancel.
select pg_temp.start('replaced');
set role anon;
do $$
begin
  assert not public.cancel_tv_login_session((pg_temp.login('replaced')).device_code, gen_random_uuid()),
    'a wrong nonce cancelled a login';
  assert public.cancel_tv_login_session(
    (pg_temp.login('replaced')).device_code, (pg_temp.login('replaced')).device_nonce),
    'the TV could not cancel its login';
end;
$$;
reset role;
set role authenticated;
select pg_temp.sign_in('b');
do $$
begin
  assert not public.approve_tv_login_session((pg_temp.login('replaced')).user_code),
    'a cancelled code was approved';
end;
$$;
select pg_temp.sign_out();
reset role;

-- Wrong codes are rate limited per account. Start from a clean count (the
-- expired and replaced codes above were failures too).
delete from public.orvix_tv_login_approval_attempts
where user_id = current_setting('test.b')::uuid;
select pg_temp.start('guess-target');
set role authenticated;
select pg_temp.sign_in('b');
do $$
begin
  assert not public.approve_tv_login_session('not a code'), 'an invalid code was approved';
  for i in 1..9 loop
    assert not public.approve_tv_login_session('ZZZZZZ'), 'a wrong code was approved';
  end loop;
  -- Ten failures, so the next attempt is refused even for a valid code.
  begin
    perform public.approve_tv_login_session((pg_temp.login('guess-target')).user_code);
    raise exception 'approval was not rate limited';
  exception when raise_exception then
    if sqlerrm <> 'Too many TV code attempts. Try again later.' then raise; end if;
  end;
end;
$$;
select pg_temp.sign_out();
reset role;

-- Another account is not affected by that limit.
set role authenticated;
select pg_temp.sign_in('a');
do $$
begin
  assert public.approve_tv_login_session((pg_temp.login('guess-target')).user_code),
    'one account''s failures blocked another account';
end;
$$;
select pg_temp.sign_out();
reset role;

-- Attempts are removed with the account.
delete from auth.users where id = current_setting('test.b')::uuid;
do $$
begin
  assert not exists (
    select 1 from public.orvix_tv_login_approval_attempts
    where user_id = current_setting('test.b')::uuid
  ), 'approval attempts outlived the account';
end;
$$;

select 'tv login checks passed' as result;
