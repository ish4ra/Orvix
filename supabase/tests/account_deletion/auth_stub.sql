-- Minimal stand-in for the parts of a Supabase project the Orvix migrations
-- use: the API roles, auth.users and auth.uid(). For a scratch database only.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'auth') then
    raise exception 'auth schema exists: run these tests only against an empty scratch database, never a Supabase project';
  end if;
end;
$$;

do $$
declare
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = v_role) then
      execute format('create role %I nologin', v_role);
    end if;
  end loop;
  -- As in Supabase, the service role is not subject to row level security.
  alter role service_role bypassrls;
end;
$$;

create schema auth;
create table auth.users (
  id uuid primary key,
  email text
);
create function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
-- Supabase gives the service role full access to tables in public.
alter default privileges in schema public
  grant all on tables to service_role;
