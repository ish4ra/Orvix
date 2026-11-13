-- Watch Party, phase 1: private rooms, authoritative playback state and
-- room chat. See docs/WATCH_PARTY.md.
--
-- Access model: every table is RPC-only (row level security on, no policies,
-- no privileges for anon or authenticated). Signed-in users reach rooms only
-- through the watch_party_* functions below, which take the caller from
-- auth.uid() and never from an argument. Room events are sent by the
-- database to a private Realtime Broadcast topic; clients can listen to that
-- topic only while they are an active participant and can never send on it.
--
-- Nothing here carries media, stream URLs, provider credentials or tokens:
-- a room holds a catalog id, a playback position and chat text.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.orvix_watch_rooms (
  id uuid primary key default gen_random_uuid(),
  -- Eight characters from a 32-symbol alphabet (40 random bits).
  invite_code text not null unique,
  -- Names the Realtime topic. Replaced when a participant is removed, so a
  -- removed client that is still connected stops receiving room events.
  channel_key uuid not null default gen_random_uuid(),
  host_user_id uuid not null references auth.users(id) on delete cascade,
  media_kind text check (media_kind in ('movie', 'series')),
  media_id text check (char_length(media_id) between 1 and 64),
  media_season integer check (media_season between 0 and 10000),
  media_episode integer check (media_episode between 0 and 100000),
  media_title text check (char_length(media_title) <= 160),
  media_year text check (char_length(media_year) <= 8),
  -- Authoritative playback state: position_ms was the position at
  -- position_at. While is_playing, the position advances with server time.
  is_playing boolean not null default false,
  position_ms bigint not null default 0 check (position_ms between 0 and 86400000),
  position_at timestamptz not null default clock_timestamp(),
  state_seq bigint not null default 0,
  roster_seq bigint not null default 0,
  chat_seq bigint not null default 0,
  created_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '12 hours')
);

create index if not exists orvix_watch_rooms_expiry_idx
  on public.orvix_watch_rooms (expires_at);
create index if not exists orvix_watch_rooms_activity_idx
  on public.orvix_watch_rooms (last_activity_at);

create table if not exists public.orvix_watch_room_participants (
  room_id uuid not null references public.orvix_watch_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- The only participant identifier other members ever see. Account ids
  -- and emails never leave these functions.
  participant_id uuid not null unique default gen_random_uuid(),
  display_name text not null check (char_length(display_name) between 1 and 24),
  is_ready boolean not null default false,
  is_buffering boolean not null default false,
  duration_ms bigint check (duration_ms between 0 and 86400000),
  -- Wall-clock time, not transaction time: join order decides who takes
  -- over from a host who disappears.
  joined_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),
  left_at timestamptz,
  -- Removed by the host: cannot rejoin this room.
  removed boolean not null default false,
  -- Highest playback command number accepted from this participant.
  last_command_seq bigint not null default 0,
  primary key (room_id, user_id)
);

create index if not exists orvix_watch_room_participants_user_idx
  on public.orvix_watch_room_participants (user_id) where left_at is null;

create table if not exists public.orvix_watch_room_messages (
  room_id uuid not null references public.orvix_watch_rooms(id) on delete cascade,
  seq bigint not null,
  participant_id uuid not null,
  -- Chosen by the sender's app; makes a retried send return the first copy.
  client_id uuid not null,
  display_name text not null,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  primary key (room_id, seq),
  unique (room_id, participant_id, client_id)
);

create table if not exists public.orvix_watch_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  window_start timestamptz not null,
  hits integer not null,
  primary key (user_id, action)
);

alter table public.orvix_watch_rooms enable row level security;
alter table public.orvix_watch_room_participants enable row level security;
alter table public.orvix_watch_room_messages enable row level security;
alter table public.orvix_watch_rate_limits enable row level security;

revoke all on table public.orvix_watch_rooms from public, anon, authenticated;
revoke all on table public.orvix_watch_room_participants from public, anon, authenticated;
revoke all on table public.orvix_watch_room_messages from public, anon, authenticated;
revoke all on table public.orvix_watch_rate_limits from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable through the API)
-- ---------------------------------------------------------------------------

create or replace function public.orvix_watch_ms(p_at timestamptz)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select floor(extract(epoch from p_at) * 1000)::bigint;
$$;

