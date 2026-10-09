-- Checks the client-facing security boundary of the Orvix schema. Run with
-- run.sh. Uses placeholder users only.
\set ON_ERROR_STOP on

select set_config('test.a', '00000000-0000-4000-8000-00000000000a', false);
select set_config('test.b', '00000000-0000-4000-8000-00000000000b', false);

insert into auth.users (id, email) values
  (current_setting('test.a')::uuid, 'a@example.test'),
  (current_setting('test.b')::uuid, 'b@example.test');

create function pg_temp.sign_in(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', current_setting('test.' || p_user), true) $$;

-- Every public table has row level security on.
do $$
declare
  v_table text;
begin
  for v_table in
    select c.relname from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r', 'p')
      and not c.relrowsecurity
  loop
    raise exception 'public.% has row level security off', v_table;
  end loop;
end;
$$;

-- Direct table privileges of the client roles. Anything not listed must be
-- absent, including TRUNCATE (which row level security does not cover).
do $$
declare
  v_table text;
  v_role text;
  v_privilege text;
  v_expected text[];
  v_has boolean;
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    for v_table in
      select c.relname from pg_class c
      where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
    loop
      v_expected := case
        when v_table = 'supporters' then array['SELECT']
        when v_table = 'orvix_user_state' and v_role = 'authenticated'
          then array['SELECT', 'INSERT', 'UPDATE', 'DELETE']
        else array[]::text[]
      end;
      foreach v_privilege in array array[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
      ] loop
        v_has := has_table_privilege(v_role, format('public.%I', v_table), v_privilege);
        if v_has <> (v_privilege = any (v_expected)) then
          raise exception '% % on public.% should be %',
            v_role, v_privilege, v_table, v_privilege = any (v_expected);
        end if;
      end loop;
    end loop;
  end loop;
end;
$$;

-- No client role can use a public sequence.
do $$
declare
  v_sequence text;
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    for v_sequence in
      select c.relname from pg_class c
      where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
    loop
      if has_sequence_privilege(v_role, format('public.%I', v_sequence), 'USAGE, SELECT, UPDATE') then
        raise exception '% can use sequence public.%', v_role, v_sequence;
      end if;
    end loop;
  end loop;
end;
$$;

-- Every SECURITY DEFINER function pins its search_path.
do $$
declare
  v_function text;
begin
  for v_function in
    select p.oid::regprocedure::text from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, array[]::text[])) c
        where c like 'search_path=%')
  loop
    raise exception 'SECURITY DEFINER function % has a mutable search_path', v_function;
  end loop;
end;
$$;

-- Callable functions per client role, computed over every public function
-- (trigger functions cannot be called through the API). A new function that
-- keeps Supabase's default EXECUTE grant fails here.
do $$
declare
  v_role text;
  v_actual text[];
  v_expected text[];
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    select coalesce(array_agg(p.oid::regprocedure::text
                              order by p.oid::regprocedure::text collate "C"), array[]::text[])
      into v_actual
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prorettype <> 'trigger'::regtype
      and has_function_privilege(v_role, p.oid, 'execute');

    v_expected := array[
      'cancel_tv_login_session(uuid,uuid)',
      'list_public_supporters()',
      'poll_tv_login_session(uuid,uuid)',
      'start_tv_login_session(uuid,text)'
    ];
    if v_role = 'authenticated' then
      v_expected := array['approve_tv_login_session(text)'] || v_expected;
    end if;
    if v_actual <> v_expected then
      raise exception '% can execute %, expected %', v_role, v_actual, v_expected;
    end if;
  end loop;
end;
$$;

-- orvix_user_state: a signed-in user reaches only their own row.
set role service_role;
insert into public.orvix_user_state (user_id, watchlist)
values (current_setting('test.b')::uuid, '[{"id":"tt-b"}]');
reset role;

do $$
declare
  v_count bigint;
