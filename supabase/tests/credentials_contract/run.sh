#!/usr/bin/env bash
# Checks the provider credential RPC contract (contract_test.sql) against a
# database that already has the credential table and RPCs: a local Supabase
# stack or scratch database restored from a schema-only dump of production
# (see README.md). Everything runs in a transaction that is rolled back.
#
#   supabase/tests/credentials_contract/run.sh "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
#
# Never run this against the production project: it creates throwaway auth
# users. Read production with inspect_readonly.sql instead.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <non-production database URL>" >&2
  exit 2
fi
database_url=$1
here=$(cd "$(dirname "$0")" && pwd)

case "$database_url" in
  *kpjuisxofwqxhbnnsyzf*)
    echo "refusing to run against the production project; use inspect_readonly.sql" >&2
    exit 2
    ;;
esac

{
  echo '\set ON_ERROR_STOP on'
  echo 'begin;'
  cat "$here/contract_test.sql"
  echo 'rollback;'
} | psql "$database_url" --no-psqlrc --quiet --tuples-only | sed '/^ *$/d'
