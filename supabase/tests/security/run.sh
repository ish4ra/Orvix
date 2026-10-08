#!/usr/bin/env bash
# Checks the client-facing security boundary of the Orvix schema (table
# privileges, row level security, function EXECUTE grants, SECURITY DEFINER
# settings) against a scratch PostgreSQL database (never a Supabase project).
# Everything runs in a transaction that is rolled back.
#
#   supabase/tests/security/run.sh "postgresql://localhost:5432/scratch"
#
# The migrations are applied on top of Supabase's default privileges (ALL on
# new tables, sequences and functions for anon and authenticated), so a new
# object that forgets its revokes fails here.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <scratch database URL>" >&2
  exit 2
fi
database_url=$1
here=$(cd "$(dirname "$0")" && pwd)
migrations="$here/../../migrations"

{
  echo '\set ON_ERROR_STOP on'
  echo 'begin;'
  cat "$here/../account_deletion/auth_stub.sql"
  cat "$here/supabase_defaults.sql"
  for migration in "$migrations"/*.sql; do
    cat "$migration"
  done
  # Applying the privilege migration again must be harmless.
  cat "$migrations/20261008100000_harden_table_privileges.sql"
  cat "$here/security_test.sql"
  echo 'rollback;'
} | psql "$database_url" --no-psqlrc --quiet --tuples-only
