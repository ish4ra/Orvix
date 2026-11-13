-- Watch Party database checks: room lifecycle, the ten-person limit, access
-- control, host-only actions, playback state ordering, chat rules, presence
-- housekeeping, expiry and Realtime authorization. Run with run.sh. Uses
-- placeholder users only.
\set ON_ERROR_STOP on

insert into auth.users (id, email)
select ('00000000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'user' || n || '@example.test'
from generate_series(1, 14) n;

create function pg_temp.uid(p_user integer) returns uuid
language sql as $$
  select ('00000000-0000-4000-8000-0000000000' || lpad(p_user::text, 2, '0'))::uuid
$$;

-- Runs one statement as a signed-in user and returns its jsonb result.
create function pg_temp.as_user(p_user integer, p_sql text) returns jsonb
language plpgsql as $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claim.sub', pg_temp.uid(p_user)::text, true);
  set local role authenticated;
  execute p_sql into v_result;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  return v_result;
end;
$$;

-- Lets "time pass" for heartbeats: every participant was last seen two
-- seconds earlier, so the next heartbeat is not refused as too frequent.
create function pg_temp.tick() returns void
language sql as $$
  update public.orvix_watch_room_participants
  set last_seen_at = last_seen_at - interval '2 seconds';
$$;

create function pg_temp.sync(p_user integer, p_room uuid) returns jsonb
language plpgsql as $$
begin
  perform pg_temp.tick();
  return pg_temp.as_user(p_user, format('select public.watch_party_sync(%L)', p_room));
end;
$$;

create function pg_temp.broadcasts(p_topic text, p_event text) returns bigint
language sql as $$
  select count(*) from realtime.messages m where m.topic = p_topic and m.event = p_event
$$;

create function pg_temp.participant_names(p_roster jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(p->>'name' order by ord), array[]::text[])
  from jsonb_array_elements(p_roster->'participants') with ordinality as t(p, ord)
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

do $$
declare
  v_table text;
  v_role text;
  v_function regprocedure;
begin
  foreach v_table in array array[
    'orvix_watch_rooms', 'orvix_watch_room_participants',
    'orvix_watch_room_messages', 'orvix_watch_rate_limits'
  ] loop
    assert (select relrowsecurity from pg_class where oid = format('public.%I', v_table)::regclass),
      format('public.%s has row level security off', v_table);
    assert not exists (select 1 from pg_policy where polrelid = format('public.%I', v_table)::regclass),
      format('public.%s must stay RPC-only (no policies)', v_table);
    foreach v_role in array array['anon', 'authenticated'] loop
      assert not has_table_privilege(v_role, format('public.%I', v_table),
          'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'),
        format('%s has a direct privilege on public.%s', v_role, v_table);
    end loop;
  end loop;

  -- anon can call nothing; signed-in users only the public API.
  for v_function in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'orvix\_watch\_%' or p.proname like 'watch\_party\_%')
  loop
    assert not has_function_privilege('anon', v_function, 'execute'),
      format('anon can execute %s', v_function);
    assert has_function_privilege('authenticated', v_function, 'execute')
        = (v_function::text like 'watch\_party\_%'
           or v_function::text = 'orvix_watch_party_can_listen(text)'),
      format('unexpected EXECUTE for authenticated on %s', v_function);
  end loop;
  assert has_function_privilege('service_role', 'public.orvix_watch_party_cleanup(integer)', 'execute'),
    'the service role cannot run cleanup';
end;
$$;

-- ---------------------------------------------------------------------------
-- Invite codes
-- ---------------------------------------------------------------------------

do $$
declare
  v_distinct bigint;
  v_bad bigint;
