#!/usr/bin/env bash
# Proves contract_test.sql itself works, against two test doubles in an empty
# scratch PostgreSQL database (never a Supabase project): it must pass for a
# replacing store and fail for a merging one. Rolled back; nothing is kept.
#
#   supabase/tests/credentials_contract/selfcheck.sh "postgresql://localhost:5432/scratch"
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <scratch database URL>" >&2
  exit 2
fi
database_url=$1
here=$(cd "$(dirname "$0")" && pwd)

run_against() {
  {
    echo '\set ON_ERROR_STOP on'
    echo 'begin;'
    cat "$here/../account_deletion/auth_stub.sql"
    for double in "$@"; do
      cat "$here/doubles/$double"
    done
    cat "$here/contract_test.sql"
    echo 'rollback;'
  } | psql "$database_url" --no-psqlrc --quiet --tuples-only | sed '/^ *$/d'
}

echo "== replacing store (must pass)"
run_against replacing.sql

echo "== merging store (must fail)"
if output=$(run_against replacing.sql merging.sql 2>&1); then
  echo "$output"
  echo "the contract test did not catch a merging store" >&2
  exit 1
fi
echo "$output" | grep -E 'FAIL|failed' || true
echo "merging store rejected as expected"
