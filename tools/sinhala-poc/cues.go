package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Cue is one English subtitle event. Start/End are in mpv's playback
// timeline (milliseconds), already corrected for the container start time.
// The model never sees or returns these values.
type Cue struct {
	Key     string // stable identity: start|end|sha1(text)
	ID      int    // per-session integer used in model requests
	StartMs int64
	EndMs   int64
	English string

	Sinhala  string
	Status   CueStatus
	Attempts int
	LastErr  string
	Source   string // "translated", "journal", "fallback-english"
}

type CueStatus int

const (
	StatusPending CueStatus = iota
	StatusInFlight
	StatusTranslated
	StatusFallback // permanently failed; shown in English (a shortfall)
)

func cueKey(startMs, endMs int64, text string) string {
	sum := sha1.Sum([]byte(normalizeForKey(text)))
	return fmt.Sprintf("%d|%d|%s", startMs, endMs, hex.EncodeToString(sum[:6]))
}

var tagRe = regexp.MustCompile(`<[^>]+>|\{\\[^}]*\}`)

func normalizeForKey(s string) string {
	s = tagRe.ReplaceAllString(s, "")
	return strings.Join(strings.Fields(strings.ToLower(s)), " ")
}

func cleanCueText(s string) string {
	s = tagRe.ReplaceAllString(s, "")
	lines := strings.Split(strings.ReplaceAll(s, "\r", ""), "\n")
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l != "" {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

// ---------------------------------------------------------------------------
// Streaming SRT parser (ffmpeg output) – emits cues as soon as a block ends.

var srtTimeRe = regexp.MustCompile(`(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})`)

func parseSrtTime(h, m, s, ms string) int64 {
	hh, _ := strconv.ParseInt(h, 10, 64)
	mm, _ := strconv.ParseInt(m, 10, 64)
	ss, _ := strconv.ParseInt(s, 10, 64)
	for len(ms) < 3 {
		ms += "0"
	}
	x, _ := strconv.ParseInt(ms, 10, 64)
	return ((hh*60+mm)*60+ss)*1000 + x
}

type rawCue struct {
	StartMs, EndMs int64
	Text           string
}

// StreamSRT reads SRT from r and calls emit for each complete cue.
func StreamSRT(r io.Reader, emit func(rawCue)) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	var cur *rawCue
	var text []string
	flush := func() {
		if cur != nil {
			cur.Text = cleanCueText(strings.Join(text, "\n"))
			if cur.Text != "" && cur.EndMs > cur.StartMs {
				emit(*cur)
			}
		}
		cur = nil
		text = nil
	}
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		line = strings.TrimPrefix(line, "\ufeff")
		if m := srtTimeRe.FindStringSubmatch(line); m != nil {
			// A new timing line always starts a new cue, even if the blank
			// separator was missing.
			if cur != nil && len(text) > 0 && isIndexLine(text[len(text)-1]) {
				text = text[:len(text)-1]
			}
			flush()
			cur = &rawCue{
				StartMs: parseSrtTime(m[1], m[2], m[3], m[4]),
				EndMs:   parseSrtTime(m[5], m[6], m[7], m[8]),
			}
			continue
		}
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		if cur != nil {
			text = append(text, line)
		}
	}
	flush()
	return sc.Err()
}

