package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Metrics struct {
	t0       time.Time
	SourceID string `json:"sourceId"`
	Mode     string `json:"mode"`

	SourceReady  time.Duration `json:"-"`
	ProbeDone    time.Duration `json:"-"`
	ExtractStart time.Duration `json:"-"`
	FirstCue     time.Duration `json:"-"`
	FirstSinhala time.Duration `json:"-"`
	PlayerReady  time.Duration `json:"-"`
	Play         time.Duration `json:"-"`
	FirstMotion  time.Duration `json:"-"`

	P2PStatsAtStart    map[string]any `json:"p2pStatsAtStart,omitempty"`
	Probe              *probeResult   `json:"-"`
	JournalLoaded      int            `json:"journalLoaded"`
	EnglishCached      int            `json:"englishCuesFromCache"`
	GateAtStart        gateState      `json:"gateAtStart"`
	GateLastBottleneck string         `json:"gateLastBottleneck"`
	GateTimedOut       bool           `json:"gateTimedOut"`
	CoverageAtStart    coverage       `json:"coverageAtStart"`
	TranslatorStop     string         `json:"translatorStop,omitempty"`
	QuotaFallbackCues  int            `json:"quotaFallbackCues"`

	Reloads                int `json:"reloads"`
	ReloadSelectFailures   int `json:"reloadSelectFailures"`
	VisibleChangedByReload int `json:"visibleCueChangedByReload"`
	ReferenceTrack         int `json:"referenceTrackMpvId"`

	SyncSamples     int      `json:"syncSamples"`
	SyncExact       int      `json:"syncExact"`
	SyncOff         int      `json:"syncOff"`
	MaxSyncDeltaMs  int64    `json:"maxSyncDeltaMs"`
	SyncOffExamples []string `json:"syncOffExamples,omitempty"`
	TextMatch       int      `json:"textMatch"`
	TextMismatch    int      `json:"textMismatch"`
	MissedCues      int      `json:"missedCues"`
	MissedExamples  []string `json:"missedExamples,omitempty"`
	FallbackShown   int      `json:"fallbackShown"`

	SkippedSeeks int `json:"skippedSeeksNoUntranslatedLeft"`

	Pauses []pauseRec `json:"pauses"`
	Seeks  []*seekRec `json:"seeks"`
	Abort  string     `json:"abort,omitempty"`
}

func NewMetrics(cfg Config, t0 time.Time) *Metrics {
	return &Metrics{t0: t0, Mode: modeOf(cfg), Pauses: []pauseRec{}, Seeks: []*seekRec{}}
}

func secs(d time.Duration) float64 {
	if d == 0 {
		return -1
	}
	return float64(d.Milliseconds()) / 1000
}

type verdict struct {
	Name   string `json:"name"`
	Pass   bool   `json:"pass"`
	Detail string `json:"detail"`
}

