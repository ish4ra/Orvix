-- Account deletion (supabase/functions/delete-account).
--
-- 1. Every Orvix row owned by an auth user is removed together with that user,
--    so deleting the Auth account cannot leave cloud data behind and a stale
--    access token cannot recreate rows for a deleted account:
--      orvix_user_state.user_id                    -> on delete cascade
--      orvix_user_credentials.user_id              -> on delete cascade
--      orvix_tv_login_sessions.approved_user_id    -> on delete cascade
--    A deleted account's TV login sessions are removed rather than kept with
--    the link cleared: an approved session is only useful for signing in to
--    that account, so keeping it would serve no purpose.
--
-- 2. delete_orvix_account_data(uuid) removes the same rows explicitly before
--    the Edge Function deletes the Auth user. Only the service role can run
--    it; the function always passes the caller's own user id.
--
-- orvix_user_credentials and its load/save RPCs were created in the
-- production project outside these migrations. This migration does not
-- recreate them; it only fixes the foreign key when the table exists, and
-- fails instead of guessing if the table has no user_id column.
--
-- The supporters table is not linked to Orvix accounts and is not touched.

do $$
declare
  v_table text;
  v_table_id regclass;
  v_fk record;
  v_columns text;
  v_ref_columns text;
begin
  foreach v_table in array array[
    'orvix_user_state',
    'orvix_user_credentials',
    'orvix_tv_login_sessions'
  ] loop
    v_table_id := to_regclass('public.' || v_table);
    continue when v_table_id is null;

    -- Recreate any foreign key to auth.users that does not cascade.
    for v_fk in
      select con.conname, con.conkey, con.confkey
      from pg_constraint con
      where con.conrelid = v_table_id
        and con.contype = 'f'
        and con.confrelid = 'auth.users'::regclass
        and con.confdeltype <> 'c'
    loop
      select string_agg(quote_ident(a.attname), ', ' order by k.ord)
        into v_columns
      from unnest(v_fk.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = v_table_id and a.attnum = k.attnum;

      select string_agg(quote_ident(a.attname), ', ' order by k.ord)
        into v_ref_columns
      from unnest(v_fk.confkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = 'auth.users'::regclass
        and a.attnum = k.attnum;

      execute format(
        'alter table public.%I drop constraint %I, '
        'add constraint %I foreign key (%s) references auth.users (%s) '
        'on delete cascade',
        v_table, v_fk.conname, v_fk.conname, v_columns, v_ref_columns);
    end loop;
  end loop;

  -- orvix_user_credentials comes from outside these migrations, so make sure
  -- it is linked to its auth user at all.
  v_table_id := to_regclass('public.orvix_user_credentials');
  if v_table_id is not null and not exists (
    select 1 from pg_constraint con
    where con.conrelid = v_table_id
      and con.contype = 'f'
      and con.confrelid = 'auth.users'::regclass
  ) then
    if not exists (
      select 1 from pg_attribute a
      where a.attrelid = v_table_id
        and a.attname = 'user_id'
        and not a.attisdropped
    ) then
      raise exception
        'public.orvix_user_credentials has no user_id column; update this '
        'migration to match the production table before applying it';
    end if;
    -- Rows whose auth user no longer exists belong to accounts that were
    -- already deleted and can no longer be read by anyone.
    delete from public.orvix_user_credentials c
    where not exists (select 1 from auth.users u where u.id = c.user_id);
    alter table public.orvix_user_credentials
      add constraint orvix_user_credentials_user_id_fkey
      foreign key (user_id) references auth.users (id) on delete cascade;
  end if;
end;
$$;

create or replace function public.delete_orvix_account_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_user_id is null then
    raise exception 'A user id is required';
  end if;

  delete from public.orvix_tv_login_sessions where approved_user_id = p_user_id;
  delete from public.orvix_user_state where user_id = p_user_id;
  if to_regclass('public.orvix_user_credentials') is not null then
    -- Dynamic so the function also works where the table does not exist.
    execute 'delete from public.orvix_user_credentials where user_id = $1'
      using p_user_id;
  end if;
end;
$$;

revoke all on function public.delete_orvix_account_data(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_orvix_account_data(uuid)
  to service_role;
