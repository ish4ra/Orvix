#!/usr/bin/env bash
# Runs the account deletion database checks against a scratch PostgreSQL
# database (never a Supabase project). Everything runs in a transaction that
# is rolled back, so the database is left unchanged.
#
#   supabase/tests/account_deletion/run.sh "postgresql://localhost:5432/scratch"
#
# Two scenarios: without orvix_user_credentials (a fresh project from these
# migrations) and with it created first, as in production.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <scratch database URL>" >&2
  exit 2
fi
database_url=$1
here=$(cd "$(dirname "$0")" && pwd)
migrations="$here/../../migrations"

run_scenario() {
  local name=$1 before=$2
  echo "== $name"
  {
    echo '\set ON_ERROR_STOP on'
    echo 'begin;'
    cat "$here/auth_stub.sql"
    for migration in "$migrations"/*.sql; do
      if [ -n "$before" ] && [ "$(basename "$migration")" = "20261007120000_account_deletion.sql" ]; then
        cat "$before"
      fi
      cat "$migration"
    done
    # Applying the account deletion migration again must be harmless.
    cat "$migrations/20261007120000_account_deletion.sql"
    cat "$here/account_deletion_test.sql"
    echo 'rollback;'
  } | psql "$database_url" --no-psqlrc --quiet --tuples-only
}

run_scenario "fresh project" ""
run_scenario "production credentials table" "$here/production_credentials.sql"