func (m *Metrics) Finish(cfg Config, store *Store, tr *Translator, ex *Extractor, ev *EventLog) error {
	sum := map[string]any{}
	sum["metrics"] = m
	timeline := map[string]float64{
		"sourceReadySec":     secs(m.SourceReady),
		"probeDoneSec":       secs(m.ProbeDone),
		"extractStartSec":    secs(m.ExtractStart),
		"firstEnglishCueSec": secs(m.FirstCue),
		"firstSinhalaCueSec": secs(m.FirstSinhala),
		"playerReadySec":     secs(m.PlayerReady),
		"playbackStartSec":   secs(m.Play),
		"videoMovingSec":     secs(m.FirstMotion),
	}
	sum["timeline"] = timeline

	var verdicts []verdict
	var shortfalls []string
	if m.Abort != "" {
		shortfalls = append(shortfalls, "Run aborted: "+m.Abort)
	}

	// Startup
	startAt := m.Play
	if m.FirstMotion > startAt {
		startAt = m.FirstMotion
	}
	startOK := m.Play > 0 && startAt.Seconds() <= cfg.TargetSec && !m.GateTimedOut && m.GateAtStart.OK
	verdicts = append(verdicts, verdict{"Cold start ≤ target", startOK,
		fmt.Sprintf("video moving with Sinhala at %.1fs (unpaused at %.1fs; target %.0fs); normal player ready at %.1fs; last wait was on: %s", secs(startAt), secs(m.Play), cfg.TargetSec, secs(m.PlayerReady), m.GateLastBottleneck)})
	if !startOK {
		shortfalls = append(shortfalls, fmt.Sprintf("Startup %.1fs exceeds the %.0fs target", secs(startAt), cfg.TargetSec))
	}

	// Pauses during normal playback (not caused by a seek)
	midPauses := 0
	var midDur float64
	for _, p := range m.Pauses {
		if !p.AfterSeek {
			midPauses++
			midDur += p.DurSec
			shortfalls = append(shortfalls, fmt.Sprintf("Translation-related pause at %s for %.1fs (%s)", fmtClock(p.PosSec), p.DurSec, p.Cause))
		}
	}
	verdicts = append(verdicts, verdict{"No Sinhala pauses during playback", midPauses == 0, fmt.Sprintf("%d pauses, %.1fs total (seek-related pauses reported separately)", midPauses, midDur)})

	// Availability
	verdicts = append(verdicts, verdict{"Every cue had Sinhala on screen", m.MissedCues == 0 && m.FallbackShown == 0 && m.SyncSamples > 0,
		fmt.Sprintf("%d checked cues: %d with no subtitle at all, %d shown in English (fallback)", m.SyncSamples, m.MissedCues, m.FallbackShown)})
	if m.MissedCues > 0 {
		shortfalls = append(shortfalls, fmt.Sprintf("%d cues appeared with no Sinhala on screen", m.MissedCues))
	}

	// Fallbacks
	fallbacks := 0
	reasons := map[string]int{}
	if store != nil {
		for _, c := range store.Snapshot() {
			if c.Status == StatusFallback {
				fallbacks++
				r := c.LastErr
				if i := strings.Index(r, ":"); i > 0 {
					r = r[:i]
				}
				reasons[r]++
			}
		}
	}
	verdicts = append(verdicts, verdict{"No English fallback", fallbacks == 0,
		fmt.Sprintf("%d cues fell back to English, by reason %v; %d were shown during playback", fallbacks, reasons, m.FallbackShown)})
	if fallbacks > 0 {
		shortfalls = append(shortfalls, fmt.Sprintf("%d cues fell back to English", fallbacks))
	}

	// Sync
	syncOK := m.SyncSamples > 0 && m.SyncOff == 0 && m.TextMismatch == 0
	if m.SyncSamples == 0 {
		shortfalls = append(shortfalls, "In-player sync was not measured: mpv reported no reference cues (needs a recent mpv and an embedded text track)")
	}
	verdicts = append(verdicts, verdict{"Sinhala cue times match the video's own English cues (in player)", syncOK,
		fmt.Sprintf("%d samples, %d exact (≤1 ms), %d off, max Δ %d ms, text mismatches %d", m.SyncSamples, m.SyncExact, m.SyncOff, m.MaxSyncDeltaMs, m.TextMismatch)})
	if store != nil {
		path := filepath.Join(cfg.OutDir, "sinhala.srt")
		if _, err := os.Stat(path); err == nil {
			n, mism, err := VerifySRTAgainstStore(path, store)
			ok := err == nil && len(mism) == 0
			d := fmt.Sprintf("%d cues re-parsed, %d mismatches", n, len(mism))
			if len(mism) > 0 {
				d += ": " + strings.Join(mism[:minInt(5, len(mism))], "; ")
			}
			verdicts = append(verdicts, verdict{"Final SRT timeline equals extracted English timeline (file)", ok, d})
		}
	}

	// Seeks
	seekOK := true
	var seekLines []string
	for _, sk := range m.Seeks {
		line := fmt.Sprintf("%s → %s (untranslated: %v, paused: %v, Sinhala after %.1fs)", fmtClock(sk.FromSec), fmtClock(sk.ToSec), sk.Untranslated, sk.Paused, sk.ReadySec)
		if sk.ReadySec < 0 {
			line = fmt.Sprintf("%s → %s (untranslated: %v, Sinhala never became available before the next seek/end)", fmtClock(sk.FromSec), fmtClock(sk.ToSec), sk.Untranslated)
			seekOK = false
		}
		seekLines = append(seekLines, line)
		if sk.Paused {
			shortfalls = append(shortfalls, fmt.Sprintf("Seek to %s waited %.1fs for Sinhala", fmtClock(sk.ToSec), sk.ReadySec))
		}
	}
	if m.SkippedSeeks > 0 {
		seekLines = append(seekLines, fmt.Sprintf("%d planned seeks skipped: no untranslated region left", m.SkippedSeeks))
	}
	if len(m.Seeks) == 0 {
		seekLines = append(seekLines, "no seeks were performed, so this was not tested")
	}
	verdicts = append(verdicts, verdict{"Sinhala available after every seek", seekOK && len(m.Seeks) > 0, strings.Join(seekLines, "; ")})

	// Translation
	if tr != nil {
		st := tr.stats
		st.mu.Lock()
		calls := st.Calls
		classes := map[ErrClass]int{}
		var lats []float64
		var rates []float64
		var pt, ot, tt, cueSum int
		for _, c := range calls {
			classes[c.Class]++
			if c.Class == ClassOK {
				lats = append(lats, float64(c.LatencyMs)/1000)
				rates = append(rates, float64(c.Cues)/(float64(c.LatencyMs)/1000+1e-9))
				cueSum += c.Cues
			}
			pt += c.PromptTokens
			ot += c.OutTokens
			tt += c.ThinkTokens
		}
		sort.Float64s(lats)
		sort.Float64s(rates)
		capv, _ := tr.Capacity()
		hosts := []string{}
		tr.g.HostsSeen.Range(func(k, _ any) bool { hosts = append(hosts, k.(string)); return true })
		sum["translation"] = map[string]any{
			"requests": len(calls), "classes": classes, "acceptedCues": st.Accepted, "rejectedByReason": st.Rejected,
			"fallbacks": st.Fallbacks, "latencySec": pct(lats), "cuesPerSecPerRequest": pct(rates), "capacityCuesPerSec": capv,
			"promptTokens": pt, "outputTokens": ot, "thinkingTokens": tt, "cuesRequested": cueSum,
			"hostsContacted": hosts, "keySource": "environment variable ORVIX_POC_GEMINI_KEY",
			"reRequestedAlreadyAccepted": st.ReRequested, "dailyQuotaAt": st.DailyQuotaAt, "authError": st.AuthError, "configError": st.ConfigError,
		}
		byokOK := len(hosts) <= 1 && (len(hosts) == 0 || strings.Contains(cfg.Endpoint, hosts[0]))
		verdicts = append(verdicts, verdict{"Only the user's key, sent only to the configured Gemini endpoint", byokOK && st.AuthError == "",
			fmt.Sprintf("hosts contacted: %v; requests: %d; auth errors: %q", hosts, len(calls), st.AuthError)})
		verdicts = append(verdicts, verdict{"Resume: no already-accepted cue requested again", st.ReRequested == 0,
			fmt.Sprintf("%d cues loaded from journal at start; %d re-requested", m.JournalLoaded, st.ReRequested)})
		if classes[ClassRateLimit] > 0 {
			shortfalls = append(shortfalls, fmt.Sprintf("%d rate-limited requests", classes[ClassRateLimit]))
		}
		st.mu.Unlock()
	}
	if ex != nil {
		sum["extraction"] = ex.Stats()
	}
	if store != nil {
		total, trd, fb, pend := store.Counts()
		sum["cues"] = map[string]int{"extracted": total, "translated": trd, "fallbackEnglish": fb, "notTranslated": pend}
	}
	sum["verdicts"] = verdicts
	sum["shortfalls"] = shortfalls
	allPass := m.Abort == ""
	for _, v := range verdicts {
		allPass = allPass && v.Pass
	}
	sum["runMeetsTarget"] = allPass

	b, _ := json.MarshalIndent(sum, "", "  ")
	os.WriteFile(filepath.Join(cfg.OutDir, "summary.json"), []byte(redact(string(b), os.Getenv("ORVIX_POC_GEMINI_KEY"))), 0o644)
	report := m.markdown(cfg, timeline, verdicts, shortfalls, sum, allPass)
	os.WriteFile(filepath.Join(cfg.OutDir, "report.md"), []byte(report), 0o644)
	fmt.Println()
	fmt.Println(report)
	ev.Log("finish", map[string]any{"runMeetsTarget": allPass})
	return nil
}