begin
  select count(distinct code), count(*) filter (where code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$')
    into v_distinct, v_bad
  from (select public.orvix_watch_new_code() as code from generate_series(1, 2000)) c;
  assert v_bad = 0, 'an invite code left the alphabet or the length';
  assert v_distinct = 2000, format('invite codes repeat: %s distinct of 2000', v_distinct);
end;
$$;

-- ---------------------------------------------------------------------------
-- Create and join
-- ---------------------------------------------------------------------------

do $$
declare
  v_created jsonb;
  v_joined jsonb;
  v_room uuid;
  v_code text;
  v_topic text;
  v_result jsonb;
begin
  v_created := pg_temp.as_user(1, $q$select public.watch_party_create('  Ali' || chr(10) || 'ce  ')$q$);
  assert (v_created->>'ok')::boolean, format('create failed: %s', v_created);
  v_room := (v_created->'room'->>'id')::uuid;
  v_code := v_created->'room'->>'code';
  v_topic := v_created->'room'->>'topic';
  perform set_config('test.room', v_room::text, false);
  perform set_config('test.code', v_code, false);
  perform set_config('test.topic', v_topic, false);

  assert v_code ~ '^[A-Z2-9]{8}$', 'create returned a malformed code';
  assert pg_temp.participant_names(v_created->'roster') = array['Ali ce'],
    format('creator name was not cleaned: %s', v_created->'roster');
  assert v_created->'roster'->>'host' = v_created->>'you', 'the creator is not the host';
  assert (v_created->'room'->>'max_participants')::int = 10, 'room limit is not ten';
  assert v_created->'room'->'media' = 'null'::jsonb, 'a new room already has media';
  assert not (v_created->'room'->'playback'->>'playing')::boolean, 'a new room is playing';
  -- No account identifier leaves the database.
  assert v_created::text not like '%' || pg_temp.uid(1)::text || '%', 'create leaked the account id';
  assert v_created::text not like '%example.test%', 'create leaked an email';

  -- A wrong code and a malformed code look the same.
  v_result := pg_temp.as_user(2, $q$select public.watch_party_join('ZZZZZZZZ', 'Bob')$q$);
  assert v_result->>'error' = 'not_found', format('wrong code: %s', v_result);
  v_result := pg_temp.as_user(2, $q$select public.watch_party_join('abc', 'Bob')$q$);
  assert v_result->>'error' = 'not_found', format('short code: %s', v_result);
  v_result := pg_temp.as_user(2, format($q$select public.watch_party_join(%L, '   ')$q$, v_code));
  assert v_result->>'error' = 'invalid_name', format('blank name: %s', v_result);

  -- Codes are accepted in any case and with separators.
  v_joined := pg_temp.as_user(2, format($q$select public.watch_party_join(%L, 'Bob')$q$,
    lower(substr(v_code, 1, 4)) || '-' || substr(v_code, 5)));
  assert (v_joined->>'ok')::boolean, format('join failed: %s', v_joined);
  assert pg_temp.participant_names(v_joined->'roster') = array['Ali ce', 'Bob'], 'roster after join';
  assert v_joined->>'you' <> v_created->>'you', 'two members share a participant id';
  assert v_joined->'roster'->>'host' = v_created->>'you', 'joining changed the host';
  assert v_joined::text not like '%' || pg_temp.uid(1)::text || '%'
     and v_joined::text not like '%' || pg_temp.uid(2)::text || '%', 'join leaked an account id';
  assert pg_temp.broadcasts(v_topic, 'roster') = 1, 'joining did not announce the roster once';

  -- Joining again is harmless and keeps the same place.
  v_result := pg_temp.as_user(2, format($q$select public.watch_party_join(%L, 'Bobby')$q$, v_code));
  assert v_result->>'you' = v_joined->>'you', 'rejoining changed the participant id';
  assert pg_temp.participant_names(v_result->'roster') = array['Ali ce', 'Bobby'], 'rename on rejoin';
end;
$$;

-- Guessing codes is rate limited, and failed guesses count.
do $$
declare
  v_result jsonb;
  v_attempt integer;
begin
  for v_attempt in 1..10 loop
    v_result := pg_temp.as_user(13, $q$select public.watch_party_join('AAAAAAAA', 'Guesser')$q$);
    assert v_result->>'error' = 'not_found', format('guess %s: %s', v_attempt, v_result);
  end loop;
  v_result := pg_temp.as_user(13, $q$select public.watch_party_join('AAAAAAAA', 'Guesser')$q$);
  assert v_result->>'error' = 'rate_limited', format('eleventh guess: %s', v_result);
  -- Even the right code is refused while limited.
  v_result := pg_temp.as_user(13, format($q$select public.watch_party_join(%L, 'Guesser')$q$,
    current_setting('test.code')));
  assert v_result->>'error' = 'rate_limited', format('limited user joined: %s', v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- Access control
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_topic text := current_setting('test.topic');
  v_result jsonb;
  v_count bigint;
begin
  -- User 3 is signed in but not a member.
  v_result := pg_temp.as_user(3, format('select public.watch_party_sync(%L)', v_room));
  assert v_result->>'error' = 'not_member', format('outsider sync: %s', v_result);
  assert v_result->'room' is null and v_result->'roster' is null, 'outsider received room data';
  v_result := pg_temp.as_user(3, format(
    $q$select public.watch_party_send_message(%L, 'hi', gen_random_uuid())$q$, v_room));
  assert v_result->>'error' = 'not_member', format('outsider chat: %s', v_result);
  v_result := pg_temp.as_user(3, format(
    'select public.watch_party_set_playback(%L, true, 0, 1)', v_room));
  assert v_result->>'error' = 'not_member', format('outsider playback: %s', v_result);
  v_result := pg_temp.as_user(3, format(
    $q$select public.watch_party_set_media(%L, 'movie', 'tt0000001')$q$, v_room));
  assert v_result->>'error' = 'not_member', format('outsider media: %s', v_result);
  v_result := pg_temp.as_user(3, format('select public.watch_party_close(%L)', v_room));
  assert v_result->>'error' = 'not_member', format('outsider close: %s', v_result);
  v_result := pg_temp.as_user(3, format('select public.watch_party_leave(%L)', v_room));
  assert (v_result->>'ok')::boolean, 'leaving a room you are not in must be harmless';
  assert (select count(*) from public.orvix_watch_room_participants
          where room_id = v_room and left_at is null) = 2, 'an outsider changed the roster';
  v_result := pg_temp.as_user(3, format('select public.watch_party_sync(%L)', gen_random_uuid()));
  assert v_result->>'error' = 'room_closed', format('unknown room: %s', v_result);

  -- Without a session nothing is callable.
  set local role anon;
  begin
    perform public.watch_party_create('Anon');
    raise exception 'anon created a room';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.watch_party_sync(v_room);
    raise exception 'anon read a room';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- Direct table access is closed to signed-in users.
  perform set_config('request.jwt.claim.sub', pg_temp.uid(1)::text, true);
  set local role authenticated;
  begin
    perform 1 from public.orvix_watch_rooms;
    raise exception 'a member read rooms directly';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.orvix_watch_rooms set host_user_id = pg_temp.uid(2);
    raise exception 'a member rewrote the host directly';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.orvix_watch_room_messages (room_id, seq, participant_id, client_id, display_name, body)
    values (v_room, 99, gen_random_uuid(), gen_random_uuid(), 'x', 'forged');
    raise exception 'a member inserted a message directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.orvix_watch_leave_internal(v_room, pg_temp.uid(2), true);
    raise exception 'a member called an internal helper';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.orvix_watch_party_cleanup(10);
    raise exception 'a member ran cleanup';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- Realtime: only members may listen, and nobody may send.
  perform set_config('realtime.topic', v_topic, true);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(2)::text, true);
  set local role authenticated;
  select count(*) into v_count from realtime.messages;
  assert v_count > 0, 'a member cannot receive room broadcasts';
  assert public.orvix_watch_party_can_listen(v_topic), 'member refused on own topic';
  begin
    insert into realtime.messages (topic, extension, payload, event, private)
    values (v_topic, 'broadcast', '{"playing":true}', 'state', true);
    raise exception 'a member sent a room event directly';
  exception when insufficient_privilege then null;
  end;
  reset role;

  perform set_config('request.jwt.claim.sub', pg_temp.uid(3)::text, true);
  set local role authenticated;
  select count(*) into v_count from realtime.messages;
  assert v_count = 0, 'an outsider received room broadcasts';
  assert not public.orvix_watch_party_can_listen(v_topic), 'outsider allowed on topic';
  reset role;

  set local role anon;
  select count(*) into v_count from realtime.messages;
  assert v_count = 0, 'anon received room broadcasts';
  reset role;

  -- A member of one room cannot listen to another room's topic.
  perform set_config('realtime.topic', 'watch_party:' || gen_random_uuid()::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(2)::text, true);
  set local role authenticated;
  select count(*) into v_count from realtime.messages;
  assert v_count = 0, 'a member can listen to a foreign topic';
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('realtime.topic', '', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Host-only actions
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_host_pid text;
  v_result jsonb;
begin
  select participant_id::text into v_host_pid from public.orvix_watch_room_participants
  where room_id = v_room and user_id = pg_temp.uid(1);

  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_set_media(%L, 'movie', 'tt0000001')$q$, v_room));
  assert v_result->>'error' = 'host_only', format('participant set media: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_set_playback(%L, true, 5000, 1)', v_room));
  assert v_result->>'error' = 'host_only', format('participant set playback: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_remove_participant(%L, %L)', v_room, v_host_pid));
  assert v_result->>'error' = 'host_only', format('participant removed the host: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_transfer_host(%L, %L)', v_room,
    (select participant_id from public.orvix_watch_room_participants
     where room_id = v_room and user_id = pg_temp.uid(2))));
  assert v_result->>'error' = 'host_only', format('participant took the host role: %s', v_result);
  v_result := pg_temp.as_user(2, format('select public.watch_party_close(%L)', v_room));
  assert v_result->>'error' = 'host_only', format('participant closed the room: %s', v_result);

  assert (select host_user_id from public.orvix_watch_rooms where id = v_room) = pg_temp.uid(1),
    'the host changed';
  assert (select state_seq from public.orvix_watch_rooms where id = v_room) = 0,
    'a refused action changed the playback state';
  -- The host cannot remove or hand over to themselves.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_remove_participant(%L, %L)', v_room, v_host_pid));
  assert v_result->>'error' = 'invalid_participant', format('host removed self: %s', v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- Media and playback state
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_topic text := current_setting('test.topic');
  v_result jsonb;
  v_now_ms bigint;
  v_seq bigint;
  v_states bigint;
begin
  -- Playback needs a title first.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, 0, 1)', v_room));
  assert v_result->>'error' = 'no_media', format('playback without media: %s', v_result);

  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_set_media(%L, 'show', 'tt0000001')$q$, v_room));
  assert v_result->>'error' = 'invalid_media', format('bad kind: %s', v_result);
  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_set_media(%L, 'movie', 'https://example.test/x')$q$, v_room));
  assert v_result->>'error' = 'invalid_media', format('url as id: %s', v_result);
  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_set_media(%L, 'series', 'tt0903747', -1, 1)$q$, v_room));
  assert v_result->>'error' = 'invalid_media', format('negative season: %s', v_result);

  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_set_media(%L, 'series', 'tt0903747', 1, 2, 'Breaking Bad', '2008')$q$,
    v_room));
  assert (v_result->>'ok')::boolean, format('set media: %s', v_result);
  assert v_result->'room'->'media'->>'key' = 'series:tt0903747:1:2', 'media key';
  assert v_result->'room'->'media'->>'title' = 'Breaking Bad', 'media title';
  assert (v_result->'room'->'playback'->>'seq')::bigint = 1, 'set media did not advance the state';
  assert pg_temp.broadcasts(v_topic, 'state') = 1, 'set media was not announced';

  -- Ready means "playing this title".
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_sync(%L, null, true, false, 'series:tt0903747:1:3', 3480000)$q$, v_room));
  assert (v_result->>'media_mismatch')::boolean, format('wrong episode not flagged: %s', v_result);
  assert not (v_result->'roster'->'participants'->1->>'ready')::boolean, 'ready with the wrong episode';
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_sync(%L, null, true, false, 'series:tt0903747:1:2', 3480000)$q$, v_room));
  assert v_result->'media_mismatch' is null, 'matching episode flagged';
  assert (v_result->'roster'->'participants'->1->>'ready')::boolean, 'not ready with the right episode';
  assert (v_result->'roster'->'participants'->1->>'duration_ms')::bigint = 3480000, 'duration not stored';

  -- Play.
  v_now_ms := public.orvix_watch_ms(clock_timestamp());
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, 60000, 10, %s)', v_room, v_now_ms - 120));
  assert (v_result->>'ok')::boolean and v_result->'stale' is null, format('play: %s', v_result);
  assert (v_result->'room'->'playback'->>'seq')::bigint = 2, 'play did not get the next state number';
  assert (v_result->'room'->'playback'->>'playing')::boolean, 'room is not playing';
  assert (v_result->'room'->'playback'->>'position_ms')::bigint = 60000, 'position';
  assert (v_result->'room'->'playback'->>'at_ms')::bigint = v_now_ms - 120,
    'the host''s observation time was not kept';
  assert pg_temp.broadcasts(v_topic, 'state') = 2, 'play was not announced';
  assert (v_result->>'command_seq')::bigint = 10, 'the accepted command number is not reported back';
  assert (select payload->'playback'->>'seq' from realtime.messages
          where topic = v_topic and event = 'state' order by id desc limit 1) = '2',
    'the broadcast does not carry the state number';

  -- The same command again (a retry) and an older one (delayed in the
  -- network) change nothing and are not announced.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, false, 0, 10)', v_room));
  assert (v_result->>'stale')::boolean, format('duplicate command accepted: %s', v_result);
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, false, 0, 9)', v_room));
  assert (v_result->>'stale')::boolean, format('delayed command accepted: %s', v_result);
  select state_seq into v_seq from public.orvix_watch_rooms where id = v_room;
  assert v_seq = 2, 'a stale command advanced the state';
  assert (select is_playing from public.orvix_watch_rooms where id = v_room), 'a stale command paused the room';
  assert pg_temp.broadcasts(v_topic, 'state') = 2, 'a stale command was announced';

  -- A new command that describes the current state is not announced either.
  v_now_ms := public.orvix_watch_ms(clock_timestamp());
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, %s, 11, %s)', v_room,
    60000 + (v_now_ms - (v_result->'room'->'playback'->>'at_ms')::bigint) + 40, v_now_ms));
  assert (v_result->>'unchanged')::boolean, format('equal state re-announced: %s', v_result);
  assert pg_temp.broadcasts(v_topic, 'state') = 2, 'an unchanged state was announced';

  -- Seek while playing, then pause.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, 900000, 12)', v_room));
  assert (v_result->'room'->'playback'->>'seq')::bigint = 3, 'seek state number';
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, false, 905000, 13)', v_room));
  assert (v_result->'room'->'playback'->>'seq')::bigint = 4
     and not (v_result->'room'->'playback'->>'playing')::boolean, 'pause';
  select count(*) into v_states from realtime.messages where topic = v_topic and event = 'state';
  assert v_states = 4, format('expected four announced states, got %s', v_states);
  assert (select array_agg((payload->'playback'->>'seq')::int order by id) from realtime.messages
          where topic = v_topic and event = 'state') = array[1, 2, 3, 4],
    'announced states are not in order';

  -- Out-of-range input is clamped, never stored as given.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, false, -500, 14, %s)', v_room,
    public.orvix_watch_ms(clock_timestamp()) + 3600000));
  assert (v_result->'room'->'playback'->>'position_ms')::bigint = 0, 'negative position stored';
  assert (v_result->'room'->'playback'->>'at_ms')::bigint
         <= public.orvix_watch_ms(clock_timestamp()), 'a future observation time was stored';
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, 999999999999, 15, 1000)', v_room));
  assert (v_result->'room'->'playback'->>'position_ms')::bigint = 86400000, 'position not capped';
  assert (v_result->'room'->'playback'->>'at_ms')::bigint
         >= public.orvix_watch_ms(clock_timestamp()) - 6000, 'an ancient observation time was stored';
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, null, 0, 16)', v_room));
  assert v_result->>'error' = 'invalid_state', format('null state: %s', v_result);

  -- A new title restarts paused at zero and clears readiness.
  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_set_media(%L, 'movie', 'tt1375666', null, null, 'Inception', '2010')$q$,
    v_room));
  assert not (v_result->'room'->'playback'->>'playing')::boolean
     and (v_result->'room'->'playback'->>'position_ms')::bigint = 0, 'new title did not reset playback';
  assert v_result->'room'->'media'->>'key' = 'movie:tt1375666:-:-', 'movie key';
  assert not (v_result->'roster'->'participants'->1->>'ready')::boolean, 'ready survived a title change';
