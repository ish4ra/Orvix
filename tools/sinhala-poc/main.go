// sinhala-poc is an isolated Windows proof of concept for Orvix AI Sinhala
// subtitles. It does not touch the Orvix app. It:
//
//   - extracts the embedded English text subtitle progressively from the
//     playhead (ffmpeg), keeping original timestamps on mpv's timeline;
//   - translates text only, with the user's own Gemini key, sent directly to
//     Google (no Orvix backend, no developer key);
//   - persists every accepted cue so retries/restarts resume;
//   - writes a Sinhala SRT whose times are copied from the English cues and
//     loads it into mpv (the same timing principle as the old Windows path);
//   - decides when playback may start, pauses only when Sinhala is genuinely
//     not ready, and measures everything.
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type Config struct {
	URL           string
	Magnet        string
	FileIdx       int
	FileHint      string
	SourceID      string
	Title         string
	SubStream     int
	StartSec      float64
	OrvixDir      string
	FFmpeg        string
	FFprobe       string
	Mpv           string
	FontDir       string
	OutDir        string
	JournalDir    string
	Model         string
	Thinking      string
	Endpoint      string
	Concurrency   int
	FirstBatch    int
	Batch         int
	FloorSec      float64
	CapacityRatio float64
	ExtractRatio  float64
	PauseLeadSec  float64
	ResumeLeadSec float64
	MaxWaitSec    float64
	MaxPlaySec    float64
	SeekPlan      string
	TargetSec     float64
	NoPlayer      bool
	MpvLog        string
}

