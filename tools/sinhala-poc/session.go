package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Session struct {
	cfg     Config
	ev      *EventLog
	m       *Metrics
	store   *Store
	ex      *Extractor
	tr      *Translator
	probe   *probeResult
	t0      time.Time
	startMs int64
	p2p     *p2pSource
	srtPath string

	mpv        *Mpv
	mpvCmd     *exec.Cmd
	loaded     map[string]bool
	loadedN    int
	ourSid     int
	lastReload time.Time
	quotaDone  bool
}

// ---------------------------------------------------------------------------
// Start gate

type gateState struct {
	OK           bool
	FrontSec     float64
	FloorReady   bool
	Successes    int
	Capacity     float64
	CueRate      float64
	ExtractRate  float64
	Complete     bool
	Bottleneck   string
	ReadyAheadS  float64
	TranslatedAh int
}

func (s *Session) evalGate(posMs int64) gateState {
	g := gateState{}
	front, complete, ok := s.ex.FrontFor(posMs)
	if !ok {
		front = posMs
	}
	g.Complete = complete
	g.FrontSec = float64(front-posMs) / 1000
	floorEnd := posMs + int64(s.cfg.FloorSec*1000)
	extractedFloor := complete || front >= floorEnd
	g.FloorReady = extractedFloor && s.store.AllReadyBetween(posMs, floorEnd)
	cap, succ := s.tr.Capacity()
	g.Capacity, g.Successes = cap, succ
	rateTo := front
	if rateTo-posMs < 30_000 {
		rateTo = posMs + 30_000
	}
	g.CueRate = s.store.CueRate(posMs, rateTo)
	g.ExtractRate = s.ex.Rate()
	nr, has := s.store.FirstNotReadyFrom(posMs)
	lead := front
	if has && nr.StartMs < lead {
		lead = nr.StartMs
	}
	if complete && !has {
		lead = math.MaxInt64 / 2
	}
	g.ReadyAheadS = float64(lead-posMs) / 1000

	// If every extracted cue ahead is already Sinhala (e.g. resumed from the
	// journal), translation is not the constraint; extraction speed is.
	translationAhead := has && nr.StartMs < front
	switch {
	case !extractedFloor:
		g.Bottleneck = "extraction (English not yet extracted for the floor)"
	case !g.FloorReady:
		g.Bottleneck = "translation (floor not yet translated)"
	case translationAhead && succ < 2:
		g.Bottleneck = "measurement (fewer than 2 completed requests)"
	case translationAhead && g.CueRate > 0 && cap < s.cfg.CapacityRatio*g.CueRate:
		g.Bottleneck = fmt.Sprintf("translation capacity %.2f cues/s < %.1f × %.2f", cap, s.cfg.CapacityRatio, g.CueRate)
	case !complete && g.ExtractRate < s.cfg.ExtractRatio:
		g.Bottleneck = fmt.Sprintf("extraction speed %.2f× < %.2f×", g.ExtractRate, s.cfg.ExtractRatio)
	default:
		g.OK = true
	}
	return g
}

// ---------------------------------------------------------------------------