end;
$$;

-- Playback commands are rate limited.
do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_result jsonb;
  v_command integer;
  v_limited boolean := false;
begin
  delete from public.orvix_watch_rate_limits where action = 'playback';
  for v_command in 1..31 loop
    v_result := pg_temp.as_user(1, format(
      'select public.watch_party_set_playback(%L, %L, %s, %s)', v_room,
      v_command % 2 = 0, v_command * 10000, 100 + v_command));
    if v_result->>'error' = 'rate_limited' then
      v_limited := true;
      assert v_command = 31, format('limited too early, at command %s', v_command);
    end if;
  end loop;
  assert v_limited, 'thirty-one playback commands in a row were all accepted';
  delete from public.orvix_watch_rate_limits where action = 'playback';
end;
$$;

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_topic text := current_setting('test.topic');
  v_client uuid := gen_random_uuid();
  v_result jsonb;
  v_again jsonb;
  v_message integer;
begin
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, '  hello' || chr(9) || chr(10) || 'there  ', %L)$q$,
    v_room, v_client));
  assert (v_result->>'ok')::boolean, format('chat: %s', v_result);
  assert (v_result->'message'->>'seq')::bigint = 1, 'first message number';
  assert v_result->'message'->>'body' = 'hello there', format('body not cleaned: %s', v_result);
  assert v_result->'message'->>'name' = 'Bobby', 'sender name';
  assert v_result::text not like '%' || pg_temp.uid(2)::text || '%', 'chat leaked the account id';
  assert pg_temp.broadcasts(v_topic, 'chat') = 1, 'message was not announced';

  -- A retried send returns the first copy; nothing is stored or announced twice.
  v_again := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, 'hello there', %L)$q$, v_room, v_client));
  assert v_again->'message'->>'seq' = '1', format('retry created a new message: %s', v_again);
  assert (select count(*) from public.orvix_watch_room_messages where room_id = v_room) = 1,
    'retry stored a duplicate';
  assert pg_temp.broadcasts(v_topic, 'chat') = 1, 'retry was announced again';

  -- Validation.
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, '   ' || chr(10) || ' ', gen_random_uuid())$q$, v_room));
  assert v_result->>'error' = 'invalid_message', format('blank message: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, repeat('x', 501), gen_random_uuid())$q$, v_room));
  assert v_result->>'error' = 'invalid_message', format('long message: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, 'no id', null)$q$, v_room));
  assert v_result->>'error' = 'invalid_message', format('missing client id: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, repeat('y', 500), gen_random_uuid())$q$, v_room));
  assert (v_result->>'ok')::boolean, format('500 characters refused: %s', v_result);
  -- Direction overrides are removed; Sinhala joiners are kept.
  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_send_message(%L, U&'a\202Eb \0DC1\0DCA\200D\0DBB\0DD3', gen_random_uuid())$q$,
    v_room));
  assert v_result->'message'->>'body' = U&'ab \0DC1\0DCA\200D\0DBB\0DD3',
    format('text cleanup changed the message: %s', v_result);

  -- Messages are numbered in order.
  assert (select array_agg(seq order by seq) from public.orvix_watch_room_messages where room_id = v_room)
         = array[1, 2, 3]::bigint[], 'message numbers are not consecutive';

  -- Rate limit: eight per ten seconds for one sender.
  delete from public.orvix_watch_rate_limits where action = 'chat';
  for v_message in 1..8 loop
    v_result := pg_temp.as_user(2, format(
      $q$select public.watch_party_send_message(%L, 'spam %s', gen_random_uuid())$q$, v_room, v_message));
    assert (v_result->>'ok')::boolean, format('message %s refused: %s', v_message, v_result);
  end loop;
  v_result := pg_temp.as_user(2, format(
    $q$select public.watch_party_send_message(%L, 'spam 9', gen_random_uuid())$q$, v_room));
  assert v_result->>'error' = 'rate_limited', format('ninth message: %s', v_result);
  -- Another member is not affected.
  v_result := pg_temp.as_user(1, format(
    $q$select public.watch_party_send_message(%L, 'calm down', gen_random_uuid())$q$, v_room));
  assert (v_result->>'ok')::boolean, 'one sender''s limit hit another member';

  -- Retention: only the latest 200 messages are kept, and a catch-up
  -- returns at most the latest 50.
  for v_message in 1..230 loop
    delete from public.orvix_watch_rate_limits where action = 'chat';
    v_result := pg_temp.as_user(1, format(
      $q$select public.watch_party_send_message(%L, 'line %s', gen_random_uuid())$q$, v_room, v_message));
    assert (v_result->>'ok')::boolean, format('bulk message %s: %s', v_message, v_result);
  end loop;
  assert (select count(*) from public.orvix_watch_room_messages where room_id = v_room) = 200,
    format('history holds %s messages',
      (select count(*) from public.orvix_watch_room_messages where room_id = v_room));
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format('select public.watch_party_sync(%L, 0)', v_room));
  assert jsonb_array_length(v_result->'messages') = 50, 'catch-up is not capped at fifty';
  assert (v_result->'messages'->49->>'seq')::bigint = (v_result->'room'->>'chat_seq')::bigint,
    'catch-up does not end at the newest message';
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format('select public.watch_party_sync(%L, %s)', v_room,
    (v_result->'room'->>'chat_seq')::bigint - 2));
  assert jsonb_array_length(v_result->'messages') = 2, 'catch-up after a known message';
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format('select public.watch_party_sync(%L)', v_room));
  assert jsonb_array_length(v_result->'messages') = 0, 'a plain heartbeat returned chat history';
  delete from public.orvix_watch_rate_limits where action = 'chat';
