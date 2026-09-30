-- TV device-link login sessions, modeled after the short-lived device-code flow used by Nuvio.
create table if not exists public.orvix_tv_login_sessions (
  device_code uuid primary key default gen_random_uuid(),
  user_code text not null unique,
  device_nonce uuid not null,
  status text not null default 'pending' check (status in ('pending','approved','consumed')),
  approved_user_id uuid references auth.users(id) on delete cascade,
  device_name text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  approved_at timestamptz,
  consumed_at timestamptz
);

alter table public.orvix_tv_login_sessions enable row level security;

revoke all on public.orvix_tv_login_sessions from anon, authenticated;

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
  v_code text;
  v_device uuid;
begin
  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (
      select 1 from public.orvix_tv_login_sessions s
      where s.user_code = v_code and s.expires_at > now()
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

create or replace function public.poll_tv_login_session(
  p_device_code uuid,
  p_device_nonce uuid
)
returns table(status text)
language sql
security definer
set search_path = public
as $$
  select case
    when s.expires_at <= now() then 'expired'
    else s.status
  end
  from public.orvix_tv_login_sessions s
  where s.device_code = p_device_code
    and s.device_nonce = p_device_nonce;
$$;

create or replace function public.approve_tv_login_session(p_user_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  update public.orvix_tv_login_sessions
  set status = 'approved',
      approved_user_id = v_uid,
      approved_at = now()
  where user_code = upper(replace(trim(p_user_code), '-', ''))
    and status = 'pending'
    and expires_at > now();

  return found;
end;
$$;

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
  returning s.approved_user_id;
end;
$$;

revoke all on function public.claim_tv_login_session(uuid, uuid) from public, anon, authenticated;
grant execute on function public.start_tv_login_session(uuid, text) to anon, authenticated;
grant execute on function public.poll_tv_login_session(uuid, uuid) to anon, authenticated;
grant execute on function public.approve_tv_login_session(text) to authenticated;
