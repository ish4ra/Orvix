-- Read-only checks that a project is ready for Watch Party testing.
-- Changes nothing. Any failed check stops with an error that names it.
--
--   psql "$ORVIX_STAGING_DB_URL" --set ON_ERROR_STOP=1 --file supabase/staging/verify.sql
--
-- apply.sh runs this after the migrations.

do $$
declare
  v_failures text[] := '{}';
  v_name text;
  v_count integer;
  v_tables constant text[] := array[
    'orvix_watch_rooms',
    'orvix_watch_room_participants',
    'orvix_watch_room_messages',
    'orvix_watch_rate_limits'
  ];
  v_client_functions constant text[] := array[
    'watch_party_create', 'watch_party_join', 'watch_party_leave',
    'watch_party_sync', 'watch_party_set_media', 'watch_party_set_playback',
    'watch_party_send_message', 'watch_party_remove_participant',
    'watch_party_transfer_host', 'watch_party_close',
    'orvix_watch_party_can_listen'
  ];
  v_function record;
begin
  -- Tables: present, row level security on, no policies, no client access.
  foreach v_name in array v_tables loop
    if to_regclass('public.' || v_name) is null then
      v_failures := v_failures || format('table %s is missing', v_name);
      continue;
    end if;
    if not (select relrowsecurity from pg_class
            where oid = to_regclass('public.' || v_name)) then
      v_failures := v_failures || format('table %s has row level security off', v_name);
    end if;
    select count(*) into v_count from pg_policies
      where schemaname = 'public' and tablename = v_name;
    if v_count <> 0 then
      v_failures := v_failures || format('table %s has %s policies, expected none', v_name, v_count);
    end if;
    if has_table_privilege('anon', 'public.' || v_name, 'select, insert, update, delete')
       or has_table_privilege('authenticated', 'public.' || v_name, 'select, insert, update, delete') then
      v_failures := v_failures || format('table %s is reachable by app clients', v_name);
    end if;
  end loop;

  -- Functions: every Watch Party function is closed to signed-out callers;
  -- signed-in callers get exactly the client functions.
  foreach v_name in array v_client_functions loop
    if not exists (select 1 from pg_proc
                   where pronamespace = 'public'::regnamespace and proname = v_name) then
      v_failures := v_failures || format('function %s is missing', v_name);
    end if;
  end loop;

  for v_function in
    select p.oid, p.proname, p.prosecdef, p.proconfig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'watch\_party\_%' or p.proname like 'orvix\_watch\_%')
  loop
    if has_function_privilege('anon', v_function.oid, 'execute') then
      v_failures := v_failures || format('function %s can be run signed out', v_function.proname);
    end if;
    if has_function_privilege('authenticated', v_function.oid, 'execute')
       <> (v_function.proname = any (v_client_functions)) then
      v_failures := v_failures || format('function %s has the wrong access for signed-in users', v_function.proname);
    end if;
    if v_function.prosecdef
       and not coalesce(v_function.proconfig @> array['search_path=""'], false)
       and not coalesce(v_function.proconfig @> array['search_path='], false) then
      v_failures := v_failures || format('function %s does not pin an empty search_path', v_function.proname);
    end if;
  end loop;

  -- Realtime: members may listen, nobody may send.
  select count(*) into v_count from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'Watch party members receive room broadcasts'
      and cmd = 'SELECT';
  if v_count <> 1 then
    v_failures := v_failures || 'the Realtime listen policy is missing'::text;
  end if;
  select count(*) into v_count from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and cmd in ('INSERT', 'ALL')
      and roles && array['anon', 'authenticated', 'public']::name[];
  if v_count <> 0 then
    v_failures := v_failures || 'app clients are allowed to send Realtime messages'::text;
  end if;

  if array_length(v_failures, 1) > 0 then
    raise exception E'Watch Party checks failed:\n - %', array_to_string(v_failures, E'\n - ');
  end if;
  raise notice 'Watch Party checks passed.';
end
$$;
