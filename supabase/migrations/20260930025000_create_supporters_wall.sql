create table if not exists public.supporters (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('github','kofi','buymeacoffee')),
  provider_user_id text not null,
  display_name text not null,
  avatar_url text,
  profile_url text,
  support_type text not null default 'Supporter',
  tier text,
  supporter_since timestamptz not null default now(),
  last_supported_at timestamptz not null default now(),
  is_recurring boolean not null default false,
  is_active boolean not null default true,
  is_public boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider, provider_user_id)
);
alter table public.supporters enable row level security;
drop policy if exists "Public can read visible supporters" on public.supporters;
create policy "Public can read visible supporters"
on public.supporters for select to anon, authenticated
using (is_public = true and is_active = true);
create index if not exists supporters_public_since_idx
on public.supporters (supporter_since desc)
where is_public = true and is_active = true;