create or replace function public.orvix_watch_error(p_code text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('ok', false, 'error', p_code);
$$;

-- An unpredictable invite code. gen_random_uuid() draws from the server's
-- cryptographic generator; bytes 6 and 8 hold the fixed UUID version and
-- variant bits and are skipped. 256 is a multiple of 32, so every symbol is
-- equally likely.
create or replace function public.orvix_watch_new_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := uuid_send(gen_random_uuid());
  v_code text := '';
  v_index integer;
begin
  foreach v_index in array array[0, 1, 2, 3, 4, 5, 7, 9] loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, v_index) % 32) + 1, 1);
  end loop;
  return v_code;
end;
$$;

-- One line of display text: control characters become spaces, bidirectional
-- override and isolate characters are dropped (they can disguise text), and
-- whitespace is collapsed. Zero-width joiners stay: Sinhala needs them.
create or replace function public.orvix_watch_clean_text(p_text text, p_max integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(
    btrim(
      regexp_replace(
        regexp_replace(
          regexp_replace(coalesce(p_text, ''), '[\u202A-\u202E\u2066-\u2069\uFEFF]', '', 'g'),
          '[[:cntrl:]]', ' ', 'g'),
        '\s+', ' ', 'g')),
    p_max);
$$;

-- Fixed-window rate limit. Returns false once p_max calls were made inside
-- the current window. The row is written even for a refused call, so callers
-- must return an error value rather than raise (a raise would roll it back).
create or replace function public.orvix_watch_rate_ok(
  p_user uuid,
  p_action text,
  p_max integer,
  p_window interval
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_hits integer;
begin
  insert into public.orvix_watch_rate_limits as r (user_id, action, window_start, hits)
  values (p_user, p_action, v_now, 1)
  on conflict (user_id, action) do update
    set hits = case
          when r.window_start + p_window <= v_now then 1
          else least(r.hits + 1, p_max + 1)
        end,
        window_start = case
          when r.window_start + p_window <= v_now then v_now
          else r.window_start
        end
  returning r.hits into v_hits;
  return v_hits <= p_max;
end;
$$;

create or replace function public.orvix_watch_room_alive(p_room public.orvix_watch_rooms)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_room.id is not null
     and p_room.expires_at > clock_timestamp()
     and p_room.last_activity_at > clock_timestamp() - interval '30 minutes';
$$;

create or replace function public.orvix_watch_media_key(p_room public.orvix_watch_rooms)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_room.media_id is null then null else
    p_room.media_kind || ':' || p_room.media_id || ':' ||
    coalesce(p_room.media_season::text, '-') || ':' ||
    coalesce(p_room.media_episode::text, '-')
  end;
$$;

create or replace function public.orvix_watch_playback_json(p_room public.orvix_watch_rooms)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'playback', jsonb_build_object(
      'seq', p_room.state_seq,
      'playing', p_room.is_playing,
      'position_ms', p_room.position_ms,
      'at_ms', public.orvix_watch_ms(p_room.position_at)),
    'media', case when p_room.media_id is null then null else jsonb_build_object(
      'kind', p_room.media_kind,
      'id', p_room.media_id,
      'season', p_room.media_season,
      'episode', p_room.media_episode,
      'title', p_room.media_title,
      'year', p_room.media_year,
      'key', public.orvix_watch_media_key(p_room)) end);
$$;

create or replace function public.orvix_watch_roster_json(p_room public.orvix_watch_rooms)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'seq', p_room.roster_seq,
    'host', (
      select h.participant_id from public.orvix_watch_room_participants h
      where h.room_id = p_room.id and h.user_id = p_room.host_user_id),
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', p.participant_id,
          'name', p.display_name,
          'ready', p.is_ready,
          'buffering', p.is_buffering,
          'online', p.last_seen_at > clock_timestamp() - interval '45 seconds',
          'duration_ms', p.duration_ms)
        order by p.joined_at, p.participant_id)
      from public.orvix_watch_room_participants p
      where p.room_id = p_room.id and p.left_at is null), '[]'::jsonb));
$$;