func isIndexLine(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func formatSrtTime(ms int64) string {
	if ms < 0 {
		ms = 0
	}
	h := ms / 3600000
	m := (ms % 3600000) / 60000
	s := (ms % 60000) / 1000
	x := ms % 1000
	return fmt.Sprintf("%02d:%02d:%02d,%03d", h, m, s, x)
}

// ---------------------------------------------------------------------------
// Cue store

type Store struct {
	mu        sync.Mutex
	byKey     map[string]*Cue
	ordered   []*Cue // sorted by StartMs, then key
	nextID    int
	changed   chan struct{}
	journal   *Journal
	extracted int
}

func NewStore(j *Journal) *Store {
	return &Store{byKey: map[string]*Cue{}, changed: make(chan struct{}, 1), journal: j}
}

func (s *Store) notify() {
	select {
	case s.changed <- struct{}{}:
	default:
	}
}

// Add inserts an extracted cue; duplicates (same key) are ignored. Returns true if new.
func (s *Store) Add(rc rawCue) bool {
	key := cueKey(rc.StartMs, rc.EndMs, rc.Text)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.byKey[key]; ok {
		return false
	}
	s.nextID++
	c := &Cue{Key: key, ID: s.nextID, StartMs: rc.StartMs, EndMs: rc.EndMs, English: rc.Text}
	if s.journal != nil {
		if si, ok := s.journal.Lookup(key); ok {
			c.Sinhala = si
			c.Status = StatusTranslated
			c.Source = "journal"
		}
	}
	s.byKey[key] = c
	i := sort.Search(len(s.ordered), func(i int) bool {
		o := s.ordered[i]
		return o.StartMs > c.StartMs || (o.StartMs == c.StartMs && o.Key > c.Key)
	})
	s.ordered = append(s.ordered, nil)
	copy(s.ordered[i+1:], s.ordered[i:])
	s.ordered[i] = c
	s.extracted++
	s.notify()
	return true
}

func (s *Store) Snapshot() []Cue {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Cue, len(s.ordered))
	for i, c := range s.ordered {
		out[i] = *c
	}
	return out
}

func (s *Store) Counts() (total, translated, fallback, pending int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.ordered {
		total++
		switch c.Status {
		case StatusTranslated:
			translated++
		case StatusFallback:
			fallback++
		default:
			pending++
		}
	}
	return
}

// FirstNotReadyFrom returns the earliest cue with StartMs >= posMs that is not
// translated (and not a permanent fallback). ok=false when none is known.
func (s *Store) FirstNotReadyFrom(posMs int64) (c Cue, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	i := sort.Search(len(s.ordered), func(i int) bool { return s.ordered[i].StartMs >= posMs })
	for ; i < len(s.ordered); i++ {
		x := s.ordered[i]
		if x.Status != StatusTranslated && x.Status != StatusFallback {
			return *x, true
		}
	}
	return Cue{}, false
}

// CueRate returns cues per media second over [fromMs, toMs] of extracted cues.
func (s *Store) CueRate(fromMs, toMs int64) float64 {
	if toMs <= fromMs {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, c := range s.ordered {
		if c.StartMs >= fromMs && c.StartMs < toMs {
			n++
		}
	}
	return float64(n) / (float64(toMs-fromMs) / 1000)
}

// AllReadyBetween reports whether every extracted cue in [from,to) is translated or fallback.
func (s *Store) AllReadyBetween(fromMs, toMs int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.ordered {
		if c.StartMs >= fromMs && c.StartMs < toMs {
			if c.Status != StatusTranslated && c.Status != StatusFallback {
				return false
			}
		}
	}
	return true
}

// TakeBatch picks up to n pending cues, prioritising cues at/after playheadMs
// in time order, then earlier cues. Marks them in-flight.
func (s *Store) TakeBatch(n int, playheadMs int64, horizonMs int64, force bool) []*Cue {
	return s.TakeBatchMin(n, playheadMs, horizonMs, 0, force)
}

// TakeBatchMin is TakeBatch that also allows a partial batch once at least
// minPartial cues are pending (minPartial <= 0 disables that rule).
func (s *Store) TakeBatchMin(n int, playheadMs int64, horizonMs int64, minPartial int, force bool) []*Cue {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ahead, behind []*Cue
	for _, c := range s.ordered {
		if c.Status != StatusPending {
			continue
		}
		if c.StartMs >= playheadMs-2000 {
			ahead = append(ahead, c)
		} else {
			behind = append(behind, c)
		}
	}
	cands := append(ahead, behind...)
	if len(cands) == 0 {
		return nil
	}
	// Batch only when worthwhile: a full batch, or a cue needed soon (at or
	// near the playhead), or the caller says extraction is idle (force).
	// Small batches waste requests, which free-tier daily limits count.
	if len(cands) < n && !force {
		urgent := false
		for _, c := range ahead {
			if c.StartMs-playheadMs <= horizonMs {
				urgent = true
			}
			break
		}
		if !urgent && (minPartial <= 0 || len(cands) < minPartial) {
			return nil
		}
	}
	if len(cands) > n {
		cands = cands[:n]
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].StartMs < cands[j].StartMs })
	for _, c := range cands {
		c.Status = StatusInFlight
	}
	return cands
}

