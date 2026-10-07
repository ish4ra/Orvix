-- TEST DOUBLE. This is NOT the production implementation, which was created
-- in the production project outside the repo migrations and is unknown
-- here. It exists only so selfcheck.sh can prove that contract_test.sql
-- passes for a store with the contract the app relies on. It encrypts with
-- a throwaway test key (pgcrypto); production uses its own key management.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.orvix_user_credentials (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload text not null,
  updated_at timestamptz not null default now()
);
alter table public.orvix_user_credentials enable row level security;
revoke all on public.orvix_user_credentials from anon, authenticated;

create function public.save_orvix_credentials(p_payload jsonb) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  insert into public.orvix_user_credentials (user_id, payload, updated_at)
  values (auth.uid(),
          encode(extensions.pgp_sym_encrypt(p_payload::text,
                 'orvix-contract-selfcheck-test-key'), 'base64'),
          now())
  on conflict (user_id) do update
    set payload = excluded.payload, updated_at = excluded.updated_at;
end;
$$;

create function public.load_orvix_credentials() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  select payload into v_payload
    from public.orvix_user_credentials where user_id = auth.uid();
  if v_payload is null then
    return '{}'::jsonb;
  end if;
  return extensions.pgp_sym_decrypt(decode(v_payload, 'base64'),
         'orvix-contract-selfcheck-test-key')::jsonb;
end;
$$;

revoke all on function public.save_orvix_credentials(jsonb) from public, anon;
revoke all on function public.load_orvix_credentials() from public, anon;
grant execute on function public.save_orvix_credentials(jsonb) to authenticated;
grant execute on function public.load_orvix_credentials() to authenticated;
