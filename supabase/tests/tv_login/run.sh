#!/usr/bin/env bash
# Runs the TV device login database checks against a scratch PostgreSQL
# database (never a Supabase project). Everything runs in a transaction that
# is rolled back, so the database is left unchanged.
#
#   supabase/tests/tv_login/run.sh "postgresql://localhost:5432/scratch"
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
  for migration in "$migrations"/*.sql; do
    cat "$migration"
  done
  # Applying the hardening migration again must be harmless.
  cat "$migrations/20261007150000_harden_tv_device_login.sql"
  cat "$here/tv_login_test.sql"
  echo 'rollback;'
} | psql "$database_url" --no-psqlrc --quiet --tuples-only