begin
  set local role authenticated;
  perform pg_temp.sign_in('a');

  insert into public.orvix_user_state (user_id) values (current_setting('test.a')::uuid);
  begin
    insert into public.orvix_user_state (user_id) values (current_setting('test.b')::uuid);
    raise exception 'user a inserted a row for user b';
  exception when insufficient_privilege then null;
  end;

  select count(*) into v_count from public.orvix_user_state;
  assert v_count = 1, 'user a can see another user''s state';

  update public.orvix_user_state set watchlist = '[]'
  where user_id = current_setting('test.b')::uuid;
  get diagnostics v_count = row_count;
  assert v_count = 0, 'user a updated user b''s state';

  begin
    update public.orvix_user_state set user_id = current_setting('test.b')::uuid
    where user_id = current_setting('test.a')::uuid;
    raise exception 'user a moved their row to user b';
  exception when insufficient_privilege then null;
  end;

  delete from public.orvix_user_state where user_id = current_setting('test.b')::uuid;
  get diagnostics v_count = row_count;
  assert v_count = 0, 'user a deleted user b''s state';
  reset role;

  assert (select watchlist from public.orvix_user_state
          where user_id = current_setting('test.b')::uuid) = '[{"id":"tt-b"}]'::jsonb,
    'user b''s state changed';
end;
$$;

-- Without a session, account state, TV logins and analytics are unreachable.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'orvix_user_state', 'orvix_tv_login_sessions', 'orvix_tv_login_approval_attempts',
    'orvix_admins', 'orvix_analytics_installations', 'orvix_analytics_sessions',
    'orvix_analytics_events', 'orvix_analytics_errors'
  ] loop
    set local role anon;
    begin
      execute format('select 1 from public.%I limit 1', v_table);
      raise exception 'anon can read public.%', v_table;
    exception when insufficient_privilege then null;
    end;
    reset role;
  end loop;
end;
$$;

-- Signed-in users cannot read or write analytics or TV login rows directly.
do $$
begin
  set local role authenticated;
  perform pg_temp.sign_in('a');
  begin
    insert into public.orvix_analytics_errors
      (installation_id, error_type, message, platform, app_version)
    values (gen_random_uuid(), 'x', 'x', 'x', 'x');
    raise exception 'a signed-in user wrote analytics directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.orvix_tv_login_sessions;
    raise exception 'a signed-in user read TV login sessions directly';
  exception when insufficient_privilege then null;
  end;
  reset role;
end;
$$;

-- Supporters: the public sees only visible rows and cannot write.
set role service_role;
insert into public.supporters (provider, provider_user_id, display_name, is_public, is_active) values
  ('github', 'public-active', 'Visible', true, true),
  ('github', 'private-active', 'Hidden', false, true),
  ('github', 'public-inactive', 'Former', true, false),
  ('kofi', 'default-visibility', 'Default', default, true);
reset role;

do $$
declare
  v_role text;
  v_names text[];
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    execute format('set local role %I', v_role);
    select array_agg(display_name order by display_name) into v_names from public.supporters;
    assert v_names = array['Visible'], format('%s sees supporters %s', v_role, v_names);

    begin
      insert into public.supporters (provider, provider_user_id, display_name)
      values ('github', 'forged', 'Forged');
      raise exception '% inserted a supporter', v_role;
    exception when insufficient_privilege then null;
    end;
    begin
      update public.supporters set display_name = 'Changed';
      raise exception '% updated supporters', v_role;
    exception when insufficient_privilege then null;
    end;
    begin
      delete from public.supporters;
      raise exception '% deleted supporters', v_role;
    exception when insufficient_privilege then null;
    end;
    reset role;
  end loop;
end;
$$;

-- Supporters public contract: list_public_supporters() returns display
-- fields only, never provider_user_id, and never hidden or test rows.
do $$
declare
  v_columns text[];
begin
  select array_agg(a.name order by a.ord) into v_columns
  from pg_proc p,
       unnest(p.proargnames, p.proargmodes::text[]) with ordinality as a(name, mode, ord)
  where p.oid = 'public.list_public_supporters()'::regprocedure and a.mode = 't';
  assert v_columns = array['display_name', 'avatar_url', 'profile_url', 'provider',
                           'support_type', 'tier', 'supporter_since'],
    format('list_public_supporters returns %s', v_columns);
end;
$$;

