-- Public supporters contract: list_public_supporters().
--
-- The app used to read public.supporters directly. That read path returns
-- every column the client asks for, including provider_user_id (for Ko-fi
-- supporters with an email, a SHA-256 of that email), and the app filtered
-- provider test rows locally by provider_user_id. This function is the new
-- public read path. It returns only the fields the Supporters screen shows,
-- applies the visibility rules on the server and never returns provider
-- test rows, so a client never receives a row it is not meant to display.
--
-- It is SECURITY DEFINER so that it keeps working once the clients' direct
-- SELECT on public.supporters is revoked (see "Retiring the direct read"
-- below). Its filter is explicit and does not depend on row level security.
--
-- Backward compatibility: released app versions (0.7.9-beta.26 and later)
-- still read public.supporters directly; beta.28 and later select
-- provider_user_id. This migration therefore leaves the table, its data,
-- its grants and its "Public can read visible supporters" policy unchanged.
--
-- Retiring the direct read (a later migration, once the app versions that
-- read the table are no longer supported):
--   revoke select on table public.supporters from anon, authenticated;
--   drop policy "Public can read visible supporters" on public.supporters;
-- provider_user_id stays: the supporter webhooks upsert on
-- (provider, provider_user_id) with the service role.
--
-- Revert: drop function if exists public.list_public_supporters();

create or replace function public.list_public_supporters()
returns table (
  display_name text,
  avatar_url text,
  profile_url text,
  provider text,
  support_type text,
  tier text,
  supporter_since timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    s.display_name,
    s.avatar_url,
    s.profile_url,
    s.provider,
    s.support_type,
    s.tier,
    s.supporter_since
  from public.supporters s
  where s.is_public
    and s.is_active
    -- Provider test deliveries: the Buy Me a Coffee sample supporter and
    -- the Ko-fi test webhook sender. Same rule the app applied locally.
    and not (s.provider = 'buymeacoffee' and s.provider_user_id = '2345')
    and not (s.provider = 'kofi' and btrim(s.display_name) = 'Jo Example')
  order by s.supporter_since, s.id
  limit 250
$$;

comment on function public.list_public_supporters() is
  'Public supporters wall: display fields of visible supporters only. Never returns provider_user_id.';

revoke all on function public.list_public_supporters() from public, anon, authenticated;
grant execute on function public.list_public_supporters() to anon, authenticated, service_role;
