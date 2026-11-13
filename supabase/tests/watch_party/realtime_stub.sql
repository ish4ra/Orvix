-- Minimal stand-in for Supabase Realtime's database side: the
-- realtime.messages table that private Broadcast is authorized against, the
-- realtime.topic() accessor and realtime.send(). For a scratch database only
-- (after auth_stub.sql). Real Realtime evaluates the same SELECT policy with
-- the listener's role and JWT claims and the topic in a setting, which is
-- what the tests reproduce.
create schema realtime;

create table realtime.messages (
  id bigint generated always as identity primary key,
  topic text not null,
  extension text not null,
  payload jsonb,
  event text,
  private boolean default false,
  inserted_at timestamptz not null default now()
);
alter table realtime.messages enable row level security;

create function realtime.topic() returns text
language sql stable
as $$ select nullif(current_setting('realtime.topic', true), '') $$;

create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void
language sql
as $$
  insert into realtime.messages (topic, extension, payload, event, private)
  values (topic, 'broadcast', payload, event, private);
$$;

grant usage on schema realtime to anon, authenticated, service_role;
grant select, insert on realtime.messages to anon, authenticated;
grant execute on function realtime.topic() to anon, authenticated, service_role;