end;
$$;

-- A plain heartbeat cannot be spammed.
do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_result jsonb;
begin
  perform pg_temp.tick();
  v_result := pg_temp.as_user(2, format('select public.watch_party_sync(%L)', v_room));
  assert (v_result->>'ok')::boolean, format('heartbeat: %s', v_result);
  assert (v_result->>'server_time_ms')::bigint > 0, 'heartbeat has no server time';
  v_result := pg_temp.as_user(2, format('select public.watch_party_sync(%L)', v_room));
  assert v_result->>'error' = 'rate_limited', format('immediate second heartbeat: %s', v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- The ten-person limit
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_code text := current_setting('test.code');
  v_result jsonb;
  v_user integer;
begin
  for v_user in 3..10 loop
    v_result := pg_temp.as_user(v_user, format(
      $q$select public.watch_party_join(%L, 'User %s')$q$, v_code, v_user));
    assert (v_result->>'ok')::boolean, format('user %s could not join: %s', v_user, v_result);
  end loop;
  assert jsonb_array_length(v_result->'roster'->'participants') = 10, 'room does not hold ten';

  v_result := pg_temp.as_user(11, format($q$select public.watch_party_join(%L, 'Eleven')$q$, v_code));
  assert v_result->>'error' = 'room_full', format('an eleventh person joined: %s', v_result);
  assert (select count(*) from public.orvix_watch_room_participants
          where room_id = v_room and left_at is null) = 10, 'room exceeds ten';

  -- A member already inside is not refused by the limit.
  v_result := pg_temp.as_user(5, format($q$select public.watch_party_join(%L, 'User 5')$q$, v_code));
  assert (v_result->>'ok')::boolean, format('a member was locked out of a full room: %s', v_result);

  -- A free place can be taken.
  v_result := pg_temp.as_user(10, format('select public.watch_party_leave(%L)', v_room));
  v_result := pg_temp.as_user(11, format($q$select public.watch_party_join(%L, 'Eleven')$q$, v_code));
  assert (v_result->>'ok')::boolean, format('free place refused: %s', v_result);

  -- Someone who silently dropped stops holding a place.
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp() - interval '3 minutes'
  where room_id = v_room and user_id = pg_temp.uid(9);
  v_result := pg_temp.as_user(12, format($q$select public.watch_party_join(%L, 'Twelve')$q$, v_code));
  assert (v_result->>'ok')::boolean, format('a dropped member still blocked the room: %s', v_result);
  assert (select left_at is not null from public.orvix_watch_room_participants
          where room_id = v_room and user_id = pg_temp.uid(9)), 'the dropped member kept their place';
  assert (select count(*) from public.orvix_watch_room_participants
          where room_id = v_room and left_at is null) = 10, 'room is not back at ten';
end;
$$;

-- ---------------------------------------------------------------------------
-- Removing a participant
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_code text := current_setting('test.code');
  v_old_topic text := current_setting('test.topic');
  v_new_topic text;
  v_target uuid;
  v_result jsonb;
  v_count bigint;
begin
  select participant_id into v_target from public.orvix_watch_room_participants
  where room_id = v_room and user_id = pg_temp.uid(3);
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_remove_participant(%L, %L)', v_room, v_target));
  assert (v_result->>'ok')::boolean, format('remove: %s', v_result);
  assert not exists (
    select 1 from jsonb_array_elements(v_result->'roster'->'participants') p
    where p->>'id' = v_target::text), 'removed participant is still in the roster';
  v_new_topic := v_result->'room'->>'topic';
  assert v_new_topic <> v_old_topic, 'the topic was not replaced after a removal';
  assert pg_temp.broadcasts(v_old_topic, 'rekey') = 1, 'members were not told to resubscribe';
  perform set_config('test.topic', v_new_topic, false);

  -- The removed user is out: no data, no listening, no way back.
  v_result := pg_temp.as_user(3, format('select public.watch_party_sync(%L)', v_room));
  assert v_result->>'error' = 'removed', format('removed user synced: %s', v_result);
  assert v_result->'room' is null, 'removed user received the new topic';
  v_result := pg_temp.as_user(3, format($q$select public.watch_party_join(%L, 'Back')$q$, v_code));
  assert v_result->>'error' = 'removed', format('removed user rejoined: %s', v_result);
  v_result := pg_temp.as_user(3, format(
    $q$select public.watch_party_send_message(%L, 'still here', gen_random_uuid())$q$, v_room));
  assert v_result->>'error' = 'not_member', format('removed user chatted: %s', v_result);

  perform set_config('request.jwt.claim.sub', pg_temp.uid(3)::text, true);
  set local role authenticated;
  assert not public.orvix_watch_party_can_listen(v_old_topic), 'removed user may listen to the old topic';
  assert not public.orvix_watch_party_can_listen(v_new_topic), 'removed user may listen to the new topic';
  perform set_config('realtime.topic', v_new_topic, true);
  select count(*) into v_count from realtime.messages;
  assert v_count = 0, 'removed user receives the new topic';
  reset role;

  -- Remaining members follow the room to the new topic; the old one is dead.
  perform set_config('request.jwt.claim.sub', pg_temp.uid(2)::text, true);
  set local role authenticated;
  assert public.orvix_watch_party_can_listen(v_new_topic), 'member refused on the new topic';
  assert not public.orvix_watch_party_can_listen(v_old_topic), 'the old topic is still valid';
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('realtime.topic', '', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Host disconnect, hand-over and leaving
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_topic text := current_setting('test.topic');
  v_code text := current_setting('test.code');
  v_result jsonb;
  v_roster_before bigint;
  v_pid_before uuid;
  v_playing boolean;
begin
  delete from public.orvix_watch_rate_limits where action = 'playback';
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, true, 120000, 500)', v_room));
  assert (v_result->>'ok')::boolean, format('play before disconnect: %s', v_result);

  -- A short interruption changes nothing.
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp() - interval '30 seconds'
  where room_id = v_room and user_id = pg_temp.uid(1);
  v_result := pg_temp.sync(2, v_room);
  assert (select host_user_id from public.orvix_watch_rooms where id = v_room) = pg_temp.uid(1),
    'a 30 second interruption cost the host their role';

  -- The host is shown as offline before the role moves.
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp() - interval '50 seconds'
  where room_id = v_room and user_id = pg_temp.uid(1);
  v_result := pg_temp.sync(2, v_room);
  assert not (v_result->'roster'->'participants'->0->>'online')::boolean, 'silent host shown online';
  assert (v_result->'roster'->'participants'->1->>'online')::boolean, 'active member shown offline';

  -- After a minute of silence the longest-present online member takes over.
  -- Playback is left running.
  select roster_seq into v_roster_before from public.orvix_watch_rooms where id = v_room;
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp() - interval '70 seconds'
  where room_id = v_room and user_id = pg_temp.uid(1);
  v_result := pg_temp.sync(4, v_room);
  assert (select host_user_id from public.orvix_watch_rooms where id = v_room) = pg_temp.uid(2),
    format('host did not move to the longest-present member: %s', v_result->'roster');
  assert (v_result->'roster'->>'seq')::bigint = v_roster_before + 1, 'hand-over did not bump the roster';
  select is_playing into v_playing from public.orvix_watch_rooms where id = v_room;
  assert v_playing, 'losing the host stopped playback';
  assert (select payload->>'host' from realtime.messages
          where topic = v_topic and event = 'roster' order by id desc limit 1)
         = (select participant_id::text from public.orvix_watch_room_participants
            where room_id = v_room and user_id = pg_temp.uid(2)),
    'the new host was not announced';

  -- The old host can no longer control playback; the new one can.
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_set_playback(%L, false, 0, 501)', v_room));
  assert v_result->>'error' = 'host_only', format('former host still controls: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_set_playback(%L, false, 125000, 1)', v_room));
  assert (v_result->>'ok')::boolean and v_result->'stale' is null,
    format('new host cannot control: %s', v_result);

  -- The former host comes back as a participant, keeping their place.
  select participant_id into v_pid_before from public.orvix_watch_room_participants
  where room_id = v_room and user_id = pg_temp.uid(1);
  v_result := pg_temp.sync(1, v_room);
  assert (v_result->>'ok')::boolean and v_result->>'you' = v_pid_before::text,
    format('returning host lost their place: %s', v_result);
  assert v_result->'roster'->>'host' <> v_pid_before::text, 'returning host took the role back';

  -- The host hands the room back deliberately.
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_transfer_host(%L, %L)', v_room, v_pid_before));
  assert v_result->'roster'->>'host' = v_pid_before::text, format('transfer: %s', v_result);
  v_result := pg_temp.as_user(2, format(
    'select public.watch_party_transfer_host(%L, %L)', v_room, gen_random_uuid()));
  assert v_result->>'error' = 'host_only', 'former host transferred again';
  v_result := pg_temp.as_user(1, format(
    'select public.watch_party_transfer_host(%L, %L)', v_room, gen_random_uuid()));
  assert v_result->>'error' = 'invalid_participant', 'transfer to a stranger';

  -- A host with nobody else online keeps the room.
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp() - interval '80 seconds'
  where room_id = v_room;
  perform public.orvix_watch_maintain(v_room);
  assert (select host_user_id from public.orvix_watch_rooms where id = v_room) = pg_temp.uid(1),
    'the room changed host with nobody online';
  update public.orvix_watch_room_participants set last_seen_at = clock_timestamp()
  where room_id = v_room and left_at is null;

  -- A host who leaves hands over at once; leaving and returning keeps the
  -- participant id.
  v_result := pg_temp.as_user(1, format('select public.watch_party_leave(%L)', v_room));
  assert (select host_user_id from public.orvix_watch_rooms where id = v_room) = pg_temp.uid(2),
    'a leaving host did not hand over';
  v_result := pg_temp.as_user(1, format('select public.watch_party_sync(%L)', v_room));
  assert v_result->>'error' = 'not_member', format('left member synced: %s', v_result);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(1)::text, true);
  set local role authenticated;
  assert not public.orvix_watch_party_can_listen(v_topic), 'a member who left may still listen';
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  v_result := pg_temp.as_user(1, format($q$select public.watch_party_join(%L, 'Alice')$q$, v_code));
  assert v_result->>'you' = v_pid_before::text, 'returning member got a new participant id';
  assert v_result->'roster'->>'host' <> v_pid_before::text, 'returning member became host';