set role service_role;
insert into public.supporters
  (provider, provider_user_id, display_name, avatar_url, profile_url, is_public, is_active, supporter_since)
values
  ('kofi', 'email-sha256:00000000000000000000000000000000000000000000000000000000000000aa',
   'Fake Kofi Fan', null, null, true, true, '2026-01-02'),
  ('kofi', 'email-sha256:00000000000000000000000000000000000000000000000000000000000000bb',
   'Private supporter', null, null, false, true, '2026-01-03'),
  ('buymeacoffee', '777', 'Fake BMC Fan', 'https://img.example.test/777.png',
   'https://bmc.example.test/fake', true, true, '2026-01-04'),
  -- Provider test deliveries.
  ('buymeacoffee', '2345', 'Sample Supporter', null, null, true, true, '2026-01-05'),
  ('kofi', 'email-sha256:00000000000000000000000000000000000000000000000000000000000000cc',
   ' Jo Example ', null, null, true, true, '2026-01-06');
update public.supporters set supporter_since = '2026-01-01' where provider_user_id = 'public-active';
reset role;

create function pg_temp.public_supporter_names() returns text[]
language sql as $$
  select coalesce(array_agg(display_name), array[]::text[]) from public.list_public_supporters()
$$;

do $$
declare
  v_role text;
  v_names text[];
  v_payload text;
begin
  foreach v_role in array array['anon', 'authenticated'] loop
    execute format('set local role %I', v_role);
    v_names := pg_temp.public_supporter_names();
    assert v_names = array['Visible', 'Fake Kofi Fan', 'Fake BMC Fan'],
      format('%s gets public supporters %s', v_role, v_names);

    assert (select row(provider, avatar_url, profile_url)::text
            from public.list_public_supporters() where display_name = 'Fake BMC Fan')
           = row('buymeacoffee', 'https://img.example.test/777.png', 'https://bmc.example.test/fake')::text,
      'public supporter display fields changed';

    select string_agg(to_jsonb(s)::text, ',') into v_payload from public.list_public_supporters() s;
    assert v_payload not like '%email-sha256%' and v_payload not like '%provider_user_id%',
      format('%s received an internal supporter identifier', v_role);

    begin
      perform provider_user_id from public.list_public_supporters();
      raise exception '% read provider_user_id through list_public_supporters', v_role;
    exception when undefined_column then null;
    end;

    -- Compatibility for released apps, which read the table directly (and
    -- from beta.28 select provider_user_id). Remove with the direct read.
    perform provider_user_id from public.supporters;
    reset role;
  end loop;
end;
$$;

-- Once the direct read is retired (revoke + drop policy), the contract still
-- works and the table is closed to clients. Rolled back afterwards.
do $$
declare
  v_names text[];
begin
  revoke select on table public.supporters from anon, authenticated;
  drop policy "Public can read visible supporters" on public.supporters;

  set local role anon;
  v_names := pg_temp.public_supporter_names();
  assert v_names = array['Visible', 'Fake Kofi Fan', 'Fake BMC Fan'],
    format('after retiring the direct read anon gets %s', v_names);
  begin
    perform 1 from public.supporters;
    raise exception 'anon still reads public.supporters after the revoke';
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise exception using errcode = 'P0001', message = 'rollback retirement check';
exception when sqlstate 'P0001' then
  if sqlerrm <> 'rollback retirement check' then
    raise;
  end if;
end;
$$;

-- Webhook ingestion (service role) still keys supporters by
-- (provider, provider_user_id) and can read the identifier.
set role service_role;
insert into public.supporters (provider, provider_user_id, display_name, is_public, is_active)
values ('buymeacoffee', '777', 'Fake BMC Fan (renamed)', true, true)
on conflict (provider, provider_user_id) do update
  set display_name = excluded.display_name;
do $$
begin
  assert (select count(*) from public.supporters where provider = 'buymeacoffee' and provider_user_id = '777') = 1,
    'webhook upsert duplicated a supporter';
  assert (select display_name from public.supporters where provider_user_id = '777') = 'Fake BMC Fan (renamed)',
    'webhook upsert did not update the supporter';
end;
$$;
reset role;

select 'security checks passed' as result;
