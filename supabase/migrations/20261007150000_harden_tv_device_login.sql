-- Hardens the Android TV device login (QR code) flow.
--
-- 1. Approval needs a signed-in Orvix account. approve_tv_login_session no
--    longer has EXECUTE for anon (Supabase grants new functions to anon by
--    default), and an account that keeps entering wrong codes is slowed down.
-- 2. The visible code uses a 32-letter alphabet without look-alike letters
--    (about a billion codes instead of 16.7 million hex codes) and is checked
--    against every stored row, so an old expired row can no longer make the
--    unique constraint reject a new login. Rows expired for over an hour are
--    removed.
-- 3. An approved login has a short exchange window, and the TV can cancel the
--    code it no longer shows, so approving an old QR does nothing.
-- 4. The exchange is two-phase. The tv-login-exchange Edge Function leases
--    the approved login, creates the session, and only then marks the login
--    consumed. A failure while creating the session releases the lease, so a
--    temporary error no longer destroys a valid approval, while a second
--    concurrent exchange cannot lease the same login. Only the service role
--    can run the exchange functions.
--
-- claim_tv_login_session stays for the Edge Function deployed before this
-- migration; it now refuses a login whose exchange is in progress.

alter table public.orvix_tv_login_sessions
  add column if not exists exchange_token uuid,
  add column if not exists exchange_expires_at timestamptz;

alter table public.orvix_tv_login_sessions
  drop constraint if exists orvix_tv_login_sessions_status_check;
alter table public.orvix_tv_login_sessions
  add constraint orvix_tv_login_sessions_status_check
  check (status in ('pending', 'approved', 'consumed', 'cancelled'));

create index if not exists orvix_tv_login_sessions_expires_at_idx
  on public.orvix_tv_login_sessions (expires_at);

-- Wrong codes entered by an account, for slowing down code guessing.
create table if not exists public.orvix_tv_login_approval_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists orvix_tv_login_approval_attempts_user_idx
  on public.orvix_tv_login_approval_attempts (user_id, attempted_at);

alter table public.orvix_tv_login_approval_attempts enable row level security;
revoke all on public.orvix_tv_login_approval_attempts from anon, authenticated;

