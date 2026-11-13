#!/usr/bin/env bash
# Checks the Watch Party rules that only matter under real concurrency, with
# many database sessions acting at the same moment:
#
#   * thirty people joining a room at once never push it past ten;
#   * chat messages sent together still get one unbroken sequence;
#   * playback commands that race end on the newest command, whatever order
#     they reach the database in.
#
# Concurrent sessions need committed data, so this creates its own throwaway
# database on the given server and drops it afterwards. Point it at a local
# scratch PostgreSQL server, never at a Supabase project.
#
#   supabase/tests/watch_party/concurrency.sh "postgresql://postgres@localhost:5432/postgres"
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <scratch server URL (any database you may create databases from)>" >&2
  exit 2
fi
admin_url=$1
here=$(cd "$(dirname "$0")" && pwd)
migrations="$here/../../migrations"
database="orvix_watch_party_concurrency_$$"
work=$(mktemp -d)

# Same server and credentials, different database name.
case "$admin_url" in
  *\?*) test_url="${admin_url%/*}/$database?${admin_url#*\?}" ;;
  *) test_url="${admin_url%/*}/$database" ;;
esac

cleanup() {
  psql "$admin_url" --no-psqlrc --quiet -c "drop database if exists \"$database\" with (force)" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

run() { psql "$test_url" --no-psqlrc --quiet --tuples-only --no-align -v ON_ERROR_STOP=1 "$@"; }

# One call as a signed-in user, in its own session and transaction.
as_user() {
  local user=$1 sql=$2
  run <<SQL
begin;
select set_config('request.jwt.claim.sub',
  ('00000000-0000-4000-8000-0000000000' || lpad('$user', 2, '0')), true) \gset ignored_
set local role authenticated;
$sql;
commit;
SQL
}

psql "$admin_url" --no-psqlrc --quiet -c "create database \"$database\""

{
  echo '\set ON_ERROR_STOP on'
  cat "$here/../account_deletion/auth_stub.sql"
  cat "$here/../security/supabase_defaults.sql"
  cat "$here/realtime_stub.sql"
  for migration in "$migrations"/*.sql; do
    cat "$migration"
  done
  cat <<'SQL'
insert into auth.users (id, email)
select ('00000000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'user' || n || '@example.test'
from generate_series(1, 40) n;
SQL
} | psql "$test_url" --no-psqlrc --quiet --tuples-only >/dev/null 2>&1

created=$(as_user 1 "select public.watch_party_create('Host')")
room=$(run -c "select ('$created'::jsonb)->'room'->>'id'")
code=$(run -c "select ('$created'::jsonb)->'room'->>'code'")
test -n "$room" && test -n "$code"

# --- Thirty simultaneous joins ---------------------------------------------
for user in $(seq 2 31); do
  as_user "$user" "select public.watch_party_join('$code', 'User $user')" >"$work/join_$user" 2>&1 &
done
wait

joined=$(cat "$work"/join_* | grep -c '"ok": true' || true)
full=$(cat "$work"/join_* | grep -c '"error": "room_full"' || true)
active=$(run -c "select count(*) from public.orvix_watch_room_participants where room_id = '$room' and left_at is null")
if [ "$joined" -ne 9 ] || [ "$full" -ne 21 ] || [ "$active" -ne 10 ]; then
  echo "concurrent joins: $joined joined, $full refused as full, $active active (expected 9, 21, 10)" >&2
  cat "$work"/join_* | grep -v '"ok": true' | grep -v room_full | head -5 >&2 || true
  exit 1
fi

# --- Simultaneous chat ------------------------------------------------------
members=$(run -c "select string_agg(substr(user_id::text, 35), ' ') from public.orvix_watch_room_participants where room_id = '$room' and left_at is null")
for member in $members; do
  user=$((10#$member))
  for message in 1 2 3 4 5; do
    as_user "$user" "select public.watch_party_send_message('$room', 'message $message from $user', gen_random_uuid())" >"$work/chat_${user}_$message" 2>&1 &
  done
done
wait

chat=$(run -c "select count(*) || ' ' || coalesce(min(seq), 0) || ' ' || coalesce(max(seq), 0) || ' ' || (select chat_seq from public.orvix_watch_rooms where id = '$room') from public.orvix_watch_room_messages where room_id = '$room'")
if [ "$chat" != "50 1 50 50" ]; then
  echo "concurrent chat: count/min/max/room sequence are '$chat' (expected '50 1 50 50')" >&2
  cat "$work"/chat_* | grep -v '"ok": true' | head -5 >&2 || true
  exit 1
fi
announced=$(run -c "select count(*) || ' ' || count(distinct payload->>'seq') from realtime.messages where event = 'chat'")
if [ "$announced" != "50 50" ]; then
  echo "concurrent chat: announcements are '$announced' (expected '50 50')" >&2
  exit 1
fi

# --- Racing playback commands -----------------------------------------------
as_user 1 "select public.watch_party_set_media('$room', 'movie', 'tt1375666')" >/dev/null
for command in $(seq 1 20); do
  playing=$([ $((command % 2)) -eq 0 ] && echo true || echo false)
  as_user 1 "select public.watch_party_set_playback('$room', $playing, $((command * 100000)), $command)" >"$work/play_$command" 2>&1 &
done
wait

final=$(run -c "select r.position_ms || ' ' || r.is_playing || ' ' || p.last_command_seq from public.orvix_watch_rooms r join public.orvix_watch_room_participants p on p.room_id = r.id and p.user_id = r.host_user_id where r.id = '$room'")
if [ "$final" != "2000000 true 20" ]; then
  echo "racing playback commands ended on '$final' (expected the newest command, '2000000 true 20')" >&2
  exit 1
fi
# Every accepted command got its own state number, announced in order.
order=$(run -c "select bool_and(seq > previous) from (select (payload->'playback'->>'seq')::bigint as seq, lag((payload->'playback'->>'seq')::bigint, 1, 0) over (order by id) as previous from realtime.messages where event = 'state') s")
states=$(run -c "select (select count(*) from realtime.messages where event = 'state') = (select state_seq from public.orvix_watch_rooms where id = '$room')")
if [ "$order" != "t" ] || [ "$states" != "t" ]; then
  echo "racing playback commands: ordered=$order, one announcement per state=$states" >&2
  exit 1
fi

echo "watch party concurrency checks passed"