// Context returns up to nBefore cues before first and nAfter cues after last (by time).
func (s *Store) Context(first, last *Cue, nBefore, nAfter int) (before []Cue, after []Cue) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fi := -1
	li := -1
	for i, c := range s.ordered {
		if c == first {
			fi = i
		}
		if c == last {
			li = i
		}
	}
	if fi >= 0 {
		for i := fi - 1; i >= 0 && len(before) < nBefore; i-- {
			before = append([]Cue{*s.ordered[i]}, before...)
		}
	}
	if li >= 0 {
		for i := li + 1; i < len(s.ordered) && len(after) < nAfter; i++ {
			after = append(after, *s.ordered[i])
		}
	}
	return
}

func (s *Store) Accept(c *Cue, si string) {
	s.mu.Lock()
	c.Sinhala = si
	c.Status = StatusTranslated
	c.Source = "translated"
	c.LastErr = ""
	s.mu.Unlock()
	s.notify()
}

func (s *Store) Requeue(c *Cue, errText string) {
	s.mu.Lock()
	c.Status = StatusPending
	c.Attempts++
	c.LastErr = errText
	s.mu.Unlock()
}

func (s *Store) Fallback(c *Cue, reason string) {
	s.mu.Lock()
	c.Status = StatusFallback
	c.Source = "fallback-english"
	c.LastErr = reason
	s.mu.Unlock()
	s.notify()
}

// FallbackAllPending marks every not-yet-translated cue as an English fallback.
func (s *Store) FallbackAllPending(reason string) int {
	s.mu.Lock()
	n := 0
	for _, c := range s.ordered {
		if c.Status == StatusPending || c.Status == StatusInFlight {
			c.Status = StatusFallback
			c.Source = "fallback-english"
			c.LastErr = reason
			n++
		}
	}
	s.mu.Unlock()
	s.notify()
	return n
}

// ---------------------------------------------------------------------------
// SRT writer: times come only from the store (copied from English cues).

// WriteSinhalaSRT writes translated cues (and English fallbacks, in italics)
// in time order, atomically. Returns the set of keys written.
func (s *Store) WriteSinhalaSRT(path string) (map[string]bool, int, error) {
	snap := s.Snapshot()
	var b strings.Builder
	written := map[string]bool{}
	n := 0
	for _, c := range snap {
		var text string
		switch c.Status {
		case StatusTranslated:
			text = c.Sinhala
		case StatusFallback:
			text = "<i>" + c.English + "</i>"
		default:
			continue
		}
		n++
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s\n\n", n, formatSrtTime(c.StartMs), formatSrtTime(c.EndMs), text)
		written[c.Key] = true
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return nil, 0, err
	}
	if err := replaceFile(tmp, path); err != nil {
		return nil, 0, err
	}
	return written, n, nil
}

// VerifySRTAgainstStore re-parses an SRT file and checks every cue's times
// and order against the store (deterministic timeline check).
func VerifySRTAgainstStore(path string, s *Store) (checked int, mismatches []string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, nil, err
	}
	defer f.Close()
	snap := s.Snapshot()
	want := map[int64][]Cue{}
	for _, c := range snap {
		if c.Status == StatusTranslated || c.Status == StatusFallback {
			want[c.StartMs] = append(want[c.StartMs], c)
		}
	}
	var prev int64 = -1
	err = StreamSRT(f, func(rc rawCue) {
		checked++
		if rc.StartMs < prev {
			mismatches = append(mismatches, fmt.Sprintf("order: %d after %d", rc.StartMs, prev))
		}
		prev = rc.StartMs
		ok := false
		for _, c := range want[rc.StartMs] {
			if c.EndMs == rc.EndMs {
				ok = true
				break
			}
		}
		if !ok {
			mismatches = append(mismatches, fmt.Sprintf("no store cue with %s --> %s", formatSrtTime(rc.StartMs), formatSrtTime(rc.EndMs)))
		}
	})
	return checked, mismatches, err
}

func replaceFile(tmp, dst string) error {
	// os.Rename replaces atomically on POSIX and uses MoveFileEx with
	// MOVEFILE_REPLACE_EXISTING on Windows.
	var err error
	for i := 0; i < 20; i++ {
		if err = os.Rename(tmp, dst); err == nil {
			return nil
		}
		// mpv may briefly hold the file open while reloading on Windows.
		time.Sleep(50 * time.Millisecond)
	}
	return err
}
