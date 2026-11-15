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

echo "Machine: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)"

pids=()
names=()
for app in "$@"; do
  executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")
  name=$(basename "$app" .app)
  "$app/Contents/MacOS/$executable" > "$report/$name.log" 2>&1 &
  pids+=($!)
  names+=("$name")
  echo "Started $name (pid $!)"
done

sleep "$seconds"
screencapture -x "$report/screen.png" 2>/dev/null || echo "No screenshot (no display session)."

status=0
for index in "${!pids[@]}"; do
  pid=${pids[$index]}
  name=${names[$index]}
  app=${@:$((index + 1)):1}
  if kill -0 "$pid" 2>/dev/null; then
    echo "$name: still running after ${seconds}s"
  else
    echo "$name: STOPPED during the first ${seconds}s" >&2
    status=1
  fi
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
  if [ -d "$HOME/Library/Containers/$id" ]; then
    echo "$name: sandbox container $id exists"
  else
    echo "$name: no sandbox container for $id"
  fi
  if grep -qE "OrvixBackendConfigError|Unhandled exception" "$report/$name.log"; then
    echo "$name: startup error in its log:" >&2
    grep -E "OrvixBackendConfigError|Unhandled exception" "$report/$name.log" | head -5 >&2
    status=1
  fi
  kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true
exit $status
