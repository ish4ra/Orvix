#!/usr/bin/env bash
# Starts built macOS apps and checks that they keep running.
#
#   tools/macos_launch_smoke_test.sh <report directory> <app> [<app> ...]
#
# Every app is started, left running together for a while, and must still be
# alive at the end. This catches an app that cannot load its libraries, is
# killed by the system for a bad signature, or stops at startup. It also
# records which sandbox container each app got, and a screenshot.
#
# When an app stops, its own output and the system's crash report are
# printed, so the reason is in the job log.
#
# It proves the app starts on the machine it runs on. It does not test
# playback or anything a person has to look at.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <report directory> <app> [<app> ...]" >&2
  exit 2
fi
report=$1
shift
mkdir -p "$report"
seconds=${ORVIX_LAUNCH_SECONDS:-25}
here=$(cd "$(dirname "$0")" && pwd)

echo "Machine: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)"

pids=()
names=()
stopped_after=()
for app in "$@"; do
  executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")
  name=$(basename "$app" .app)
  "$app/Contents/MacOS/$executable" > "$report/$name.log" 2>&1 &
  pids+=($!)
  names+=("$name")
  stopped_after+=("")
  echo "Started $name (pid $!)"
done

for ((second = 1; second <= seconds; second++)); do
  sleep 1
  for index in "${!pids[@]}"; do
    if [ -z "${stopped_after[$index]}" ] && ! kill -0 "${pids[$index]}" 2>/dev/null; then
      stopped_after[$index]=$second
    fi
  done
done
screencapture -x "$report/screen.png" 2>/dev/null || echo "No screenshot (no display session)."

status=0
for index in "${!pids[@]}"; do
  pid=${pids[$index]}
  name=${names[$index]}
  app=${@:$((index + 1)):1}
  executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
  if [ -z "${stopped_after[$index]}" ]; then
    echo "$name: still running after ${seconds}s"
  else
    code=0
    wait "$pid" 2>/dev/null || code=$?
    echo "$name: STOPPED after about ${stopped_after[$index]}s (exit status $code)"
    status=1
    echo "--- $name: last output"
    tail -n 40 "$report/$name.log" || true
    echo "--- $name: crash report"
    python3 "$here/macos_crash_summary.py" "$executable" "$report/$name.crash.txt" || true
  fi
  if [ -d "$HOME/Library/Containers/$id" ]; then
    echo "$name: sandbox container $id exists"
  else
    echo "$name: no sandbox container for $id"
  fi
  if grep -qE "OrvixBackendConfigError|Unhandled exception" "$report/$name.log"; then
    echo "$name: startup error in its log:"
    grep -E "OrvixBackendConfigError|Unhandled exception" "$report/$name.log" | head -5
    status=1
  fi
  kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true
exit $status
