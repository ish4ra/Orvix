-- Supabase's default privileges for objects the migration role creates in
-- public: every API role gets ALL on tables, sequences and functions unless
-- a migration revokes it. For a scratch database only (after auth_stub.sql).
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
