-- Private analytics/control-center storage for Orvix.
-- Clients never read/write these tables directly. Edge Functions use the
-- service role and all exposed roles are explicitly revoked.

create table if not exists public.orvix_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.orvix_analytics_installations (
  installation_id uuid primary key,
  user_id uuid references auth.users(id) on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  country_code text,
  platform text not null,
  os_version text,
  locale text,
  app_version text not null,
  build_number text,
  is_tv boolean not null default false,
  constraint orvix_analytics_country_code_check
    check (country_code is null or country_code ~ '^[A-Z]{2}$')
);

create table if not exists public.orvix_analytics_sessions (
  session_id uuid primary key,
  installation_id uuid not null
    references public.orvix_analytics_installations(installation_id)
    on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  last_heartbeat_at timestamptz not null default now(),
  ended_at timestamptz,
  is_foreground boolean not null default true,
  country_code text,
  platform text not null,
  app_version text not null,
  build_number text,
  constraint orvix_analytics_session_country_code_check
    check (country_code is null or country_code ~ '^[A-Z]{2}$')
);

create table if not exists public.orvix_analytics_events (
  id bigint generated always as identity primary key,
  installation_id uuid not null
    references public.orvix_analytics_installations(installation_id)
    on delete cascade,
  session_id uuid
    references public.orvix_analytics_sessions(session_id)
    on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  event_name text not null,
  event_category text not null default 'app',
  properties jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create table if not exists public.orvix_analytics_errors (
  id bigint generated always as identity primary key,
  installation_id uuid not null
    references public.orvix_analytics_installations(installation_id)
    on delete cascade,
  session_id uuid
    references public.orvix_analytics_sessions(session_id)
    on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  error_type text not null,
  message text not null,
  stack text,
  fatal boolean not null default false,
  platform text not null,
  app_version text not null,
  occurred_at timestamptz not null default now()
);

create index if not exists orvix_analytics_installations_last_seen_idx
  on public.orvix_analytics_installations (last_seen_at desc);
create index if not exists orvix_analytics_installations_user_idx
  on public.orvix_analytics_installations (user_id);
create index if not exists orvix_analytics_installations_country_idx
  on public.orvix_analytics_installations (country_code);
create index if not exists orvix_analytics_sessions_heartbeat_idx
  on public.orvix_analytics_sessions (last_heartbeat_at desc);
create index if not exists orvix_analytics_sessions_installation_idx
  on public.orvix_analytics_sessions (installation_id);
create index if not exists orvix_analytics_sessions_user_idx
  on public.orvix_analytics_sessions (user_id);
create index if not exists orvix_analytics_events_occurred_idx
  on public.orvix_analytics_events (occurred_at desc);
create index if not exists orvix_analytics_events_name_idx
  on public.orvix_analytics_events (event_name, occurred_at desc);
create index if not exists orvix_analytics_errors_occurred_idx
  on public.orvix_analytics_errors (occurred_at desc);

alter table public.orvix_admins enable row level security;
alter table public.orvix_analytics_installations enable row level security;
alter table public.orvix_analytics_sessions enable row level security;
alter table public.orvix_analytics_events enable row level security;
alter table public.orvix_analytics_errors enable row level security;

revoke all on table public.orvix_admins from anon, authenticated;
revoke all on table public.orvix_analytics_installations from anon, authenticated;
revoke all on table public.orvix_analytics_sessions from anon, authenticated;
revoke all on table public.orvix_analytics_events from anon, authenticated;
revoke all on table public.orvix_analytics_errors from anon, authenticated;
revoke usage, select on sequence public.orvix_analytics_events_id_seq
  from anon, authenticated;
revoke usage, select on sequence public.orvix_analytics_errors_id_seq
  from anon, authenticated;
