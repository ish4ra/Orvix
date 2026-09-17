-- Orvix v0.6.0 account sync state.
-- One row per authenticated user. Provider credentials are intentionally not
-- stored here; this table only contains app preferences and media state.

create table if not exists public.orvix_sync_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  library jsonb not null default '{"library":[],"watchlist":[]}'::jsonb,
  progress jsonb not null default '{}'::jsonb,
  settings_updated_at timestamptz not null default now(),
  library_updated_at timestamptz not null default now(),
  progress_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.orvix_sync_state enable row level security;

revoke all on table public.orvix_sync_state from anon;
revoke all on table public.orvix_sync_state from authenticated;
grant select, insert, update, delete on table public.orvix_sync_state to authenticated;

drop policy if exists "orvix users can read own sync state"
  on public.orvix_sync_state;
create policy "orvix users can read own sync state"
  on public.orvix_sync_state
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "orvix users can insert own sync state"
  on public.orvix_sync_state;
create policy "orvix users can insert own sync state"
  on public.orvix_sync_state
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "orvix users can update own sync state"
  on public.orvix_sync_state;
create policy "orvix users can update own sync state"
  on public.orvix_sync_state
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "orvix users can delete own sync state"
  on public.orvix_sync_state;
create policy "orvix users can delete own sync state"
  on public.orvix_sync_state
  for delete
  to authenticated
  using ((select auth.uid()) = user_id);

comment on table public.orvix_sync_state is
  'Local-first Orvix library, watch progress and non-sensitive preference sync.';