-- Sends one event to the room's private Realtime topic. A scratch database
-- has no Realtime; there, and if Realtime ever refuses the message, the room
-- transaction still commits and clients catch up through watch_party_sync.
create or replace function public.orvix_watch_broadcast(
  p_channel_key uuid,
  p_event text,
  p_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(p_payload, p_event, 'watch_party:' || p_channel_key::text, true);
exception
  when invalid_schema_name or undefined_function then
    null;
  when others then
    raise warning 'watch party broadcast failed: %', sqlerrm;
end;
$$;

-- Bumps the roster version and tells the room. The caller holds the room row
-- lock.
create or replace function public.orvix_watch_roster_changed(p_room_id uuid)
returns public.orvix_watch_rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.orvix_watch_rooms;
begin
  update public.orvix_watch_rooms
  set roster_seq = roster_seq + 1
  where id = p_room_id
  returning * into v_room;
  perform public.orvix_watch_broadcast(
    v_room.channel_key, 'roster', public.orvix_watch_roster_json(v_room));
  return v_room;
end;
$$;

-- Presence housekeeping for one room. The caller holds the room row lock.
--   * A participant silent for two minutes gives up their place (they can
--     come back with the invite code).
--   * A host silent for one minute hands the room to the longest-present
--     participant who is online. Playback is left as it is.
-- Returns true when the roster changed.
create or replace function public.orvix_watch_maintain(p_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_room public.orvix_watch_rooms;
  v_host_seen timestamptz;
  v_host_left timestamptz;
  v_new_host uuid;
  v_changed boolean := false;
  v_rows integer;
begin
  select * into v_room from public.orvix_watch_rooms where id = p_room_id;
  if not found then
    return false;
  end if;

  select p.last_seen_at, p.left_at into v_host_seen, v_host_left
  from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.user_id = v_room.host_user_id;

  if v_host_seen is null
     or v_host_left is not null
     or v_host_seen < v_now - interval '60 seconds' then
    select p.user_id into v_new_host
    from public.orvix_watch_room_participants p
    where p.room_id = p_room_id
      and p.left_at is null
      and p.user_id <> v_room.host_user_id
      and p.last_seen_at > v_now - interval '45 seconds'
    order by p.joined_at, p.participant_id
    limit 1;
    if v_new_host is not null then
      update public.orvix_watch_rooms set host_user_id = v_new_host where id = p_room_id;
      v_room.host_user_id := v_new_host;
      v_changed := true;
    end if;
  end if;

  update public.orvix_watch_room_participants p
  set left_at = v_now, is_ready = false, is_buffering = false
  where p.room_id = p_room_id
    and p.left_at is null
    and p.user_id <> v_room.host_user_id
    and p.last_seen_at < v_now - interval '2 minutes';
  get diagnostics v_rows = row_count;
  if v_rows > 0 then
    v_changed := true;
  end if;

  if v_changed then
    perform public.orvix_watch_roster_changed(p_room_id);
  end if;
  return v_changed;
end;
$$;

-- Takes p_user out of a room. The caller holds the room row lock. The room
-- is deleted when nobody is left; a departing host hands over first.
create or replace function public.orvix_watch_leave_internal(
  p_room_id uuid,
  p_user_id uuid,
  p_removed boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_room public.orvix_watch_rooms;
  v_new_host uuid;
  v_old_key uuid;
begin
  select * into v_room from public.orvix_watch_rooms where id = p_room_id;
  if not found then
    return;
  end if;

  update public.orvix_watch_room_participants p
  set left_at = coalesce(p.left_at, v_now),
      removed = p.removed or p_removed,
      is_ready = false,
      is_buffering = false
  where p.room_id = p_room_id and p.user_id = p_user_id;
  if not found then
    return;
  end if;

  if not exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.left_at is null
  ) then
    perform public.orvix_watch_broadcast(
      v_room.channel_key, 'closed', jsonb_build_object('reason', 'empty'));
    delete from public.orvix_watch_rooms where id = p_room_id;
    return;
  end if;

  if v_room.host_user_id = p_user_id then
    select p.user_id into v_new_host
    from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.left_at is null
    order by (p.last_seen_at > v_now - interval '45 seconds') desc,
             p.joined_at, p.participant_id
    limit 1;
    update public.orvix_watch_rooms set host_user_id = v_new_host where id = p_room_id;
  end if;

  v_room := public.orvix_watch_roster_changed(p_room_id);

  if p_removed then
    -- The removed client may still be connected to the old topic. Everyone
    -- else is told to fetch the new one, which only members can read.
    v_old_key := v_room.channel_key;
    update public.orvix_watch_rooms set channel_key = gen_random_uuid() where id = p_room_id;
    perform public.orvix_watch_broadcast(v_old_key, 'rekey', '{}'::jsonb);
  end if;
end;
$$;

-- Locks p_room_id and every other room p_user is active in, always in id
-- order so two users moving between the same rooms cannot deadlock.
create or replace function public.orvix_watch_lock_rooms(p_user uuid, p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.orvix_watch_rooms r
  where r.id = p_room_id
     or r.id in (
       select p.room_id from public.orvix_watch_room_participants p
       where p.user_id = p_user and p.left_at is null)
  order by r.id
  for update;
end;
$$;

-- One room per account at a time: takes p_user out of every room except
-- p_room_id. The caller holds the locks from orvix_watch_lock_rooms and
-- calls this only once nothing can refuse the move any more, so a failed
-- attempt to join another room never costs someone their current one.
create or replace function public.orvix_watch_leave_others(p_user uuid, p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_other uuid;
begin
  for v_other in
    select p.room_id from public.orvix_watch_room_participants p
    where p.user_id = p_user and p.left_at is null
      and (p_room_id is null or p.room_id <> p_room_id)
    order by p.room_id
  loop
    perform public.orvix_watch_leave_internal(v_other, p_user, false);
  end loop;
end;
$$;

-- Everything a member needs to (re)build their view of the room.
create or replace function public.orvix_watch_snapshot(
  p_room public.orvix_watch_rooms,
  p_user uuid,
  p_after_chat_seq bigint
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ok', true,
    'server_time_ms', public.orvix_watch_ms(clock_timestamp()),
    'you', (
      select p.participant_id from public.orvix_watch_room_participants p
      where p.room_id = p_room.id and p.user_id = p_user),
    -- The caller's own highest accepted playback command number, so a
    -- reinstalled or second device continues above it.
    'command_seq', (
      select p.last_command_seq from public.orvix_watch_room_participants p
      where p.room_id = p_room.id and p.user_id = p_user),
    'room', jsonb_build_object(
      'id', p_room.id,
      'code', p_room.invite_code,
      'topic', 'watch_party:' || p_room.channel_key::text,
      'expires_at_ms', public.orvix_watch_ms(p_room.expires_at),
      'max_participants', 10,
      'chat_seq', p_room.chat_seq) || public.orvix_watch_playback_json(p_room),
    'roster', public.orvix_watch_roster_json(p_room),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
          'seq', m.seq,
          'from', m.participant_id,
          'name', m.display_name,
          'body', m.body,
          'at_ms', public.orvix_watch_ms(m.created_at))
        order by m.seq)
      from public.orvix_watch_room_messages m
      where m.room_id = p_room.id
        and m.seq > greatest(coalesce(p_after_chat_seq, 0), p_room.chat_seq - 50)), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------------
-- Client API (signed-in users only)
-- ---------------------------------------------------------------------------

-- Deletes rooms past their lifetime (12 hours) or idle for 30 minutes, and
-- stale rate-limit rows. Run on a schedule with the service role; creating a
-- room also runs a small pass, so storage stays bounded without a schedule.
create or replace function public.orvix_watch_party_cleanup(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  with doomed as (
    select r.id from public.orvix_watch_rooms r
    where r.expires_at <= clock_timestamp()
       or r.last_activity_at <= clock_timestamp() - interval '30 minutes'
    order by r.expires_at
    limit greatest(coalesce(p_limit, 500), 0)
    for update skip locked
  )
  delete from public.orvix_watch_rooms r using doomed d where r.id = d.id;
  get diagnostics v_deleted = row_count;

  delete from public.orvix_watch_rate_limits l
  where l.window_start < clock_timestamp() - interval '1 day';
  return v_deleted;
end;
$$;

create or replace function public.watch_party_create(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := public.orvix_watch_clean_text(p_display_name, 24);
  v_code text;
  v_room public.orvix_watch_rooms;
  v_tries integer := 0;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  if not public.orvix_watch_rate_ok(v_uid, 'create', 6, interval '1 hour') then
    return public.orvix_watch_error('rate_limited');
  end if;
  if v_name = '' then
    return public.orvix_watch_error('invalid_name');
  end if;

  perform public.orvix_watch_party_cleanup(25);
  perform public.orvix_watch_lock_rooms(v_uid, null);
  perform public.orvix_watch_leave_others(v_uid, null);

  loop
    v_code := public.orvix_watch_new_code();
    begin
      insert into public.orvix_watch_rooms (invite_code, host_user_id)
      values (v_code, v_uid)
      returning * into v_room;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries >= 5 then
        return public.orvix_watch_error('unavailable');
      end if;
    end;
  end loop;

  insert into public.orvix_watch_room_participants (room_id, user_id, display_name)
  values (v_room.id, v_uid, v_name);
  update public.orvix_watch_rooms set roster_seq = 1 where id = v_room.id
  returning * into v_room;

  return public.orvix_watch_snapshot(v_room, v_uid, null);
end;
$$;

create or replace function public.watch_party_join(p_invite_code text, p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := public.orvix_watch_clean_text(p_display_name, 24);
  v_code text := upper(regexp_replace(coalesce(p_invite_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_room public.orvix_watch_rooms;
  v_existing public.orvix_watch_room_participants;
  v_active integer;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  -- Counts every attempt, so invite codes cannot be searched.
  if not public.orvix_watch_rate_ok(v_uid, 'join', 10, interval '10 minutes') then
    return public.orvix_watch_error('rate_limited');
  end if;
  if v_name = '' then
    return public.orvix_watch_error('invalid_name');
  end if;
  if char_length(v_code) <> 8 then
    return public.orvix_watch_error('not_found');
  end if;

  select * into v_room from public.orvix_watch_rooms where invite_code = v_code;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('not_found');
  end if;

  perform public.orvix_watch_lock_rooms(v_uid, v_room.id);
  -- Re-read under the lock: the room may have closed or filled meanwhile.
  select * into v_room from public.orvix_watch_rooms where id = v_room.id;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('not_found');
  end if;

  select * into v_existing from public.orvix_watch_room_participants p
  where p.room_id = v_room.id and p.user_id = v_uid;
  if found and v_existing.removed then
    return public.orvix_watch_error('removed');
  end if;

  if not found or v_existing.left_at is not null then
    select count(*) into v_active from public.orvix_watch_room_participants p
    where p.room_id = v_room.id and p.left_at is null;
    if v_active >= 10 then
      -- Places held by people who silently dropped are released first.
      perform public.orvix_watch_maintain(v_room.id);
      select count(*) into v_active from public.orvix_watch_room_participants p
      where p.room_id = v_room.id and p.left_at is null;
      if v_active >= 10 then
        return public.orvix_watch_error('room_full');
      end if;
    end if;
  end if;

  -- Nothing can refuse the join from here on.
  perform public.orvix_watch_leave_others(v_uid, v_room.id);

  insert into public.orvix_watch_room_participants as p (room_id, user_id, display_name)
  values (v_room.id, v_uid, v_name)
  on conflict (room_id, user_id) do update
    set display_name = excluded.display_name,
        joined_at = case when p.left_at is null then p.joined_at else clock_timestamp() end,
        last_seen_at = clock_timestamp(),
        left_at = null,
        is_ready = false,
        is_buffering = false;

  update public.orvix_watch_rooms set last_activity_at = clock_timestamp()
  where id = v_room.id;
  v_room := public.orvix_watch_roster_changed(v_room.id);
  return public.orvix_watch_snapshot(v_room, v_uid, null);
end;
$$;

create or replace function public.watch_party_leave(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  perform 1 from public.orvix_watch_rooms where id = p_room_id for update;
  if found and exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null
  ) then
    perform public.orvix_watch_leave_internal(p_room_id, v_uid, false);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Heartbeat, status report and catch-up in one call. Every participant
-- calls it on a timer; it is also how a client recovers after missing
-- Realtime events (the reply always carries the full current state).
create or replace function public.watch_party_sync(
  p_room_id uuid,
  p_after_chat_seq bigint default null,
  p_ready boolean default null,
  p_buffering boolean default null,
  p_media_key text default null,
  p_duration_ms bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  v_room public.orvix_watch_rooms;
  v_me public.orvix_watch_room_participants;
  v_ready boolean;
  v_buffering boolean;
  v_duration bigint;
  v_mismatch boolean := false;
  v_status_changed boolean;
  v_needs_lock boolean;
  v_result jsonb;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;

  select * into v_room from public.orvix_watch_rooms where id = p_room_id;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  select * into v_me from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.user_id = v_uid;
  if not found or v_me.left_at is not null then
    return public.orvix_watch_error(case when v_me.removed then 'removed' else 'not_member' end);
  end if;

  v_ready := coalesce(p_ready, v_me.is_ready);
  v_buffering := coalesce(p_buffering, v_me.is_buffering);
  v_duration := case
    when p_duration_ms between 0 and 86400000 then p_duration_ms
    else v_me.duration_ms
  end;
  -- "Ready" means: playing the room's title. Anything else is not ready.
  if v_ready and (p_media_key is not null or p_ready is not null)
     and p_media_key is distinct from public.orvix_watch_media_key(v_room) then
    v_mismatch := p_media_key is not null and v_room.media_id is not null;
    v_ready := false;
  end if;
  v_status_changed := v_ready is distinct from v_me.is_ready
    or v_buffering is distinct from v_me.is_buffering
    or v_duration is distinct from v_me.duration_ms;

  if v_status_changed then
    if not public.orvix_watch_rate_ok(v_uid, 'status', 40, interval '10 seconds') then
      return public.orvix_watch_error('rate_limited');
    end if;
  elsif v_me.last_seen_at > v_now - interval '700 milliseconds' then
    -- A plain heartbeat more than about once a second is refused without
    -- writing anything.
    return public.orvix_watch_error('rate_limited');
  end if;

  v_needs_lock := v_status_changed
    or v_room.last_activity_at < v_now - interval '60 seconds'
    or exists (
      select 1 from public.orvix_watch_room_participants p
      where p.room_id = p_room_id and p.left_at is null and (
        (p.user_id = v_room.host_user_id and p.last_seen_at < v_now - interval '60 seconds')
        or (p.user_id <> v_room.host_user_id and p.last_seen_at < v_now - interval '2 minutes')));

  -- Lock order is always room, then participant.
  if v_needs_lock then
    perform 1 from public.orvix_watch_rooms where id = p_room_id for update;
    update public.orvix_watch_rooms set last_activity_at = v_now where id = p_room_id;
  end if;

  update public.orvix_watch_room_participants p
  set last_seen_at = v_now,
      is_ready = v_ready,
      is_buffering = v_buffering,
      duration_ms = v_duration
  where p.room_id = p_room_id and p.user_id = v_uid;

  if v_needs_lock then
    if not public.orvix_watch_maintain(p_room_id) and v_status_changed then
      perform public.orvix_watch_roster_changed(p_room_id);
    end if;
  end if;

  select * into v_room from public.orvix_watch_rooms where id = p_room_id;
  v_result := public.orvix_watch_snapshot(v_room, v_uid, coalesce(p_after_chat_seq, v_room.chat_seq));
  if v_mismatch then
    v_result := v_result || jsonb_build_object('media_mismatch', true);
  end if;
  return v_result;
end;
$$;

-- The host sets what the room is watching. Playback restarts paused at the
-- beginning and everyone has to become ready again.
create or replace function public.watch_party_set_media(
  p_room_id uuid,
  p_kind text,
  p_media_id text,
  p_season integer default null,
  p_episode integer default null,
  p_title text default null,
  p_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.orvix_watch_rooms;
  v_title text := public.orvix_watch_clean_text(p_title, 160);
  v_year text := public.orvix_watch_clean_text(p_year, 8);
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  if not exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null
  ) then
    return public.orvix_watch_error('not_member');
  end if;
  if v_room.host_user_id <> v_uid then
    return public.orvix_watch_error('host_only');
  end if;
  if not public.orvix_watch_rate_ok(v_uid, 'media', 20, interval '10 minutes') then
    return public.orvix_watch_error('rate_limited');
  end if;
  if p_kind is null or p_kind not in ('movie', 'series')
     or p_media_id is null or p_media_id !~ '^[A-Za-z0-9:_.-]{1,64}$'
     or p_season not between 0 and 10000
     or p_episode not between 0 and 100000 then
    return public.orvix_watch_error('invalid_media');
  end if;

  update public.orvix_watch_rooms
  set media_kind = p_kind,
      media_id = p_media_id,
      media_season = p_season,
      media_episode = p_episode,
      media_title = nullif(v_title, ''),
      media_year = nullif(v_year, ''),
      is_playing = false,
      position_ms = 0,
      position_at = clock_timestamp(),
      state_seq = state_seq + 1,
      last_activity_at = clock_timestamp()
  where id = p_room_id
  returning * into v_room;

  update public.orvix_watch_room_participants p
  set is_ready = false, is_buffering = false, duration_ms = null
  where p.room_id = p_room_id;

  perform public.orvix_watch_broadcast(
    v_room.channel_key, 'state', public.orvix_watch_playback_json(v_room));
  v_room := public.orvix_watch_roster_changed(p_room_id);
  return public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq);
end;
$$;

-- The host publishes play, pause or seek as one absolute state: "at
-- p_observed_at_ms (server clock) the position was p_position_ms and the
-- player was / was not playing". The room assigns the next state number, so
-- every client applies states in one order.
--
-- p_client_seq must grow with every command from the same host. A command
-- that arrives late, after a newer one was accepted, or twice, is ignored.
create or replace function public.watch_party_set_playback(
  p_room_id uuid,
  p_playing boolean,
  p_position_ms bigint,
  p_client_seq bigint,
  p_observed_at_ms bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  v_room public.orvix_watch_rooms;
  v_me public.orvix_watch_room_participants;
  v_at timestamptz;
  v_position bigint;
  v_expected bigint;
  v_result jsonb;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  select * into v_me from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null;
  if not found then
    return public.orvix_watch_error('not_member');
  end if;
  if v_room.host_user_id <> v_uid then
    return public.orvix_watch_error('host_only');
  end if;
  if p_playing is null or p_position_ms is null or p_client_seq is null then
    return public.orvix_watch_error('invalid_state');
  end if;
  if v_room.media_id is null then
    return public.orvix_watch_error('no_media');
  end if;

  if p_client_seq <= v_me.last_command_seq then
    return public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq)
      || jsonb_build_object('stale', true);
  end if;
  if not public.orvix_watch_rate_ok(v_uid, 'playback', 30, interval '10 seconds') then
    return public.orvix_watch_error('rate_limited');
  end if;

  v_position := least(greatest(p_position_ms, 0), 86400000);
  -- The host's own reading of the server clock is trusted only within a
  -- few seconds of the real one.
  v_at := v_now;
  if p_observed_at_ms is not null then
    v_at := to_timestamp(p_observed_at_ms / 1000.0);
    v_at := least(v_at, v_now);
    v_at := greatest(v_at, v_now - interval '5 seconds');
  end if;

  update public.orvix_watch_room_participants p
  set last_command_seq = p_client_seq, last_seen_at = v_now
  where p.room_id = p_room_id and p.user_id = v_uid;

  -- A command that describes the state the room is already in changes
  -- nothing and is not announced.
  v_expected := v_room.position_ms + case when v_room.is_playing
    then (public.orvix_watch_ms(v_at) - public.orvix_watch_ms(v_room.position_at))
    else 0 end;
  if p_playing = v_room.is_playing and abs(v_expected - v_position) < 300 then
    return public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq)
      || jsonb_build_object('unchanged', true);
  end if;

  update public.orvix_watch_rooms
  set is_playing = p_playing,
      position_ms = v_position,
      position_at = v_at,
      state_seq = state_seq + 1,
      last_activity_at = v_now
  where id = p_room_id
  returning * into v_room;

  perform public.orvix_watch_broadcast(
    v_room.channel_key, 'state', public.orvix_watch_playback_json(v_room));
  v_result := public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq);
  return v_result;
end;
$$;

create or replace function public.watch_party_send_message(
  p_room_id uuid,
  p_body text,
  p_client_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := public.orvix_watch_clean_text(p_body, 2000);
  v_room public.orvix_watch_rooms;
  v_me public.orvix_watch_room_participants;
  v_message public.orvix_watch_room_messages;
  v_payload jsonb;
  v_new boolean := false;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  if p_client_id is null or v_body = '' or char_length(v_body) > 500 then
    return public.orvix_watch_error('invalid_message');
  end if;

  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  select * into v_me from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null;
  if not found then
    return public.orvix_watch_error('not_member');
  end if;

  select * into v_message from public.orvix_watch_room_messages m
  where m.room_id = p_room_id
    and m.participant_id = v_me.participant_id
    and m.client_id = p_client_id;
  if not found then
    if not public.orvix_watch_rate_ok(v_uid, 'chat', 8, interval '10 seconds') then
      return public.orvix_watch_error('rate_limited');
    end if;
    update public.orvix_watch_rooms
    set chat_seq = chat_seq + 1, last_activity_at = clock_timestamp()
    where id = p_room_id
    returning * into v_room;

    insert into public.orvix_watch_room_messages
      (room_id, seq, participant_id, client_id, display_name, body)
    values
      (p_room_id, v_room.chat_seq, v_me.participant_id, p_client_id, v_me.display_name, v_body)
    returning * into v_message;
    v_new := true;

    -- Only the latest 200 messages of a room are kept.
    delete from public.orvix_watch_room_messages m
    where m.room_id = p_room_id and m.seq <= v_room.chat_seq - 200;
  end if;

  v_payload := jsonb_build_object(
    'seq', v_message.seq,
    'from', v_message.participant_id,
    'name', v_message.display_name,
    'body', v_message.body,
    'at_ms', public.orvix_watch_ms(v_message.created_at));
  if v_new then
    perform public.orvix_watch_broadcast(v_room.channel_key, 'chat', v_payload);
  end if;
  return jsonb_build_object(
    'ok', true,
    'server_time_ms', public.orvix_watch_ms(clock_timestamp()),
    'message', v_payload);
end;
$$;

create or replace function public.watch_party_remove_participant(
  p_room_id uuid,
  p_participant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.orvix_watch_rooms;
  v_target uuid;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  if not exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null
  ) then
    return public.orvix_watch_error('not_member');
  end if;
  if v_room.host_user_id <> v_uid then
    return public.orvix_watch_error('host_only');
  end if;
  select p.user_id into v_target from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.participant_id = p_participant_id and p.left_at is null;
  if not found or v_target = v_uid then
    return public.orvix_watch_error('invalid_participant');
  end if;

  perform public.orvix_watch_leave_internal(p_room_id, v_target, true);
  select * into v_room from public.orvix_watch_rooms where id = p_room_id;
  return public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq);
end;
$$;

create or replace function public.watch_party_transfer_host(
  p_room_id uuid,
  p_participant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.orvix_watch_rooms;
  v_target uuid;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found or not public.orvix_watch_room_alive(v_room) then
    return public.orvix_watch_error('room_closed');
  end if;
  if not exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null
  ) then
    return public.orvix_watch_error('not_member');
  end if;
  if v_room.host_user_id <> v_uid then
    return public.orvix_watch_error('host_only');
  end if;
  select p.user_id into v_target from public.orvix_watch_room_participants p
  where p.room_id = p_room_id and p.participant_id = p_participant_id and p.left_at is null;
  if not found or v_target = v_uid then
    return public.orvix_watch_error('invalid_participant');
  end if;

  update public.orvix_watch_rooms
  set host_user_id = v_target, last_activity_at = clock_timestamp()
  where id = p_room_id;
  v_room := public.orvix_watch_roster_changed(p_room_id);
  return public.orvix_watch_snapshot(v_room, v_uid, v_room.chat_seq);
end;
$$;

-- The host ends the room for everyone.
create or replace function public.watch_party_close(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.orvix_watch_rooms;
begin
  if v_uid is null then
    return public.orvix_watch_error('auth_required');
  end if;
  select * into v_room from public.orvix_watch_rooms where id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', true);
  end if;
  if not exists (
    select 1 from public.orvix_watch_room_participants p
    where p.room_id = p_room_id and p.user_id = v_uid and p.left_at is null
  ) then
    return public.orvix_watch_error('not_member');
  end if;
  if v_room.host_user_id <> v_uid then
    return public.orvix_watch_error('host_only');
  end if;
  perform public.orvix_watch_broadcast(
    v_room.channel_key, 'closed', jsonb_build_object('reason', 'host'));
  delete from public.orvix_watch_rooms where id = p_room_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- Realtime authorization: may the caller listen to this topic? True only
-- for an active participant of the live room that currently owns the topic.
create or replace function public.orvix_watch_party_can_listen(p_topic text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.orvix_watch_room_participants p
    join public.orvix_watch_rooms r on r.id = p.room_id
    where p.user_id = auth.uid()
      and p.left_at is null
      and not p.removed
      and 'watch_party:' || r.channel_key::text = p_topic
      and r.expires_at > clock_timestamp());
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

do $$
declare
  v_function regprocedure;
begin
  for v_function in
    select p.oid::regprocedure from pg_catalog.pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'orvix\_watch\_%' or p.proname like 'watch\_party\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_function);
  end loop;
end;
$$;

grant execute on function public.watch_party_create(text) to authenticated;
grant execute on function public.watch_party_join(text, text) to authenticated;
grant execute on function public.watch_party_leave(uuid) to authenticated;
grant execute on function public.watch_party_sync(uuid, bigint, boolean, boolean, text, bigint) to authenticated;
grant execute on function public.watch_party_set_media(uuid, text, text, integer, integer, text, text) to authenticated;
grant execute on function public.watch_party_set_playback(uuid, boolean, bigint, bigint, bigint) to authenticated;
grant execute on function public.watch_party_send_message(uuid, text, uuid) to authenticated;
grant execute on function public.watch_party_remove_participant(uuid, uuid) to authenticated;
grant execute on function public.watch_party_transfer_host(uuid, uuid) to authenticated;
grant execute on function public.watch_party_close(uuid) to authenticated;
grant execute on function public.orvix_watch_party_can_listen(text) to authenticated;
grant execute on function public.orvix_watch_party_cleanup(integer) to service_role;

-- ---------------------------------------------------------------------------
-- Realtime authorization
-- ---------------------------------------------------------------------------

-- Private Broadcast topics are authorized by row level security on
-- realtime.messages. Members may receive (SELECT) their room's broadcasts.
-- There is deliberately no INSERT policy for watch party topics: clients
-- cannot send on them, and no presence policy: presence is not used.
-- Skipped where Realtime is not installed (a scratch database).
do $$
begin
  if exists (
    select 1 from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'realtime' and c.relname = 'messages'
  ) then
    execute 'drop policy if exists "Watch party members receive room broadcasts" on realtime.messages';
    execute $policy$
      create policy "Watch party members receive room broadcasts"
      on realtime.messages
      for select
      to authenticated
      using (
        extension = 'broadcast'
        and (select realtime.topic()) like 'watch\_party:%'
        and public.orvix_watch_party_can_listen((select realtime.topic()))
      )
    $policy$;
  end if;
end;
$$;
