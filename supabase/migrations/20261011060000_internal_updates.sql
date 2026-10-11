-- Owner-only internal update distribution. No client-readable tables or objects.
create table if not exists public.orvix_internal_release_assets (
  version text not null,
  platform text not null check (platform in ('windows','android_tv','android_mobile','macos','ios_modern','ios_legacy')),
  object_path text not null unique,
  asset_name text not null,
  size_bytes bigint not null check (size_bytes > 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  notes text not null default '',
  created_at timestamptz not null default now(),
  primary key (version, platform)
);
alter table public.orvix_internal_release_assets enable row level security;
revoke all on public.orvix_internal_release_assets from anon, authenticated;
-- Server-side service role alone maintains the release manifest.
insert into storage.buckets (id, name, public, file_size_limit)
values ('orvix-internal-updates', 'orvix-internal-updates', false, 2147483648)
on conflict (id) do update set public = false;
-- Deliberately NO anon/authenticated storage.objects SELECT/INSERT policy.
-- Signed URLs are issued by orvix-internal-update only after validating JWT
-- AND checking public.orvix_admins against the authenticated user ID.
