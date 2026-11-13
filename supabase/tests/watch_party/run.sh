#!/usr/bin/env bash
# Runs the Watch Party database checks against a scratch PostgreSQL database
# (never a Supabase project). Everything runs in a transaction that is rolled
# back, so the database is left unchanged.
#
#   supabase/tests/watch_party/run.sh "postgresql://localhost:5432/scratch"
#
# The migrations are applied on top of Supabase's default privileges and a
# stand-in for Realtime, so a function that keeps a default EXECUTE grant or a
# room event that reaches the wrong listener fails here.
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
  cat "$here/../security/supabase_defaults.sql"
  cat "$here/realtime_stub.sql"
  for migration in "$migrations"/*.sql; do
    cat "$migration"
  done
  # Applying the Watch Party migration again must be harmless.
  cat "$migrations/20261112120000_create_watch_party.sql"
  cat "$here/watch_party_test.sql"
  echo 'rollback;'
} | psql "$database_url" --no-psqlrc --quiet --tuples-only
