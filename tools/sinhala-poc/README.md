# AI Sinhala pipeline — isolated Windows proof of concept

`sinhala-poc` is a standalone test tool. It does not change, start or replace
the Orvix app, and nothing here is wired into any Orvix build or release.

It tests one question with real playback: can a first-time episode, with no
cache, start in about 60 seconds with correctly synchronized Sinhala, and stay
in Sinhala for the whole episode without pauses or English fallback, using the
viewer's own free Gemini key?

## How it works

1. **English source:** the video's own embedded English *text* subtitle,
   extracted progressively from the playhead with ffmpeg (Orvix's bundled
   copy). Cues stream out as the file is read. No full-file pass before play.
2. **Timing:** cue times are copied from that English track and corrected
   for the container start time, because mpv shifts embedded tracks by the
   file's start time but not external subtitle files. The Sinhala SRT is
   loaded with `sub-add` and refreshed with `sub-reload` only when no
   subtitle is on screen. Same principle as the old Windows path: the model
   never sees or returns times.
3. **Translation:** text only, as `{id, en}` → `{id, si}`, sent directly from
   this PC to `generativelanguage.googleapis.com` with your key in the
   `x-goog-api-key` header. There is no Orvix server and no developer key in
   this tool. Every cue is validated on its own; one bad cue never discards
   its batch.
