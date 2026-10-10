#!/usr/bin/env bash
# Automated simulation of the PoC on Linux: synthetic 10-minute MKV with an
# embedded English SRT track (negative container start time, like many real
# releases), a throttled HTTP server, a fake Gemini API with injected faults
# and a fake mpv IPC player. This checks the harness logic only; it is NOT
# playback evidence and says nothing about real Gemini latency or quality.
#
# Usage: internal/sim/run-sim.sh [workdir]     (needs go, ffmpeg, python3)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work/bin" "$work/runs"
cd "$root"
go build -o "$work/bin/sinhala-poc" .
go build -o "$work/bin/fakempv" ./internal/fakempv
go build -o "$work/bin/fakegemini" ./internal/fakegemini
cd "$work"
if [ ! -f sample.mkv ]; then
  python3 - <<'PY'
def ts(ms):
    return f"{ms//3600000:02}:{ms%3600000//60000:02}:{ms%60000//1000:02},{ms%1000:03}"
out, n, t = [], 1, 1500
while t < 600000:
    out.append(f"{n}\n{ts(t)} --> {ts(t+2100)}\nLine number {n}, the general said we move at dawn.\n")
    n += 1; t += 3000 + (n % 5) * 137
open("en.srt", "w").write("\n".join(out))
PY
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=320x180:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -i en.srt -t 600 -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -b:v 1500k -g 48 -c:a aac -b:a 96k \
    -c:s srt -metadata:s:s:0 language=eng sample.mkv
  # Reference track as mpv shows the embedded subtitle (start-time rebased).
  ffmpeg -hide_banner -loglevel error -y -i sample.mkv -map 0:2 -c:s srt ref.srt
fi

run() { # name faults bytesPerSec fakeSpeed [harness args...]
  local name=$1 faults=$2 rate=$3 speed=$4; shift 4
  local gport=$((18100 + RANDOM % 800)) sport=$((19000 + RANDOM % 800))
  FAKE_GEMINI_ADDR=127.0.0.1:$gport FAKE_GEMINI_LATENCY_MS=${LAT:-800} FAKE_GEMINI_FAULTS="$faults" ./bin/fakegemini >/dev/null 2>&1 &
  local gpid=$!
  python3 "$here/throttle.py" sample.mkv "$rate" "$sport" >/dev/null 2>&1 &
  local spid=$!
  sleep 1
  ORVIX_POC_GEMINI_KEY=test-key FAKE_MPV_REF_SRT=$PWD/ref.srt FAKE_MPV_DURATION=600 FAKE_MPV_SPEED=$speed \
    ./bin/sinhala-poc --url "http://127.0.0.1:$sport/sample.mkv" --source-id sim --mpv ./bin/fakempv \
    --gemini-endpoint "http://127.0.0.1:$gport" --orvix-dir /nonexistent --font-dir . --title Sim --out "runs/$name" "$@" \
    > "runs/$name.out" 2>&1 || true
  kill $gpid $spid 2>/dev/null || true
  echo "== $name"; sed -n '/## Verdicts/,/## Startup/p' "runs/$name/report.md" | grep '^|' | tail -n +3
}

rm -rf journals
run A-faults 'ratelimit@3,malformed@5,english@7,dup@9,refuse:Line number 150,' 1000000 5 --seek-plan '15:auto,35:auto,55:120,75:auto'
run B-resume 'ratelimit@3' 1000000 5 --seek-plan '15:auto,35:400,50:100'
rm -rf journals
run C-daily-quota 'daily@6' 1000000 5 --seek-plan '15:auto'
rm -rf journals
run D-slow-source '' 150000 1 --seek-plan '100:auto' --max-play 170
rm -rf journals
LAT=12000 run E-slow-api '' 1000000 5 --seek-plan '20:auto' --concurrency 1
rm -rf journals
LAT=15000 run F-api-too-slow '' 1000000 1 --seek-plan none --concurrency 1 --first-batch 6 --batch 6 --max-wait 90 --max-play 200
echo "Outputs in $work/runs"
