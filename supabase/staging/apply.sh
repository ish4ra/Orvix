#!/usr/bin/env bash
# Applies the repository's migrations to the Watch Party TEST Supabase
# project, then runs the read-only checks in verify.sql.
#
#   export ORVIX_STAGING_PROJECT_REF=<test project id>
#   export ORVIX_STAGING_DB_URL='postgresql://postgres.<test project id>:<password>@...'
#   supabase/staging/apply.sh
#
# Safe to run again: a migration that is already recorded is skipped. Each
# migration runs in its own transaction and is recorded in
# supabase_migrations.schema_migrations, the table the Supabase CLI uses.
#
# It refuses to run against the production project, and against any database
# whose address does not name the project you said you meant. The database
# address is read from the environment so the password never appears in the
# command line. Nothing here is run by CI.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
migrations="$here/../migrations"
config="$here/../../lib/services/orvix_backend_config.dart"

fail() {
  echo "staging: $*" >&2
  exit 1
}

ref=${ORVIX_STAGING_PROJECT_REF:-}
url=${ORVIX_STAGING_DB_URL:-}
[ -n "$ref" ] || fail "set ORVIX_STAGING_PROJECT_REF to the test project's id."
[ -n "$url" ] || fail "set ORVIX_STAGING_DB_URL to the test project's database address."
[[ "$ref" =~ ^[a-z0-9]{16,32}$ ]] || fail "ORVIX_STAGING_PROJECT_REF is not a project id."

production_ref=$(grep -oE "https://[a-z0-9]{16,32}\.supabase\.co" "$config" | head -1 |
  sed -E 's#https://([a-z0-9]+)\..*#\1#')
[ -n "$production_ref" ] || fail "could not read the production project id from the app source."

[ "$ref" != "$production_ref" ] || fail "that is the production project. Refusing."
case "$url" in
  *"$production_ref"*) fail "the database address names the production project. Refusing." ;;
esac
case "$url" in
  *"$ref"*) ;;
  *) fail "the database address does not name project $ref. Refusing." ;;
esac

run_psql() {
  psql "$url" --no-psqlrc --quiet --tuples-only --no-align --set ON_ERROR_STOP=1 "$@"
}

run_psql <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL

for file in "$migrations"/*.sql; do
  base=$(basename "$file" .sql)
  version=${base%%_*}
  name=${base#*_}
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "unexpected migration file name: $base"
  applied=$(run_psql --command \
    "select count(*) from supabase_migrations.schema_migrations where version = '$version'")
  if [ "$applied" != "0" ]; then
    echo "skip   $base"
    continue
  fi
  {
    echo 'begin;'
    cat "$file"
    echo
    echo "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name');"
    echo 'commit;'
  } | run_psql
  echo "apply  $base"
done

run_psql --file "$here/verify.sql"
echo "staging: migrations applied and checks passed for project $ref."