end;
$$;

-- One room per account: joining or creating another room leaves the first.
do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_other jsonb;
  v_result jsonb;
begin
  v_other := pg_temp.as_user(14, $q$select public.watch_party_create('Solo')$q$);
  assert (v_other->>'ok')::boolean, format('second room: %s', v_other);
  v_result := pg_temp.as_user(4, format($q$select public.watch_party_join(%L, 'Four')$q$,
    v_other->'room'->>'code'));
  assert (v_result->>'ok')::boolean, format('join second room: %s', v_result);
  assert (select left_at is not null from public.orvix_watch_room_participants
          where room_id = v_room and user_id = pg_temp.uid(4)),
    'a user is active in two rooms';
  assert (select count(*) from public.orvix_watch_room_participants
          where user_id = pg_temp.uid(4) and left_at is null) = 1, 'active memberships';

  -- The last person leaving deletes the room and everything in it.
  v_result := pg_temp.as_user(4, format('select public.watch_party_leave(%L)',
    v_other->'room'->>'id'));
  v_result := pg_temp.as_user(14, format(
    $q$select public.watch_party_send_message(%L, 'alone', gen_random_uuid())$q$, v_other->'room'->>'id'));
  assert (v_result->>'ok')::boolean, 'chat in second room';
  v_result := pg_temp.as_user(14, format('select public.watch_party_leave(%L)',
    v_other->'room'->>'id'));
  assert not exists (select 1 from public.orvix_watch_rooms where id = (v_other->'room'->>'id')::uuid),
    'an empty room was kept';
  assert not exists (select 1 from public.orvix_watch_room_messages
                     where room_id = (v_other->'room'->>'id')::uuid), 'messages outlived their room';
  assert not exists (select 1 from public.orvix_watch_room_participants
                     where room_id = (v_other->'room'->>'id')::uuid), 'participants outlived their room';
