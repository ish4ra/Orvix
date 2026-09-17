create table if not exists public.orvix_user_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  watchlist jsonb not null default '[]'::jsonb,
  library jsonb not null default '[]'::jsonb,
  progress jsonb not null default '{}'::jsonb,
  home_sections jsonb not null default '[]'::jsonb,
  preferred_cloud text not null default 'pikpak',
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.orvix_user_state enable row level security;

grant select, insert, update, delete on public.orvix_user_state to authenticated;

create policy "users can read own orvix state"
on public.orvix_user_state
for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "users can insert own orvix state"
on public.orvix_user_state
for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "users can update own orvix state"
on public.orvix_user_state
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "users can delete own orvix state"
on public.orvix_user_state
for delete
to authenticated
using ((select auth.uid()) = user_id);

create or replace function public.set_orvix_user_state_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_orvix_user_state_updated_at on public.orvix_user_state;
create trigger trg_orvix_user_state_updated_at
before update on public.orvix_user_state
for each row execute function public.set_orvix_user_state_updated_at();