func main() {
	cfg := Config{}
	flag.StringVar(&cfg.URL, "url", "", "debrid/HTTPS video URL (direct file link)")
	flag.StringVar(&cfg.Magnet, "magnet", "", "magnet link or 40-char info hash for Free P2P (uses the Orvix stream server)")
	flag.IntVar(&cfg.FileIdx, "file-idx", -1, "torrent file index (P2P)")
	flag.StringVar(&cfg.FileHint, "file-hint", "", "substring of the episode file name inside the torrent (P2P)")
	flag.StringVar(&cfg.SourceID, "source-id", "", "stable id for this exact file, used for the translation journal (default: derived)")
	flag.StringVar(&cfg.Title, "title", "", "title given to the translator for context, e.g. \"Star Wars: The Clone Wars S02E05\"")
	flag.IntVar(&cfg.SubStream, "sub-stream", -1, "force ffprobe stream index of the English text subtitle")
	flag.Float64Var(&cfg.StartSec, "start", 0, "start position in seconds (simulates resume)")
	flag.StringVar(&cfg.OrvixDir, "orvix-dir", "", "installed Orvix folder (default %LOCALAPPDATA%\\Programs\\Orvix) for ffmpeg and the stream server")
	flag.StringVar(&cfg.FFmpeg, "ffmpeg", "", "ffmpeg path (default: Orvix's bundled one, then PATH)")
	flag.StringVar(&cfg.FFprobe, "ffprobe", "", "ffprobe path (default: Orvix's bundled one, then PATH)")
	flag.StringVar(&cfg.Mpv, "mpv", "mpv", "mpv executable")
	flag.StringVar(&cfg.FontDir, "font-dir", "fonts", "folder with NotoSansSinhala-Regular.ttf")
	flag.StringVar(&cfg.OutDir, "out", "", "run output folder (default: runs/<timestamp>)")
	flag.StringVar(&cfg.JournalDir, "journal-dir", "journals", "folder for persisted translations (shared across runs)")
	flag.StringVar(&cfg.Model, "model", "gemini-3.1-flash-lite", "Gemini model id")
	flag.StringVar(&cfg.Thinking, "thinking", "minimal", "thinkingLevel to send (minimal|low|omit)")
	flag.StringVar(&cfg.Endpoint, "gemini-endpoint", "https://generativelanguage.googleapis.com", "Gemini API base URL (tests only)")
	flag.IntVar(&cfg.Concurrency, "concurrency", 2, "parallel translation requests")
	flag.IntVar(&cfg.FirstBatch, "first-batch", 12, "cues in the first request (small = fast first window)")
	flag.IntVar(&cfg.Batch, "batch", 30, "cues per request after the first")
	flag.Float64Var(&cfg.FloorSec, "floor", 60, "seconds of media that must be fully Sinhala before playback starts")
	flag.Float64Var(&cfg.CapacityRatio, "capacity-ratio", 1.5, "required translation capacity / cue consumption rate")
	flag.Float64Var(&cfg.ExtractRatio, "extract-ratio", 1.25, "required extraction speed / playback speed (unless complete)")
	flag.Float64Var(&cfg.PauseLeadSec, "pause-lead", 8, "pause when ready Sinhala ahead of the playhead drops below this")
	flag.Float64Var(&cfg.ResumeLeadSec, "resume-lead", 30, "resume after a pause once this much is ready ahead")
	flag.Float64Var(&cfg.MaxWaitSec, "max-wait", 600, "give up waiting for the start gate after this many seconds (reported as a fail)")
	flag.Float64Var(&cfg.MaxPlaySec, "max-play", 0, "stop after this many seconds of playback (0 = whole episode)")
	flag.StringVar(&cfg.SeekPlan, "seek-plan", "auto", "auto | none | comma list of wallSec:targetSec (e.g. 300:1500,600:2400)")
	flag.Float64Var(&cfg.TargetSec, "target", 60, "startup target in seconds")
	flag.BoolVar(&cfg.NoPlayer, "no-player", false, "measure extraction and translation only, without mpv (diagnostic)")
	flag.StringVar(&cfg.MpvLog, "mpv-log", "auto", "write mpv.log: auto (P2P only, because debrid links are private), yes, no")
	flag.Parse()

	if err := run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(cfg Config) error {
	key := strings.TrimSpace(os.Getenv("ORVIX_POC_GEMINI_KEY"))
	if key == "" {
		return fmt.Errorf("set ORVIX_POC_GEMINI_KEY to your own Gemini API key; this tool has no other key and never falls back to a server key")
	}
	if (cfg.URL == "") == (cfg.Magnet == "") {
		return fmt.Errorf("pass exactly one of --url (debrid) or --magnet (Free P2P)")
	}
	t0 := time.Now()
	if cfg.OutDir == "" {
		cfg.OutDir = filepath.Join("runs", t0.Format("20060102-150405"))
	}
	if err := os.MkdirAll(cfg.OutDir, 0o755); err != nil {
		return err
	}
	os.MkdirAll(cfg.JournalDir, 0o755)
	ev, err := NewEventLog(filepath.Join(cfg.OutDir, "events.jsonl"), t0, key)
	if err != nil {
		return err
	}
	defer ev.Close()
	m := NewMetrics(cfg, t0)
	ev.Log("start", map[string]any{"mode": modeOf(cfg), "model": cfg.Model, "startSec": cfg.StartSec, "keySource": "env ORVIX_POC_GEMINI_KEY", "endpoint": cfg.Endpoint})
	fmt.Printf("Orvix Sinhala PoC • output: %s\n", cfg.OutDir)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() { <-sig; fmt.Println("\nStopping…"); cancel() }()

	resolveTools(&cfg)

	// 1. Source
	videoURL := cfg.URL
	var p2p *p2pSource
	var serverCmd *exec.Cmd
	if cfg.Magnet != "" {
		if !streamServerAlive() {
			fmt.Println("Starting the Orvix stream server…")
			serverCmd, err = startStreamServer(cfg.OrvixDir, ev)
			if err != nil {
				return fmt.Errorf("Orvix stream server: %w (close Orvix, or pass --orvix-dir)", err)
			}
			defer serverCmd.Process.Kill()
		}
		fmt.Println("Creating the torrent stream…")
		p2p, err = createP2PStream(cfg.Magnet, cfg.FileIdx, cfg.FileHint, ev)
		if err != nil {
			return err
		}
		videoURL = p2p.URL
		m.P2PStatsAtStart = p2pStats(p2p)
		if cfg.SourceID == "" {
			cfg.SourceID = fmt.Sprintf("p2p-%s-%d", p2p.InfoHash, p2p.FileIdx)
		}
	} else if cfg.SourceID == "" {
		cfg.SourceID = deriveSourceID(cfg.URL)
	}
	m.SourceReady = time.Since(t0)
	m.SourceID = cfg.SourceID

	// 2. Probe
	fmt.Println("Probing subtitle tracks…")
	pctx, pcancel := context.WithTimeout(ctx, 120*time.Second)
	probe, err := ffprobe(pctx, cfg.FFprobe, videoURL, cfg.SubStream)
	pcancel()
	m.ProbeDone = time.Since(t0)
	if err != nil {
		m.Abort = "probe failed: " + strings.ReplaceAll(err.Error(), videoURL, "<video-url>")
		return m.Finish(cfg, nil, nil, nil, ev)
	}
	m.Probe = probe
	ev.Log("probe", map[string]any{"startTimeMs": probe.StartTimeMs, "durationMs": probe.DurationMs, "streams": probe.Streams, "chosen": probe.Chosen, "reason": probe.Reason})
	if probe.Chosen == nil {
		m.Abort = "no usable English text subtitle: " + probe.Reason
		return m.Finish(cfg, nil, nil, nil, ev)
	}
	fmt.Printf("English text track: stream %d (%s, %s) • container start time %d ms\n", probe.Chosen.Index, probe.Chosen.Codec, probe.Chosen.Language, probe.StartTimeMs)

	// 3. Journal, store, extractor, translator
	jpath := filepath.Join(cfg.JournalDir, sanitize(fmt.Sprintf("%s-s%d-%s", cfg.SourceID, probe.Chosen.Index, cfg.Model))+".jsonl")
	journal, err := OpenJournal(jpath, cfg.Model, promptVersion)
	if err != nil {
		return err
	}
	defer journal.Close()
	m.JournalLoaded = journal.Loaded
	if journal.Loaded > 0 {
		fmt.Printf("Resuming: %d translated cues loaded from %s\n", journal.Loaded, jpath)
	}
	store := NewStore(journal)
	startMs := int64(cfg.StartSec * 1000)
	ecache, cachedCues, cachedCov, err := OpenEnglishCache(strings.TrimSuffix(jpath, ".jsonl") + "-english.jsonl")
	if err != nil {
		return err
	}
	defer ecache.Close()
	for _, rc := range cachedCues {
		store.Add(rc)
	}
	m.EnglishCached = len(cachedCues)
	extractor := NewExtractor(cfg.FFmpeg, videoURL, probe.Chosen.Index, probe.StartTimeMs, probe.DurationMs, store, ev)
	extractor.cache = ecache
	extractor.Preload(cachedCov)
	m.ExtractStart = time.Since(t0)
	extractor.StartAtUncovered(maxI64(0, startMs-30_000))

	g := &GeminiClient{Endpoint: cfg.Endpoint, Model: cfg.Model, Key: key, Thinking: cfg.Thinking, Title: cfg.Title,
		HTTP: &http.Client{Timeout: 100 * time.Second}}
	tr := NewTranslator(g, store, journal, ev, cfg.Concurrency, cfg.FirstBatch, cfg.Batch)
	tr.SetPlayhead(startMs)
	tr.prestartMs = int64(cfg.FloorSec*1000) + 15_000
	tr.floorExtracted = func() bool {
		f, complete, ok := extractor.FrontFor(startMs)
		return complete || (ok && f >= startMs+int64(cfg.FloorSec*1000))
	}
	tr.extractIdle = func() bool {
		f, complete, ok := extractor.FrontFor(tr.playhead.Load())
		return complete || (ok && extractor.Rate() < 0.5 && f > 0)
	}
	go tr.Run(ctx)

	s := &Session{cfg: cfg, ev: ev, m: m, store: store, ex: extractor, tr: tr, probe: probe, t0: t0, startMs: startMs, p2p: p2p,
		srtPath: absPath(filepath.Join(cfg.OutDir, "sinhala.srt"))}
	err = s.Run(ctx, videoURL)
	extractor.Stop()
	cancel()
	if err != nil {
		m.Abort = err.Error()
	}
	return m.Finish(cfg, store, tr, extractor, ev)
}

func modeOf(c Config) string {
	if c.Magnet != "" {
		return "free-p2p"
	}
	return "debrid"
}

func resolveTools(cfg *Config) {
	if cfg.OrvixDir == "" {
		cfg.OrvixDir = filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "Orvix")
	}
	find := func(flagVal, name string) string {
		if flagVal != "" {
			return flagVal
		}
		bundled := filepath.Join(cfg.OrvixDir, "tools", "ffmpeg", "bin", name+exeSuffix)
		if _, err := os.Stat(bundled); err == nil {
			return bundled
		}
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
		return name
	}
	cfg.FFmpeg = find(cfg.FFmpeg, "ffmpeg")
	cfg.FFprobe = find(cfg.FFprobe, "ffprobe")
}

var unsafeRe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func sanitize(s string) string {
	s = unsafeRe.ReplaceAllString(s, "_")
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

func deriveSourceID(u string) string {
	// Signed debrid URLs change their query string; the path is more stable.
	if i := strings.Index(u, "?"); i >= 0 {
		u = u[:i]
	}
	return "url-" + sanitize(strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://"))
}

func absPath(p string) string {
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}