end;
$$;

-- ---------------------------------------------------------------------------
-- Closing, expiry and cleanup
-- ---------------------------------------------------------------------------

do $$
declare
  v_room uuid := current_setting('test.room')::uuid;
  v_code text := current_setting('test.code');
  v_result jsonb;
  v_expired jsonb;
  v_idle jsonb;
  v_closing jsonb;
  v_deleted integer;
begin
  -- The host closes a room for everyone.
  delete from public.orvix_watch_rate_limits where user_id = pg_temp.uid(13);
  v_closing := pg_temp.as_user(13, $q$select public.watch_party_create('Closer')$q$);
  v_result := pg_temp.as_user(14, format($q$select public.watch_party_join(%L, 'Guest')$q$,
    v_closing->'room'->>'code'));
  assert (v_result->>'ok')::boolean, format('join closing room: %s', v_result);
  v_result := pg_temp.as_user(13, format('select public.watch_party_close(%L)', v_closing->'room'->>'id'));
  assert (v_result->>'ok')::boolean, format('close: %s', v_result);
  assert pg_temp.broadcasts(v_closing->'room'->>'topic', 'closed') = 1, 'closing was not announced';
  v_result := pg_temp.as_user(14, format('select public.watch_party_sync(%L)', v_closing->'room'->>'id'));
  assert v_result->>'error' = 'room_closed', format('sync after close: %s', v_result);
  v_result := pg_temp.as_user(14, format($q$select public.watch_party_join(%L, 'Guest')$q$,
    v_closing->'room'->>'code'));
  assert v_result->>'error' = 'not_found', format('join after close: %s', v_result);

  -- A room past its lifetime, and one idle for half an hour, are closed to
  -- every call before cleanup removes them.
  v_expired := pg_temp.as_user(13, $q$select public.watch_party_create('Old')$q$);
  v_idle := pg_temp.as_user(14, $q$select public.watch_party_create('Idle')$q$);
  update public.orvix_watch_rooms set expires_at = clock_timestamp() - interval '1 second'
  where id = (v_expired->'room'->>'id')::uuid;
  v_result := pg_temp.as_user(13, format('select public.watch_party_sync(%L)', v_expired->'room'->>'id'));
  assert v_result->>'error' = 'room_closed', format('expired room synced: %s', v_result);
  v_result := pg_temp.as_user(14, format($q$select public.watch_party_join(%L, 'Late')$q$,
    v_expired->'room'->>'code'));
  assert v_result->>'error' = 'not_found', format('expired room joined: %s', v_result);
  v_result := pg_temp.as_user(13, format(
    $q$select public.watch_party_send_message(%L, 'late', gen_random_uuid())$q$, v_expired->'room'->>'id'));
  assert v_result->>'error' = 'room_closed', format('expired room chat: %s', v_result);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(13)::text, true);
  set local role authenticated;
  assert not public.orvix_watch_party_can_listen(v_expired->'room'->>'topic'),
    'an expired room can still be listened to';
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);

  update public.orvix_watch_rooms set last_activity_at = clock_timestamp() - interval '31 minutes'
  where id = (v_idle->'room'->>'id')::uuid;
  v_result := pg_temp.as_user(14, format('select public.watch_party_sync(%L)', v_idle->'room'->>'id'));
  assert v_result->>'error' = 'room_closed', format('idle room synced: %s', v_result);

  insert into public.orvix_watch_rate_limits (user_id, action, window_start, hits)
  values (pg_temp.uid(12), 'stale', clock_timestamp() - interval '2 days', 3);

  set local role service_role;
  v_deleted := public.orvix_watch_party_cleanup(500);
  reset role;
  assert v_deleted = 2, format('cleanup removed %s rooms, expected 2', v_deleted);
  assert not exists (select 1 from public.orvix_watch_rooms
                     where id in ((v_expired->'room'->>'id')::uuid, (v_idle->'room'->>'id')::uuid)),
    'cleanup kept a dead room';
  assert exists (select 1 from public.orvix_watch_rooms where id = v_room), 'cleanup removed a live room';
  assert not exists (select 1 from public.orvix_watch_rate_limits where action = 'stale'),
    'cleanup kept an old rate-limit row';

  -- Creating a room also sweeps dead rooms, so storage stays bounded
  -- without a scheduled job.
  update public.orvix_watch_rooms set last_activity_at = clock_timestamp() - interval '31 minutes'
  where id = v_room;
  delete from public.orvix_watch_rate_limits where user_id = pg_temp.uid(13);
  v_result := pg_temp.as_user(13, $q$select public.watch_party_create('Sweeper')$q$);
  assert (v_result->>'ok')::boolean, format('create: %s', v_result);
  assert not exists (select 1 from public.orvix_watch_rooms where id = v_room),
    'creating a room did not sweep a dead one';
  assert not exists (select 1 from public.orvix_watch_room_messages where room_id = v_room),
    'chat history outlived its room';

  -- Room creation is rate limited (six an hour).
  delete from public.orvix_watch_rate_limits where user_id = pg_temp.uid(12);
  for v_deleted in 1..6 loop
    v_result := pg_temp.as_user(12, $q$select public.watch_party_create('Many')$q$);
    assert (v_result->>'ok')::boolean, format('create %s: %s', v_deleted, v_result);
  end loop;
  v_result := pg_temp.as_user(12, $q$select public.watch_party_create('Many')$q$);
  assert v_result->>'error' = 'rate_limited', format('seventh room: %s', v_result);
  -- Each new room replaced the previous one.
  assert (select count(*) from public.orvix_watch_rooms where host_user_id = pg_temp.uid(12)) = 1,
    'one account holds several rooms';
end;
$$;

-- Deleting an account removes its memberships, and a room it was hosting.
do $$
declare
  v_hosted jsonb;
  v_result jsonb;
begin
  delete from public.orvix_watch_rate_limits where user_id in (pg_temp.uid(13), pg_temp.uid(14));
  v_hosted := pg_temp.as_user(13, $q$select public.watch_party_create('Leaving')$q$);
  v_result := pg_temp.as_user(14, format($q$select public.watch_party_join(%L, 'Stays')$q$,
    v_hosted->'room'->>'code'));
  assert (v_result->>'ok')::boolean, format('join: %s', v_result);

  delete from auth.users where id = pg_temp.uid(14);
  assert not exists (select 1 from public.orvix_watch_room_participants where user_id = pg_temp.uid(14)),
    'a deleted account still has a membership';
  assert not exists (select 1 from public.orvix_watch_rate_limits where user_id = pg_temp.uid(14)),
    'a deleted account still has rate-limit rows';
  delete from auth.users where id = pg_temp.uid(13);
  assert not exists (select 1 from public.orvix_watch_rooms where id = (v_hosted->'room'->>'id')::uuid),
    'a room outlived its host''s account';
end;
$$;

select 'watch party checks passed' as result;