func pct(v []float64) map[string]float64 {
	if len(v) == 0 {
		return nil
	}
	at := func(p float64) float64 { return v[int(p*float64(len(v)-1))] }
	return map[string]float64{"min": v[0], "p25": at(0.25), "median": at(0.5), "p75": at(0.75), "max": v[len(v)-1]}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (m *Metrics) markdown(cfg Config, tl map[string]float64, vs []verdict, sf []string, sum map[string]any, all bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Orvix Sinhala PoC run — %s\n\n", m.t0.Format("2006-01-02 15:04"))
	fmt.Fprintf(&b, "Mode: %s • source id: %s • model: %s\n\n", m.Mode, m.SourceID, cfg.Model)
	if all {
		b.WriteString("**Result: this run met every criterion.**\n\n")
	} else {
		b.WriteString("**Result: this run did NOT meet every criterion.**\n\n")
	}
	b.WriteString("## Verdicts\n\n| Criterion | Pass | Detail |\n| --- | --- | --- |\n")
	for _, v := range vs {
		p := "FAIL"
		if v.Pass {
			p = "PASS"
		}
		fmt.Fprintf(&b, "| %s | %s | %s |\n", v.Name, p, strings.ReplaceAll(v.Detail, "|", "/"))
	}
	b.WriteString("\n## Startup timeline (seconds from start)\n\n")
	keys := []string{"sourceReadySec", "probeDoneSec", "extractStartSec", "firstEnglishCueSec", "firstSinhalaCueSec", "playerReadySec", "playbackStartSec", "videoMovingSec"}
	for _, k := range keys {
		fmt.Fprintf(&b, "- %s: %.1f\n", k, tl[k])
	}
	fmt.Fprintf(&b, "- coverage at start: %d Sinhala cues ahead, ready %.0fs ahead, English extracted %.0fs ahead\n", m.CoverageAtStart.TranslatedAhead, m.CoverageAtStart.ReadyAheadSec, m.CoverageAtStart.EnglishAheadSec)
	if m.Probe != nil {
		fmt.Fprintf(&b, "- container start time correction: %d ms\n", m.Probe.StartTimeMs)
	}
	if t, ok := sum["translation"].(map[string]any); ok {
		b.WriteString("\n## Translation\n\n")
		for _, k := range []string{"requests", "classes", "acceptedCues", "rejectedByReason", "latencySec", "cuesPerSecPerRequest", "capacityCuesPerSec", "outputTokens", "thinkingTokens", "hostsContacted", "reRequestedAlreadyAccepted"} {
			js, _ := json.Marshal(t[k])
			fmt.Fprintf(&b, "- %s: %s\n", k, js)
		}
	}
	b.WriteString("\n## Shortfalls against the target\n\n")
	if len(sf) == 0 {
		b.WriteString("None.\n")
	}
	for _, s := range sf {
		fmt.Fprintf(&b, "- %s\n", s)
	}
	b.WriteString("\nFull data: summary.json, events.jsonl, mpv.log, sinhala.srt\n")
	return b.String()
}
