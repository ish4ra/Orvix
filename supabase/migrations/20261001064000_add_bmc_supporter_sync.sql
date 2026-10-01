alter table public.supporters
  add column if not exists provider_sync_id text;

create index if not exists supporters_provider_sync_id_idx
  on public.supporters (provider, provider_sync_id)
  where provider_sync_id is not null;

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;