4. **Persistence:** accepted Sinhala cues and the extracted English timeline
   are saved in `journals\` after every batch. A rerun or restart reuses
   them and never requests a finished cue again.
5. **Start rule:** playback starts only when the first 60 s from the start
   position are Sinhala, two requests have completed, measured translation
   throughput is at least 1.5× the episode's cue rate, and English extraction
   runs at least 1.25× real time. The console shows which condition it is
   waiting on.
6. **During playback:** if ready Sinhala ahead drops below 8 s, playback
   pauses ("Sinhala is catching up…") and resumes at 30 s. Every pause is
   recorded as a shortfall.
7. **Measurement:** the video's own English track is selected as a hidden
   secondary subtitle, so mpv itself reports, cue by cue, whether the Sinhala
   line on screen starts at the same moment as the original English line.

## What this changes compared with the earlier buffered approach

The earlier "prepare a first batch, translate the rest in the background"
path (`_prepareBufferedNativeCueAi` in `player_screen.dart` and
`prepareTrustedTranscriptForNativeClock` / `ensureTranslatedAround` in
`ai_sinhala_subtitle_service.dart` on `develop`) differs at each point where
it failed:

| Point | Earlier path (from the code) | This experiment |
| --- | --- | --- |
| English source | Waited for the **whole** embedded track (full-file read through the stream-server routes or FFmpegKit, with 20–35 s limits, 4 min for FFmpegKit) or an OpenSubtitles exact match before translating anything | Streams cues out of ffmpeg from the playhead; translation starts after the first cues |
| How Sinhala reaches the screen | Flutter overlay; each English cue mpv shows is looked up by fuzzy text match, polled every 200 ms; untranslated cues fall back to English per cue | mpv renders a Sinhala SRT whose times are copied from the English cues; no text matching or overlay |
| What is translated ahead | 36 cues before start, then 24 cues around the playhead per 30 s bucket; one request at a time | Everything extracted, from the playhead forward, two requests in parallel |
| When playback starts | After the first 36 cues, with no check that translation can keep up | When 60 s are Sinhala **and** measured throughput is ≥ 1.5× the cue rate **and** extraction is ≥ 1.25× real time |
| A bad cue | Whole batch retried, then the window fails | Only that cue is retried; it is then marked and counted as an English fallback |
| Progress | In memory; lost on restart | Saved to disk after every batch; resumes without re-requesting |
| Key | Sent to the Orvix Supabase function (repository code uses the server key) | Sent only to Google, from this PC |
| Falling behind | Silent: English appears | An explicit pause, recorded as a shortfall |

## Setup (once)

1. Install Orvix normally. The tool uses its bundled ffmpeg/ffprobe and its
   Free P2P stream server. Default location: `%LOCALAPPDATA%\Programs\Orvix`.
2. Download a current Windows build of **mpv** (0.38 or newer) from
   <https://mpv.io/installation/> and put `mpv.exe` in the `mpv` folder next
   to these scripts. A separate mpv is used so the test cannot disturb the
   Orvix player; it is the same libmpv engine family Orvix uses on Windows.
3. **Close Orvix** before each test.
4. Windows may warn that `sinhala-poc.exe` is unsigned. It is built from
   `tools/sinhala-poc` on the `feature/sinhala-pipeline-poc` branch.

## The tests

Open PowerShell in this folder. If scripts are blocked, run
`Set-ExecutionPolicy -Scope Process Bypass` in that window first. The first
script asks for your Gemini key once per window. The input is hidden, and the
key is never written to disk.

**Cold start:** use episodes you have not streamed in Orvix recently. Keep
`journals\` empty for the first run of each episode, and pass `-Title` so the
translator has context.

### Run 1 — Free P2P, previously troublesome source, whole episode

```
.\run-p2p.ps1 -Magnet "magnet:?xt=urn:btih:<hash>..." -FileHint "S02E05" -Title "Star Wars: The Clone Wars S02E05"
```

Use the same torrent Orvix had trouble with. `-FileHint` selects the episode
inside a season pack; alternatively pass `-FileIdx`. If the release only has
image (PGS) English subtitles, the tool stops and says so. That is a real
"unavailable" result; record it, then pick another release of the same title.

### Run 2 — debrid file with embedded English text subtitles, whole episode

```
.\run-debrid.ps1 -Url "<direct download link from TorBox>" -SourceId "torbox-<itemId>-<fileId>" -Title "<Show SxxEyy>"
```

### What happens in each run

- The console prints why it is waiting, then **Playback started at N s**.
- Four automatic seeks happen at 5, 10, 15 and 20 minutes. Each picks a
  position whose Sinhala is not ready yet. You may also seek yourself; every
  seek is measured.
- Let the episode play to the end, or close mpv to stop early.
- At the end, a report prints and is saved in `runs\<date-time>\`.

### Run 3 — resume check (short)

Rerun Run 2's exact command. It should start almost immediately. The report
should show the cues loaded from `journals\` and `0 re-requested`. To test an
interrupted preparation instead, start a new episode, press Ctrl+C while it
says "Preparing Sinhala…", and run the same command again.

## What to send back

From each run's `runs\<date-time>\` folder, send `report.md`, `summary.json`
and `events.jsonl`. P2P runs also have `mpv.log`. Debrid runs do not write
`mpv.log` by default, because it would contain your private download link.
The tool replaces your key with `<key>` in every file it writes.

## Reading the report

Every criterion is PASS or FAIL. Everything that missed the target is listed
under **Shortfalls**, including:

- startup slower than 60 s;
- any Sinhala pause;
- any cue shown in English or with no subtitle;
- any rate-limited request.

The report also shows where the startup time went: source ready, first
English cue, first Sinhala cue, when mpv itself was ready, and when playback
started.

## Useful options

| Option | Default | Meaning |
| --- | --- | --- |
| `--model` | `gemini-3.1-flash-lite` | Model id; must be available to your key |
| `--thinking` | `minimal` | `omit` if the model rejects thinking settings |
| `--concurrency` | 2 | Parallel requests (lower it if you see rate limits) |
| `--first-batch` / `--batch` | 12 / 30 | Cues per request |
| `--floor` | 60 | Seconds that must be Sinhala before playback starts |
| `--start` | 0 | Start position in seconds (tests resuming mid-episode) |
| `--seek-plan` | auto | `none`, or `wallSec:targetSec,…` (`auto` as target picks an untranslated spot) |
| `--no-player` | off | Measure extraction and translation only |
