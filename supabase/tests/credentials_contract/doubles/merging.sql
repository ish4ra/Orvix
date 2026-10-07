-- TEST DOUBLE with the WRONG contract: save merges into the stored payload
-- instead of replacing it. Applied on top of replacing.sql; selfcheck.sh
-- expects contract_test.sql to fail against it. Not production code.
create or replace function public.save_orvix_credentials(p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  v_previous := public.load_orvix_credentials();
  insert into public.orvix_user_credentials (user_id, payload, updated_at)
  values (auth.uid(),
          encode(extensions.pgp_sym_encrypt((v_previous || p_payload)::text,
                 'orvix-contract-selfcheck-test-key'), 'base64'),
          now())
  on conflict (user_id) do update
    set payload = excluded.payload, updated_at = excluded.updated_at;
end;
$$;
