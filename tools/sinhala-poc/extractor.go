package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type probeResult struct {
	StartTimeMs int64 // format start_time; mpv rebases playback by this
	DurationMs  int64
	Streams     []probeStream
	Chosen      *probeStream
	Reason      string
}

type probeStream struct {
	Index    int    `json:"index"`
	Type     string `json:"codec_type"`
	Codec    string `json:"codec_name"`
	Language string
	Title    string
	Forced   bool
	HI       bool
}

var bitmapCodecs = map[string]bool{
	"hdmv_pgs_subtitle": true, "pgssub": true, "dvd_subtitle": true,
	"dvb_subtitle": true, "dvb_teletext": true, "xsub": true,
}

func ffprobe(ctx context.Context, ffprobePath, url string, override int) (*probeResult, error) {
	args := []string{"-v", "error", "-rw_timeout", "30000000",
		"-show_entries", "format=start_time,duration:stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
		"-of", "json", url}
	cmd := exec.CommandContext(ctx, ffprobePath, args...)
	hideWindow(cmd)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, fmt.Errorf("ffprobe failed: %v: %s", err, strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, fmt.Errorf("ffprobe failed: %w", err)
	}
	var raw struct {
		Format struct {
			StartTime string `json:"start_time"`
			Duration  string `json:"duration"`
		} `json:"format"`
		Streams []struct {
			Index       int               `json:"index"`
			CodecType   string            `json:"codec_type"`
			CodecName   string            `json:"codec_name"`
			Tags        map[string]string `json:"tags"`
			Disposition map[string]int    `json:"disposition"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("ffprobe JSON: %w", err)
	}
	pr := &probeResult{}
	if v, err := strconv.ParseFloat(raw.Format.StartTime, 64); err == nil {
		pr.StartTimeMs = int64(v*1000 + sign(v)*0.5)
	}
	if v, err := strconv.ParseFloat(raw.Format.Duration, 64); err == nil {
		pr.DurationMs = int64(v * 1000)
	}
	for _, s := range raw.Streams {
		ps := probeStream{Index: s.Index, Type: s.CodecType, Codec: strings.ToLower(s.CodecName)}
		for k, v := range s.Tags {
			switch strings.ToLower(k) {
			case "language":
				ps.Language = strings.ToLower(strings.TrimSpace(v))
			case "title":
				ps.Title = strings.TrimSpace(v)
			}
		}
		ps.Forced = s.Disposition["forced"] != 0
		ps.HI = s.Disposition["hearing_impaired"] != 0
		pr.Streams = append(pr.Streams, ps)
	}
	pr.Chosen, pr.Reason = chooseEnglishText(pr.Streams, override)
	return pr, nil
}

func sign(v float64) float64 {
	if v < 0 {
		return -1
	}
	return 1
}

func chooseEnglishText(streams []probeStream, override int) (*probeStream, string) {
	var subs []probeStream
	for _, s := range streams {
		if s.Type == "subtitle" {
			subs = append(subs, s)
		}
	}
	if override >= 0 {
		for i := range subs {
			if subs[i].Index == override {
				if bitmapCodecs[subs[i].Codec] {
					return nil, fmt.Sprintf("stream %d is an image subtitle (%s); it has no text to translate", override, subs[i].Codec)
				}
				return &subs[i], "selected by --sub-stream"
			}
		}
		return nil, fmt.Sprintf("--sub-stream %d is not a subtitle stream", override)
	}
	if len(subs) == 0 {
		return nil, "the file has no embedded subtitle streams"
	}
	type scored struct {
		s     probeStream
		score int
	}
	var cands []scored
	bitmapEnglish := false
	for _, s := range subs {
		lang := s.Language
		title := strings.ToLower(s.Title)
		eng := lang == "eng" || lang == "en" || strings.HasPrefix(lang, "en-") || strings.Contains(title, "english")
		if bitmapCodecs[s.Codec] {
			if eng {
				bitmapEnglish = true
			}
			continue
		}
		score := 0
		if eng {
			score += 100
		}
		if lang == "" || lang == "und" {
			score += 10
		}
		if s.Forced || strings.Contains(title, "forced") || strings.Contains(title, "signs") {
			score -= 200
		}
		if strings.Contains(title, "commentary") {
			score -= 200
		}
		if s.HI || strings.Contains(title, "sdh") {
			score -= 5 // usable, but prefer plain dialogue
		}
		if score > 0 {
			cands = append(cands, scored{s, score})
		}
	}
	if len(cands) == 0 {
		if bitmapEnglish {
			return nil, "only image-based (PGS/VobSub) English subtitles are embedded; no text to translate"
		}
		return nil, "no English text subtitle stream found"
	}
	sort.SliceStable(cands, func(i, j int) bool { return cands[i].score > cands[j].score })
	c := cands[0].s
	return &c, "best English text stream"
}

// ---------------------------------------------------------------------------

type interval struct{ From, To int64 }

// Extractor runs ffmpeg from an offset and feeds cues into the store as they
// are demuxed. Timestamps: ffmpeg -copyts outputs container pts; mpv rebases
// the main file by -start_time but does NOT rebase external subtitle files,
// so we subtract the container start time to land on mpv's timeline.
type Extractor struct {
	ffmpeg      string
	url         string
	streamIndex int
	startTimeMs int64
	durationMs  int64
	store       *Store
	ev          *EventLog

	mu        sync.Mutex
	covered   []interval // merged media ranges fully extracted
	segFrom   int64
	front     int64
	done      bool // reached end of file at least once from segFrom
	cancel    context.CancelFunc
	running   bool
	gen       int
	rateWin   []ratePoint
	firstCue  time.Time
	segments  int
	lastError string
	cache     *EnglishCache
	lastCov   time.Time
}

// Preload restores ranges extracted in earlier runs.
func (x *Extractor) Preload(cov []interval) {
	x.mu.Lock()
	defer x.mu.Unlock()
	for _, iv := range cov {
		x.covered = mergeInterval(x.covered, iv)
	}
}

// StartAtUncovered starts extraction at fromMs, or at the end of an already
// covered range containing it.
func (x *Extractor) StartAtUncovered(fromMs int64) {
	x.mu.Lock()
	start := fromMs
	for _, iv := range x.covered {
		if fromMs >= iv.From && fromMs < iv.To {
			start = iv.To - 5_000
		}
	}
	complete := x.durationMs > 0 && start+5_000 >= x.durationMs
	x.mu.Unlock()
	if complete {
		x.ev.Log("extract-skip-cached", map[string]any{"fromMs": fromMs})
		return
	}
	x.StartAt(start)
}

type ratePoint struct {
	at    time.Time
	front int64
}

func NewExtractor(ffmpegPath, url string, stream int, startTimeMs, durationMs int64, store *Store, ev *EventLog) *Extractor {
	return &Extractor{ffmpeg: ffmpegPath, url: url, streamIndex: stream, startTimeMs: startTimeMs, durationMs: durationMs, store: store, ev: ev}
}

// StartAt (re)starts extraction at media position fromMs (playback timeline).
func (x *Extractor) StartAt(fromMs int64) {
	x.mu.Lock()
	if x.cancel != nil {
		x.cancel()
	}
	x.closeSegmentLocked()
	if fromMs < 0 {
		fromMs = 0
	}
	ctx, cancel := context.WithCancel(context.Background())
	x.cancel = cancel
	x.gen++
	gen := x.gen
	x.segFrom = fromMs
	x.front = fromMs
	x.running = true
	x.segments++
	x.rateWin = []ratePoint{{time.Now(), fromMs}}
	x.mu.Unlock()
	x.ev.Log("extract-start", map[string]any{"fromMs": fromMs, "segment": x.segments})
	go x.run(ctx, gen, fromMs)
}

func (x *Extractor) closeSegmentLocked() {
	if x.running && x.front > x.segFrom {
		iv := interval{x.segFrom, x.front}
		x.covered = mergeInterval(x.covered, iv)
		x.cache.Covered(iv)
	}
	x.running = false
}

func mergeInterval(list []interval, iv interval) []interval {
	list = append(list, iv)
	sort.Slice(list, func(i, j int) bool { return list[i].From < list[j].From })
	out := []interval{}
	for _, v := range list {
		if len(out) > 0 && v.From <= out[len(out)-1].To {
			if v.To > out[len(out)-1].To {
				out[len(out)-1].To = v.To
			}
			continue
		}
		out = append(out, v)
	}
	return out
}

func (x *Extractor) run(ctx context.Context, gen int, fromMs int64) {
	// Seek in container time: playback time + start time.
	ssSec := float64(fromMs+x.startTimeMs) / 1000
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin", "-rw_timeout", "30000000"}
	if fromMs > 0 {
		args = append(args, "-ss", fmt.Sprintf("%.3f", ssSec))
	}
	args = append(args, "-copyts", "-i", x.url,
		"-map", fmt.Sprintf("0:%d", x.streamIndex), "-vn", "-an", "-dn",
		"-c:s", "srt", "-flush_packets", "1", "-f", "srt", "pipe:1",
		"-progress", "pipe:2", "-nostats")
	cmd := exec.CommandContext(ctx, x.ffmpeg, args...)
	hideWindow(cmd)
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		x.fail(gen, "ffmpeg start: "+err.Error())
		return
	}
	var wg sync.WaitGroup
	var errTail []string
	wg.Add(1)
	go func() {
		defer wg.Done()
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "out_time_us=") {
				if v, err := strconv.ParseInt(strings.TrimPrefix(line, "out_time_us="), 10, 64); err == nil && v > 0 {
					x.progress(gen, fromMs, v/1000)
				}
				continue
			}
			if strings.Contains(line, "=") && !strings.Contains(line, " ") {
				continue // other -progress keys
			}
			if len(errTail) < 20 {
				errTail = append(errTail, line)
			}
		}
	}()
	err := StreamSRT(stdout, func(rc rawCue) {
		if !x.isGen(gen) {
			return
		}
		rc.StartMs -= x.startTimeMs
		rc.EndMs -= x.startTimeMs
		if x.store.Add(rc) {
			x.cache.Cue(rc)
		}
		x.advance(gen, rc.StartMs)
		x.mu.Lock()
		if x.firstCue.IsZero() {
			x.firstCue = time.Now()
		}
		x.mu.Unlock()
	})
	_ = err
	wg.Wait()
	werr := cmd.Wait()
	if ctx.Err() != nil {
		return // superseded by a newer segment or shutdown
	}
	if werr != nil {
		x.fail(gen, fmt.Sprintf("ffmpeg exited: %v %s", werr, strings.Join(errTail, " | ")))
		return
	}
	x.mu.Lock()
	if gen == x.gen {
		x.front = maxI64(x.front, x.durationMs)
		x.done = true
		x.closeSegmentLocked()
	}
	x.mu.Unlock()
	x.ev.Log("extract-eof", map[string]any{"fromMs": fromMs})
}

func (x *Extractor) isGen(gen int) bool {
	x.mu.Lock()
	defer x.mu.Unlock()
	return gen == x.gen
}

func (x *Extractor) fail(gen int, msg string) {
	msg = strings.ReplaceAll(msg, x.url, "<video-url>") // signed debrid links stay out of logs
	x.mu.Lock()
	if gen == x.gen {
		x.lastError = msg
		x.closeSegmentLocked()
	}
	x.mu.Unlock()
	x.ev.Log("extract-error", map[string]any{"error": msg})
}

// progress handles ffmpeg's out_time, which is relative to the seek point in
// ffmpeg's -progress output; reconcile against the latest cue to be safe.
func (x *Extractor) progress(gen int, fromMs, outMs int64) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if gen != x.gen {
		return
	}
	rel := fromMs + outMs
	cand := rel
	if x.front > fromMs {
		abs := outMs - x.startTimeMs
		if absDiff(abs, x.front) < absDiff(rel, x.front) {
			cand = abs
		}
	}
	if cand > x.front && (x.durationMs == 0 || cand <= x.durationMs) {
		x.front = cand
		x.recordRateLocked()
	}
}

func (x *Extractor) advance(gen int, cueStart int64) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if gen == x.gen && cueStart > x.front {
		x.front = cueStart
		x.recordRateLocked()
	}
}

func (x *Extractor) recordRateLocked() {
	now := time.Now()
	if now.Sub(x.lastCov) > 5*time.Second && x.front > x.segFrom {
		// Checkpoint the live range: everything up to the front is extracted
		// (cues arrive in time order).
		x.lastCov = now
		x.cache.Covered(interval{x.segFrom, x.front})
	}
	x.rateWin = append(x.rateWin, ratePoint{now, x.front})
	cut := now.Add(-15 * time.Second)
	for len(x.rateWin) > 2 && x.rateWin[1].at.Before(cut) {
		x.rateWin = x.rateWin[1:]
	}
}

// Rate returns media seconds extracted per wall second over the recent window.
func (x *Extractor) Rate() float64 {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.done {
		return 1e9
	}
	if len(x.rateWin) < 2 {
		return 0
	}
	a, b := x.rateWin[0], x.rateWin[len(x.rateWin)-1]
	wall := b.at.Sub(a.at).Seconds()
	if wall < 1 {
		return 0
	}
	return float64(b.front-a.front) / 1000 / wall
}

// FrontFor returns the extraction front for a playback position: the end of
// the covered range containing posMs (live segment included). ok=false if
// posMs is not covered at all.
func (x *Extractor) FrontFor(posMs int64) (front int64, complete bool, ok bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	// A freshly (re)started segment owns the next 90 s even before its
	// front reaches posMs; the caller sees front < posMs (extraction behind).
	if x.running && posMs >= x.segFrom-1000 && posMs <= maxI64(x.front, x.segFrom+90_000)+1000 {
		f := x.front
		if x.done {
			f = maxI64(f, x.durationMs)
		}
		// If the live segment has run into an older covered range, extend.
		for _, iv := range x.covered {
			if iv.From <= f && iv.To > f {
				f = iv.To
			}
		}
		return f, x.durationMs > 0 && f >= x.durationMs, true
	}
	for _, iv := range x.covered {
		if posMs >= iv.From-1000 && posMs <= iv.To {
			return iv.To, x.durationMs > 0 && iv.To >= x.durationMs, true
		}
	}
	return 0, false, false
}

// MaybeSkipCovered restarts the live segment past an already-covered range it
// has run into, so we never re-read media we already extracted.
func (x *Extractor) MaybeSkipCovered() {
	x.mu.Lock()
	if !x.running {
		x.mu.Unlock()
		return
	}
	var jump int64 = -1
	for _, iv := range x.covered {
		if iv.From > x.segFrom && x.front >= iv.From && iv.To > x.front {
			jump = iv.To
		}
	}
	complete := x.durationMs > 0 && jump >= x.durationMs
	x.mu.Unlock()
	if jump > 0 {
		if complete {
			x.mu.Lock()
			if x.cancel != nil {
				x.cancel()
			}
			x.front = jump
			x.closeSegmentLocked()
			x.done = true
			x.mu.Unlock()
			x.ev.Log("extract-joined-covered", map[string]any{"toMs": jump, "complete": true})
			return
		}
		x.ev.Log("extract-joined-covered", map[string]any{"toMs": jump})
		x.StartAt(jump - 5000)
	}
}

func (x *Extractor) Stats() map[string]any {
	x.mu.Lock()
	defer x.mu.Unlock()
	cov := []map[string]int64{}
	for _, iv := range x.covered {
		cov = append(cov, map[string]int64{"fromMs": iv.From, "toMs": iv.To})
	}
	return map[string]any{"segments": x.segments, "covered": cov, "liveFrom": x.segFrom, "liveFront": x.front, "lastError": x.lastError}
}

func (x *Extractor) Stop() {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.cancel != nil {
		x.cancel()
	}
	x.closeSegmentLocked()
}

func absDiff(a, b int64) int64 {
	if a > b {
		return a - b
	}
	return b - a
}

func maxI64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

var _ = io.EOF