func (s *Session) Run(ctx context.Context, videoURL string) error {
	if !s.cfg.NoPlayer {
		if err := s.launchMpv(videoURL); err != nil {
			return err
		}
		defer func() {
			if s.mpv != nil {
				s.mpv.Close()
			}
		}()
	}

	// ---- Phase 1: wait for the start gate (player stays paused)
	fmt.Println("Preparing Sinhala…")
	lastPrint := time.Time{}
	var gate gateState
	playerReadyLogged := false
	for {
		if ctx.Err() != nil {
			return fmt.Errorf("cancelled before playback")
		}
		if stopped, why := s.tr.Stopped(); stopped {
			s.m.TranslatorStop = string(why)
			if why == ClassDailyQuota {
				s.applyQuotaFallback()
			} else {
				return fmt.Errorf("translation stopped before playback: %s (%s)", why, s.tr.stats.AuthError+s.tr.stats.ConfigError)
			}
		}
		if s.mpv != nil && !playerReadyLogged && s.playerReady() {
			s.m.PlayerReady = time.Since(s.t0)
			playerReadyLogged = true
			s.ev.Log("player-ready", nil)
		}
		gate = s.evalGate(s.startMs)
		if s.m.FirstCue == 0 {
			if total, _, _, _ := s.store.Counts(); total > 0 {
				s.m.FirstCue = time.Since(s.t0)
			}
		}
		if s.m.FirstSinhala == 0 {
			if _, tr, _, _ := s.store.Counts(); tr > 0 {
				s.m.FirstSinhala = time.Since(s.t0)
			}
		}
		if gate.Bottleneck != "" {
			s.m.GateLastBottleneck = gate.Bottleneck
		}
		if gate.OK || s.quotaDone {
			break
		}
		if time.Since(s.t0).Seconds() > s.cfg.MaxWaitSec {
			s.m.GateTimedOut = true
			break
		}
		if time.Since(lastPrint) > 2*time.Second {
			lastPrint = time.Now()
			fmt.Printf("  %5.1fs  English ahead %5.0fs  Sinhala ready ahead %5.0fs  capacity %.2f cues/s vs need %.2f  extract %.1f×  ⟶ waiting on: %s\n",
				time.Since(s.t0).Seconds(), gate.FrontSec, gate.ReadyAheadS, gate.Capacity, s.cfg.CapacityRatio*gate.CueRate, gate.ExtractRate, gate.Bottleneck)
			if s.p2p != nil {
				s.ev.Log("gate", map[string]any{"gate": gate, "p2p": p2pStats(s.p2p)})
			} else {
				s.ev.Log("gate", gate)
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	s.m.GateAtStart = gate
	if s.mpv != nil && !playerReadyLogged {
		s.m.PlayerReady = time.Since(s.t0)
	}
	s.m.CoverageAtStart = s.coverage(s.startMs)

	if s.cfg.NoPlayer {
		s.m.Play = time.Since(s.t0)
		s.tr.playing.Store(true)
		fmt.Printf("Start gate passed at %.1fs (no player). Continuing extraction/translation for measurement for up to %.0fs…\n", s.m.Play.Seconds(), s.maxPlay())
		deadline := time.Now().Add(time.Duration(s.maxPlay() * float64(time.Second)))
		for time.Now().Before(deadline) && ctx.Err() == nil {
			total, tr, fb, _ := s.store.Counts()
			_, complete, _ := s.ex.FrontFor(s.startMs)
			if complete && tr+fb == total {
				break
			}
			time.Sleep(time.Second)
		}
		return nil
	}

	// ---- Phase 2: attach and play
	if err := s.reload(true); err != nil {
		return fmt.Errorf("attach Sinhala SRT: %w", err)
	}
	s.selectEnglishReference()
	s.m.Play = time.Since(s.t0)
	s.tr.playing.Store(true)
	if err := s.mpv.Set("pause", false); err != nil {
		return err
	}
	s.ev.Log("play", map[string]any{"coverage": s.m.CoverageAtStart, "gate": gate})
	fmt.Printf("▶ Playback started at %.1fs (target %.0fs) • Sinhala ready %.0fs ahead\n", s.m.Play.Seconds(), s.cfg.TargetSec, s.m.CoverageAtStart.ReadyAheadSec)

	return s.playLoop(ctx)
}

func (s *Session) maxPlay() float64 {
	if s.cfg.MaxPlaySec > 0 {
		return s.cfg.MaxPlaySec
	}
	return 4 * 3600
}

func (s *Session) launchMpv(videoURL string) error {
	name := fmt.Sprintf("orvix-sinhala-poc-%d", os.Getpid())
	endpoint := ipcEndpoint(name)
	fontDir := absPath(s.cfg.FontDir)
	args := []string{
		"--input-ipc-server=" + endpoint,
		"--pause=yes",
		fmt.Sprintf("--start=%.3f", s.cfg.StartSec),
		"--sid=no", "--secondary-sid=no",
		"--sub-auto=no",
		"--sub-fonts-dir=" + fontDir,
		"--sub-font=Noto Sans Sinhala",
		"--secondary-sub-visibility=no",
		"--keep-open=yes",
		"--force-window=immediate",
		"--title=Orvix Sinhala PoC",
		"--cache=yes",
	}
	if s.cfg.MpvLog == "yes" || (s.cfg.MpvLog == "auto" && s.cfg.Magnet != "") {
		args = append(args, "--log-file="+absPath(s.cfg.OutDir+"/mpv.log"))
	}
	args = append(args, videoURL)
	cmd := exec.Command(s.cfg.Mpv, args...)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start mpv (%s): %w — install mpv or pass --mpv", s.cfg.Mpv, err)
	}
	s.mpvCmd = cmd
	m, err := ConnectMpv(endpoint, 20*time.Second)
	if err != nil {
		return err
	}
	s.mpv = m
	s.ev.Log("mpv-started", map[string]any{"ipc": endpoint})
	return nil
}

func (s *Session) playerReady() bool {
	d, ok := s.mpv.GetFloat("duration")
	if !ok || d <= 0 {
		return false
	}
	c, ok := s.mpv.GetFloat("demuxer-cache-duration")
	return ok && c >= 2
}

// selectEnglishReference makes the video's own embedded English track the
// hidden secondary subtitle, so the player itself reports both timelines.
func (s *Session) selectEnglishReference() {
	tracks, err := s.mpv.Tracks()
	if err != nil {
		return
	}
	pick := func(t mpvTrack, how string) {
		s.mpv.Set("secondary-sub-visibility", false)
		if err := s.mpv.Set("secondary-sid", t.ID); err == nil {
			s.m.ReferenceTrack = t.ID
			s.ev.Log("reference-track", map[string]any{"mpvId": t.ID, "matchedBy": how})
		}
	}
	for _, t := range tracks {
		if t.Type == "sub" && !t.External && t.FFIndex != nil && *t.FFIndex == s.probe.Chosen.Index {
			pick(t, "ff-index")
			return
		}
	}
	// Fallback: same position among the file's subtitle streams (mpv lists
	// internal tracks in file order; ff-index is not guaranteed for mkv).
	ordinal := 0
	for _, st := range s.probe.Streams {
		if st.Type == "subtitle" {
			if st.Index == s.probe.Chosen.Index {
				break
			}
			ordinal++
		}
	}
	n := 0
	for _, t := range tracks {
		if t.Type == "sub" && !t.External {
			if n == ordinal {
				pick(t, "ordinal")
				return
			}
			n++
		}
	}
	s.ev.Log("reference-track-missing", nil)
}

// reload rewrites the Sinhala SRT and (re)loads it into mpv, keeping it selected.
func (s *Session) reload(first bool) error {
	written, n, err := s.store.WriteSinhalaSRT(s.srtPath)
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("no Sinhala cues to load")
	}
	before, _ := s.mpv.GetString("sub-text")
	if first || s.ourSid == 0 {
		if _, err := s.mpv.Command("sub-add", s.srtPath, "select", "AI Sinhala (PoC)", "si"); err != nil {
			return err
		}
	} else {
		if _, err := s.mpv.Command("sub-reload", s.ourSid); err != nil {
			s.ev.Log("sub-reload-error", map[string]any{"error": err.Error()})
			if _, err := s.mpv.Command("sub-add", s.srtPath, "select", "AI Sinhala (PoC)", "si"); err != nil {
				return err
			}
		}
	}
	// Confirm our file is the selected primary track (sub-reload re-adds it).
	ok := false
	for i := 0; i < 20 && !ok; i++ {
		tracks, _ := s.mpv.Tracks()
		for _, t := range tracks {
			if t.Type == "sub" && t.External && sameFile(t.ExternalFilename, s.srtPath) {
				s.ourSid = t.ID
				if !t.Selected || (t.MainSelection != nil && *t.MainSelection != 0) {
					s.mpv.Set("sid", t.ID)
				} else {
					ok = true
				}
			}
		}
		if !ok {
			time.Sleep(50 * time.Millisecond)
		}
	}
	after, _ := s.mpv.GetString("sub-text")
	s.loaded = written
	s.loadedN = n
	s.lastReload = time.Now()
	s.m.Reloads++
	if !first && before != "" && before != after {
		s.m.VisibleChangedByReload++
	}
	s.ev.Log("reload", map[string]any{"cues": n, "selected": ok, "sid": s.ourSid})
	if !ok {
		s.m.ReloadSelectFailures++
	}
	return nil
}

// leadMs is how far ahead of posMs the LOADED Sinhala file (plus permanent
// English fallbacks) covers without a gap.
func (s *Session) leadMs(posMs int64) (lead int64, cause string) {
	front, complete, ok := s.ex.FrontFor(posMs)
	if !ok {
		return 0, "extraction-not-at-position"
	}
	snap := s.store.Snapshot()
	i := sort.Search(len(snap), func(i int) bool { return snap[i].StartMs >= posMs })
	for ; i < len(snap); i++ {
		c := snap[i]
		if !s.loaded[c.Key] {
			if c.Status == StatusTranslated || c.Status == StatusFallback {
				return c.StartMs - posMs, "loaded-file-behind"
			}
			if c.StartMs < front {
				st := "translation-behind"
				if stop, why := s.tr.Stopped(); stop {
					st = "translator-stopped-" + string(why)
				}
				return c.StartMs - posMs, st
			}
			break
		}
	}
	if complete {
		return math.MaxInt64 / 4, ""
	}
	return front - posMs, "extraction-behind"
}

type coverage struct {
	TranslatedAhead int     `json:"translatedAhead"`
	ReadyAheadSec   float64 `json:"readyAheadSec"`
	EnglishAheadSec float64 `json:"englishAheadSec"`
}

func (s *Session) coverage(posMs int64) coverage {
	c := coverage{}
	front, complete, ok := s.ex.FrontFor(posMs)
	if ok {
		c.EnglishAheadSec = float64(front-posMs) / 1000
		if complete {
			c.EnglishAheadSec = float64(s.probe.DurationMs-posMs) / 1000
		}
	}
	for _, cue := range s.store.Snapshot() {
		if cue.StartMs >= posMs && cue.Status == StatusTranslated {
			c.TranslatedAhead++
		}
	}
	nr, has := s.store.FirstNotReadyFrom(posMs)
	lead := int64(c.EnglishAheadSec * 1000)
	if has && nr.StartMs-posMs < lead {
		lead = nr.StartMs - posMs
	}
	c.ReadyAheadSec = float64(lead) / 1000
	return c
}

func (s *Session) applyQuotaFallback() {
	if s.quotaDone {
		return
	}
	s.quotaDone = true
	n := s.store.FallbackAllPending("daily-quota")
	s.m.QuotaFallbackCues += n
	s.ev.Log("daily-quota-fallback", map[string]any{"cues": n})
	fmt.Println("⚠ Gemini daily quota exhausted: remaining cues will show in English (counted as shortfalls).")
}

// ---------------------------------------------------------------------------
// Playback loop

type seekRec struct {
	At           time.Time `json:"-"`
	WallSec      float64   `json:"wallSec"`
	FromSec      float64   `json:"fromSec"`
	ToSec        float64   `json:"toSec"`
	Scripted     bool      `json:"scripted"`
	Untranslated bool      `json:"untranslatedAtSeek"`
	Paused       bool      `json:"pausedForSinhala"`
	ReadySec     float64   `json:"sinhalaAvailableAfterSec"` // -1 = never
	done         bool
}

type pauseRec struct {
	WallSec   float64 `json:"wallSec"`
	PosSec    float64 `json:"posSec"`
	Cause     string  `json:"cause"`
	DurSec    float64 `json:"durationSec"`
	AfterSeek bool    `json:"afterSeek"`
	start     time.Time
}

func (s *Session) playLoop(ctx context.Context) error {
	plan := s.seekPlan()
	planIdx := 0
	playStart := time.Now()
	var lastPos float64 = float64(s.startMs) / 1000
	lastTick := time.Now()
	lastWasPaused := false
	var ourPause *pauseRec
	var pendingSeek *seekRec
	var lastSecStart float64 = -1
	lastStatus := time.Time{}
	extractFail := time.Time{}

	startPos := float64(s.startMs) / 1000
	for {
		if ctx.Err() != nil {
			return nil
		}
		if s.cfg.MaxPlaySec > 0 && time.Since(playStart).Seconds() > s.cfg.MaxPlaySec {
			s.ev.Log("max-play-reached", nil)
			return nil
		}
		pos, ok := s.mpv.GetFloat("time-pos")
		if !ok {
			if !s.mpv.Alive() {
				s.ev.Log("mpv-closed", nil)
				return nil
			}
			time.Sleep(200 * time.Millisecond)
			continue
		}
		paused, _ := s.mpv.GetBool("pause")
		eof, _ := s.mpv.GetBool("eof-reached")
		posMs := int64(pos * 1000)
		s.tr.SetPlayhead(posMs)
		now := time.Now()
		if s.m.FirstMotion == 0 && !paused && pos > startPos+0.3 && pos < startPos+5 {
			// The picture is actually moving: this, not the unpause command,
			// is when the viewer starts watching.
			s.m.FirstMotion = now.Sub(s.t0) - time.Duration((pos-startPos)*float64(time.Second))
			s.ev.Log("first-motion", map[string]any{"sec": s.m.FirstMotion.Seconds()})
		}

		// --- Seek detection (user or scripted)
		expected := lastPos
		if !lastWasPaused {
			expected += now.Sub(lastTick).Seconds()
		}
		if math.Abs(pos-expected) > 3.0 {
			sr := &seekRec{At: now, WallSec: now.Sub(s.t0).Seconds(), FromSec: lastPos, ToSec: pos, ReadySec: -1}
			if planIdx > 0 && plan[planIdx-1].issued && !plan[planIdx-1].matched {
				sr.Scripted = true
				plan[planIdx-1].matched = true
			}
			if nr, has := s.store.FirstNotReadyFrom(posMs); has && nr.StartMs-posMs < int64(s.cfg.PauseLeadSec*1000) {
				sr.Untranslated = true
			} else if _, _, ok := s.ex.FrontFor(posMs); !ok {
				sr.Untranslated = true
			}
			s.onSeek(posMs)
			if pendingSeek != nil && !pendingSeek.done {
				pendingSeek.done = true
			}
			pendingSeek = sr
			s.m.Seeks = append(s.m.Seeks, sr)
			s.ev.Log("seek", sr)
			lastSecStart = -1
		}
		lastPos, lastTick, lastWasPaused = pos, now, paused

		// --- Extractor upkeep
		s.ex.MaybeSkipCovered()
		if _, _, ok := s.ex.FrontFor(posMs); !ok && time.Since(extractFail) > 3*time.Second {
			extractFail = now
			s.ev.Log("extract-restart-not-covered", map[string]any{"posMs": posMs})
			s.ex.StartAtUncovered(maxI64(0, posMs-10_000))
		}
		if stop, why := s.tr.Stopped(); stop && why == ClassDailyQuota {
			s.m.TranslatorStop = string(why)
			if !s.quotaDone {
				s.applyQuotaFallback()
			} else if n := s.store.FallbackAllPending("daily-quota"); n > 0 {
				// Cues extracted after the quota ran out.
				s.m.QuotaFallbackCues += n
			}
		}

		// --- Reload the Sinhala file when new cues are ready, at a safe moment
		lead, cause := s.leadMs(posMs)
		subText, _ := s.mpv.GetString("sub-text")
		dirty := s.dirtyCount() > 0
		urgent := cause == "loaded-file-behind" && lead < 20_000
		safe := subText == "" || paused
		if dirty && safe && (urgent || time.Since(s.lastReload) > 4*time.Second) {
			if err := s.reload(false); err != nil {
				s.ev.Log("reload-error", map[string]any{"error": err.Error()})
			}
			lead, cause = s.leadMs(posMs)
		}

		// --- Pause / resume for Sinhala availability
		if ourPause == nil && !paused && !eof && lead < int64(s.cfg.PauseLeadSec*1000) && !strings.HasPrefix(cause, "translator-stopped") {
			ourPause = &pauseRec{WallSec: now.Sub(s.t0).Seconds(), PosSec: pos, Cause: cause, start: now, AfterSeek: pendingSeek != nil && !pendingSeek.done}
			if pendingSeek != nil && !pendingSeek.done {
				pendingSeek.Paused = true
			}
			s.mpv.Set("pause", true)
			s.mpv.Command("show-text", "Sinhala is catching up…", 60000)
			s.ev.Log("pause", ourPause)
			fmt.Printf("  ⏸ Sinhala pause at %s (%s)\n", fmtClock(pos), cause)
		} else if ourPause != nil {
			if !paused {
				// User resumed manually while we were waiting.
				ourPause.DurSec = now.Sub(ourPause.start).Seconds()
				ourPause.Cause += " (user resumed)"
				s.m.Pauses = append(s.m.Pauses, *ourPause)
				s.ev.Log("pause-end", ourPause)
				ourPause = nil
			} else if lead >= int64(s.cfg.ResumeLeadSec*1000) || eof || strings.HasPrefix(cause, "translator-stopped") {
				ourPause.DurSec = now.Sub(ourPause.start).Seconds()
				s.m.Pauses = append(s.m.Pauses, *ourPause)
				s.ev.Log("pause-end", ourPause)
				s.mpv.Command("show-text", "", 1)
				s.mpv.Set("pause", false)
				fmt.Printf("  ▶ resumed after %.1fs\n", ourPause.DurSec)
				ourPause = nil
			}
		}
		if pendingSeek != nil && !pendingSeek.done && lead >= int64(s.cfg.PauseLeadSec*1000) && ourPause == nil {
			pendingSeek.ReadySec = now.Sub(pendingSeek.At).Seconds()
			pendingSeek.done = true
			s.ev.Log("seek-ready", pendingSeek)
		}

		// --- In-player sync + availability check against the video's own English track
		// (skipped while we hold playback for Sinhala: that wait is reported per seek/pause)
		if !paused && ourPause == nil {
			if secStart, ok := s.mpv.GetFloat("secondary-sub-start"); ok && secStart != lastSecStart {
				lastSecStart = secStart
				s.checkSync(secStart)
			}
		}

		// --- Scripted seeks
		if planIdx < len(plan) && !paused && ourPause == nil && time.Since(playStart).Seconds() >= plan[planIdx].afterSec {
			target := s.pickSeekTarget(plan[planIdx], posMs)
			if target < 0 {
				s.m.SkippedSeeks++
			}
			if target >= 0 {
				plan[planIdx].issued = true
				s.mpv.Command("seek", fmt.Sprintf("%.3f", float64(target)/1000), "absolute")
				s.ev.Log("scripted-seek", map[string]any{"toMs": target})
			}
			planIdx++
		}

		if time.Since(lastStatus) > 30*time.Second {
			lastStatus = now
			total, tr, fb, pend := s.store.Counts()
			capv, _ := s.tr.Capacity()
			fmt.Printf("  %s  Sinhala ahead %s  cues %d/%d (+%d English)  pending %d  capacity %.2f/s  pauses %d\n",
				fmtClock(pos), fmtLead(lead), tr, total, fb, pend, capv, len(s.m.Pauses))
			st := map[string]any{"posSec": pos, "leadMs": lead, "cause": cause, "total": total, "translated": tr, "fallback": fb, "pending": pend, "capacity": capv, "extract": s.ex.Stats(), "extractRate": s.ex.Rate()}
			if s.p2p != nil {
				st["p2p"] = p2pStats(s.p2p)
			}
			s.ev.Log("status", st)
		}

		if eof {
			s.ev.Log("eof", nil)
			if ourPause != nil {
				ourPause.DurSec = now.Sub(ourPause.start).Seconds()
				s.m.Pauses = append(s.m.Pauses, *ourPause)
			}
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func (s *Session) dirtyCount() int {
	n := 0
	for _, c := range s.store.Snapshot() {
		if (c.Status == StatusTranslated || c.Status == StatusFallback) && !s.loaded[c.Key] {
			n++
		}
	}
	return n
}

func (s *Session) onSeek(posMs int64) {
	front, complete, ok := s.ex.FrontFor(posMs)
	switch {
	case !ok:
		s.ex.StartAtUncovered(maxI64(0, posMs-30_000))
	case !complete && front-posMs < 120_000:
		// Covered by an old range that ends soon, or the live segment: if the
		// live segment is elsewhere, continue from the end of this range.
		s.ex.mu.Lock()
		live := s.ex.running && posMs >= s.ex.segFrom-1000 && posMs <= s.ex.front+1000
		s.ex.mu.Unlock()
		if !live {
			s.ex.StartAt(maxI64(0, front-5_000))
		}
	}
}

// checkSync compares what the player shows from our Sinhala file with the
// video's own embedded English cue at the same moment.
func (s *Session) checkSync(secStart float64) {
	priStart, priOK := s.mpv.GetFloat("sub-start")
	secText, _ := s.mpv.GetString("secondary-sub-text")
	s.m.SyncSamples++
	if !priOK {
		// The video is showing an English cue but no Sinhala cue is on screen.
		s.m.MissedCues++
		if len(s.m.MissedExamples) < 20 {
			s.m.MissedExamples = append(s.m.MissedExamples, fmt.Sprintf("%s %q", fmtClock(secStart), truncate(oneLine(secText), 60)))
		}
		s.ev.Log("missed-cue", map[string]any{"secStart": secStart})
		return
	}
	delta := int64(math.Round((priStart - secStart) * 1000))
	if delta < 0 {
		delta = -delta
	}
	if delta > s.m.MaxSyncDeltaMs {
		s.m.MaxSyncDeltaMs = delta
	}
	if delta <= 1 {
		s.m.SyncExact++
	} else {
		s.m.SyncOff++
		if len(s.m.SyncOffExamples) < 20 {
			s.m.SyncOffExamples = append(s.m.SyncOffExamples, fmt.Sprintf("%s Δ%dms", fmtClock(secStart), delta))
		}
	}
	// Was the Sinhala line on screen a translation of this English line?
	want := normalizeForKey(secText)
	for _, c := range s.store.Snapshot() {
		if int64(math.Round(priStart*1000)) == c.StartMs {
			if normalizeForKey(c.English) == want || want == "" {
				s.m.TextMatch++
			} else {
				s.m.TextMismatch++
			}
			if c.Status == StatusFallback {
				s.m.FallbackShown++
			}
			break
		}
	}
}

type seekStep struct {
	afterSec float64
	target   int64 // -1 = auto
	issued   bool
	matched  bool
}

func (s *Session) seekPlan() []*seekStep {
	switch strings.ToLower(s.cfg.SeekPlan) {
	case "none", "":
		return nil
	case "auto":
		return []*seekStep{{afterSec: 300, target: -1}, {afterSec: 600, target: -1}, {afterSec: 900, target: -1}, {afterSec: 1200, target: -1}}
	}
	var out []*seekStep
	for _, part := range strings.Split(s.cfg.SeekPlan, ",") {
		kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
		if len(kv) != 2 {
			continue
		}
		a, err1 := strconv.ParseFloat(kv[0], 64)
		if err1 != nil {
			continue
		}
		if strings.TrimSpace(kv[1]) == "auto" {
			out = append(out, &seekStep{afterSec: a, target: -1})
			continue
		}
		if b, err2 := strconv.ParseFloat(kv[1], 64); err2 == nil {
			out = append(out, &seekStep{afterSec: a, target: int64(b * 1000)})
		}
	}
	return out
}

// pickSeekTarget chooses a position whose Sinhala is NOT ready yet, so every
// automatic seek tests the hard case. Returns -1 if nothing suitable.
func (s *Session) pickSeekTarget(st *seekStep, posMs int64) int64 {
	if st.target >= 0 {
		return st.target
	}
	dur := s.probe.DurationMs
	if dur <= 0 {
		return -1
	}
	limit := dur - 120_000
	// First, any extracted-but-untranslated cue well ahead of the playhead.
	if nr, has := s.store.FirstNotReadyFrom(posMs + 120_000); has && nr.StartMs < limit {
		return nr.StartMs + 2_000
	}
	// Otherwise, beyond everything extracted so far.
	front, complete, ok := s.ex.FrontFor(posMs)
	if ok && !complete && front+180_000 < limit {
		return front + 180_000
	}
	// Otherwise, a region before the start of what we have.
	if s.startMs > 300_000 {
		return s.startMs / 2
	}
	s.ev.Log("seek-target-none", map[string]any{"reason": "no untranslated region left"})
	return -1
}

func fmtClock(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	t := int64(sec)
	return fmt.Sprintf("%d:%02d:%02d", t/3600, (t%3600)/60, t%60)
}

func fmtLead(ms int64) string {
	if ms > 1e12 {
		return "to end"
	}
	return fmt.Sprintf("%.0fs", float64(ms)/1000)
}