create or replace function public.start_tv_login_session(
  p_device_nonce uuid,
  p_device_name text default 'Orvix TV'
)
returns table(device_code uuid, user_code text, verification_uri_complete text, poll_interval_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- 32 letters: 256 is a multiple of 32, so every letter is equally likely.
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
  v_device uuid;
begin
  if p_device_nonce is null then
    raise exception 'A device nonce is required';
  end if;

  delete from public.orvix_tv_login_sessions s
  where s.expires_at < now() - interval '1 hour';

  loop
    -- The first six bytes of a version 4 UUID are fully random.
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for i in 0..5 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
    end loop;
    exit when not exists (
      select 1 from public.orvix_tv_login_sessions s where s.user_code = v_code
    );
  end loop;

  insert into public.orvix_tv_login_sessions(user_code, device_nonce, device_name)
  values (v_code, p_device_nonce, left(coalesce(nullif(trim(p_device_name), ''), 'Orvix TV'), 80))
  returning orvix_tv_login_sessions.device_code into v_device;

  return query select
    v_device,
    v_code,
    'https://kpjuisxofwqxhbnnsyzf.supabase.co/functions/v1/tv-login-link?code=' || v_code,
    3;
end;
$$;

create or replace function public.approve_tv_login_session(p_user_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_user_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if (
    select count(*) from public.orvix_tv_login_approval_attempts a
    where a.user_id = v_uid and a.attempted_at > now() - interval '15 minutes'
  ) >= 10 then
    raise exception 'Too many TV code attempts. Try again later.'
      using errcode = 'P0001', hint = 'tv_login_rate_limited';
  end if;

  if length(v_code) = 6 then
    update public.orvix_tv_login_sessions s
    set status = 'approved',
        approved_user_id = v_uid,
        approved_at = now(),
        -- The TV exchanges within seconds; an unused approval soon expires.
        expires_at = now() + interval '2 minutes'
    where s.user_code = v_code
      and s.status = 'pending'
      and s.expires_at > now();
    if found then
      return true;
    end if;
  end if;

  insert into public.orvix_tv_login_approval_attempts (user_id) values (v_uid);
  delete from public.orvix_tv_login_approval_attempts a
  where a.attempted_at < now() - interval '1 day';
  return false;
end;
$$;

-- The TV stops showing a code (refresh, cancel, leaving the Account screen).
create or replace function public.cancel_tv_login_session(
  p_device_code uuid,
  p_device_nonce uuid
)
returns boolean
language sql
security definer
set search_path = public
as $$
  with cancelled as (
    update public.orvix_tv_login_sessions s
    set status = 'cancelled'
    where s.device_code = p_device_code
      and s.device_nonce = p_device_nonce
      and s.status in ('pending', 'approved')
      and (s.exchange_expires_at is null or s.exchange_expires_at <= now())
    returning 1
  )
  select exists (select 1 from cancelled);
$$;

-- Edge Function, step 1: lease an approved login for one exchange attempt.
-- state is 'leased' (user_id and exchange_token set), 'busy' while another
-- exchange holds the lease, or 'unavailable' for anything else, including a
-- wrong nonce, so the response reveals nothing about other logins.
create or replace function public.begin_tv_login_exchange(
  p_device_code uuid,
  p_device_nonce uuid
)
returns table(state text, user_id uuid, exchange_token uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token uuid := gen_random_uuid();
  v_user uuid;
begin
  update public.orvix_tv_login_sessions s
  set exchange_token = v_token,
      exchange_expires_at = now() + interval '60 seconds'
  where s.device_code = p_device_code
    and s.device_nonce = p_device_nonce
    and s.status = 'approved'
    and s.approved_user_id is not null
    and s.expires_at > now()
    and (s.exchange_expires_at is null or s.exchange_expires_at <= now())
  returning s.approved_user_id into v_user;

  if v_user is not null then
    return query select 'leased'::text, v_user, v_token;
    return;
  end if;

  if exists (
    select 1 from public.orvix_tv_login_sessions s
    where s.device_code = p_device_code
      and s.device_nonce = p_device_nonce
      and s.status = 'approved'
      and s.expires_at > now()
      and s.exchange_expires_at > now()
  ) then
    return query select 'busy'::text, null::uuid, null::uuid;
    return;
  end if;

  return query select 'unavailable'::text, null::uuid, null::uuid;
end;
$$;

-- Edge Function, step 2a: the session was created; the login is used up.
create or replace function public.complete_tv_login_exchange(
  p_device_code uuid,
  p_exchange_token uuid
)
returns boolean
language sql
security definer
set search_path = public
as $$
  with consumed as (
    update public.orvix_tv_login_sessions s
    set status = 'consumed',
        consumed_at = now(),
        exchange_token = null,
        exchange_expires_at = null
    where s.device_code = p_device_code
      and s.exchange_token = p_exchange_token
      and s.status = 'approved'
    returning 1
  )
  select exists (select 1 from consumed);
$$;

-- Edge Function, step 2b: creating the session failed; allow a retry.
create or replace function public.release_tv_login_exchange(
  p_device_code uuid,
  p_exchange_token uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.orvix_tv_login_sessions s
  set exchange_token = null,
      exchange_expires_at = null
  where s.device_code = p_device_code
    and s.exchange_token = p_exchange_token
    and s.status = 'approved';
$$;

-- Kept for the previously deployed Edge Function (single-step exchange).
create or replace function public.claim_tv_login_session(
  p_device_code uuid,
  p_device_nonce uuid
)
returns table(user_id uuid)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update public.orvix_tv_login_sessions s
  set status = 'consumed', consumed_at = now()
  where s.device_code = p_device_code
    and s.device_nonce = p_device_nonce
    and s.status = 'approved'
    and s.approved_user_id is not null
    and s.expires_at > now()
    and (s.exchange_expires_at is null or s.exchange_expires_at <= now())
  returning s.approved_user_id;
end;
$$;

-- Grants. Supabase grants EXECUTE on new functions to anon, authenticated
-- and service_role by default, so every role is listed explicitly.
revoke all on function public.start_tv_login_session(uuid, text) from public;
revoke all on function public.poll_tv_login_session(uuid, uuid) from public;
revoke all on function public.cancel_tv_login_session(uuid, uuid) from public;
grant execute on function public.start_tv_login_session(uuid, text) to anon, authenticated;
grant execute on function public.poll_tv_login_session(uuid, uuid) to anon, authenticated;
grant execute on function public.cancel_tv_login_session(uuid, uuid) to anon, authenticated;

revoke all on function public.approve_tv_login_session(text) from public, anon;
grant execute on function public.approve_tv_login_session(text) to authenticated;

revoke all on function public.claim_tv_login_session(uuid, uuid) from public, anon, authenticated;
revoke all on function public.begin_tv_login_exchange(uuid, uuid) from public, anon, authenticated;
revoke all on function public.complete_tv_login_exchange(uuid, uuid) from public, anon, authenticated;
revoke all on function public.release_tv_login_exchange(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_tv_login_session(uuid, uuid) to service_role;
grant execute on function public.begin_tv_login_exchange(uuid, uuid) to service_role;
grant execute on function public.complete_tv_login_exchange(uuid, uuid) to service_role;
grant execute on function public.release_tv_login_exchange(uuid, uuid) to service_role;
