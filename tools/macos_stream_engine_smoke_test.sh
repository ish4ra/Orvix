#!/usr/bin/env bash
# Checks that a built macOS stream engine starts, answers, honours its port
# setting and does not outlive the process that started it.
#
#   tools/macos_stream_engine_smoke_test.sh <engine binary>
#
# This runs the engine on its own, outside the app and outside the sandbox.
# tools/macos_sandbox_engine_test.sh covers the sandbox.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <engine binary>" >&2
  exit 2
fi
engine=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
test -x "$engine" || { echo "engine: $engine is not executable." >&2; exit 1; }
work=$(mktemp -d)
echo "Engine architectures: $(lipo -archs "$engine")  (this machine: $(uname -m))"

answers() { curl --fail --silent --max-time 2 "http://127.0.0.1:$1/heartbeat" > /dev/null; }

wait_ready() { # <port> <pid> <log>
  for _ in $(seq 1 120); do
    if answers "$1"; then return 0; fi
    if ! kill -0 "$2" 2>/dev/null; then
      echo "engine: exited before answering on port $1." >&2
      tail -n 40 "$3" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "engine: no answer on port $1 within 60 s." >&2
  tail -n 40 "$3" >&2 || true
  return 1
}

# 1. Default port.
(cd "$work" && exec "$engine" --no-tray > "$work/default.log" 2>&1) &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
wait_ready 11470 "$pid" "$work/default.log"
echo "Default port: answering on 127.0.0.1:11470"

# 2. A second engine on its own port, next to the first. The engine allows
# one instance per temporary folder (a lock file there). Every sandboxed app
# has a temporary folder of its own, so a second app is modelled by giving
# the second engine another one.
mkdir -p "$work/second-tmp" "$work/orphan-tmp"
(cd "$work" && TMPDIR="$work/second-tmp/" ORVIX_STREAM_SERVER_PORT=11493 \
  exec "$engine" --no-tray > "$work/second.log" 2>&1) &
second=$!
trap 'kill "$pid" "$second" 2>/dev/null || true' EXIT
wait_ready 11493 "$second" "$work/second.log"
answers 11470 || { echo "engine: the first engine stopped answering." >&2; exit 1; }
echo "Second engine: answering on 127.0.0.1:11493 while the first keeps 11470"

# 2b. A second engine in the same temporary folder is refused, not started
# twice: this is what stops one app from running two engines.
(cd "$work" && ORVIX_STREAM_SERVER_PORT=11496 "$engine" --no-tray > "$work/duplicate.log" 2>&1) || true
if answers 11496; then
  echo "engine: a second engine started for the same temporary folder." >&2
  exit 1
fi
echo "Same temporary folder: a duplicate engine is refused"

# 3. Not reachable from the network: it listens on the loopback address only.
if lsof -nP -a -p "$second" -iTCP -sTCP:LISTEN 2>/dev/null | grep -v "127.0.0.1:" | grep -q LISTEN; then
  echo "engine: it listens on an address other than 127.0.0.1:" >&2
  lsof -nP -a -p "$second" -iTCP -sTCP:LISTEN >&2
  exit 1
fi
echo "Listening on 127.0.0.1 only"

kill "$pid" "$second" 2>/dev/null || true
wait "$pid" "$second" 2>/dev/null || true
for _ in $(seq 1 20); do answers 11470 || break; sleep 0.5; done
if answers 11470; then echo "engine: still answering after being stopped." >&2; exit 1; fi
echo "Stopped: the port is free again"

# 4. It exits when the process that started it goes away.
bash -c "cd '$work' && TMPDIR='$work/orphan-tmp/' ORVIX_STREAM_SERVER_PORT=11495 '$engine' --no-tray > '$work/orphan.log' 2>&1 & echo \$! > '$work/orphan.pid'; sleep 6"
orphan=$(cat "$work/orphan.pid")
gone=0
for _ in $(seq 1 30); do
  if ! kill -0 "$orphan" 2>/dev/null; then gone=1; break; fi
  sleep 0.5
done
if [ "$gone" -ne 1 ]; then
  kill "$orphan" 2>/dev/null || true
  echo "engine: it kept running after the process that started it exited." >&2
  exit 1
fi
echo "Exits with its parent: no engine is left behind"
trap - EXIT
echo "Stream engine smoke test passed."
