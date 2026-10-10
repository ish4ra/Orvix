package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
)

const promptVersion = "si-poc-1"

// ErrClass separates failures that need different handling.
type ErrClass string

const (
	ClassOK         ErrClass = "ok"
	ClassTransient  ErrClass = "temporary"   // network, timeout, 5xx
	ClassRateLimit  ErrClass = "rate-limit"  // per-minute style 429
	ClassDailyQuota ErrClass = "daily-quota" // daily quota exhausted / prepay depleted
	ClassAuth       ErrClass = "auth"        // bad key / permission / billing precondition
	ClassConfig     ErrClass = "config"      // bad model name, bad request shape
	ClassMalformed  ErrClass = "malformed"   // unparseable / truncated output
	ClassRefusal    ErrClass = "refusal"     // blocked by safety / policy
)

type GeminiClient struct {
	Endpoint  string // base, e.g. https://generativelanguage.googleapis.com
	Model     string
	Key       string
	Thinking  string // "minimal", "low", "omit"
	HTTP      *http.Client
	Title     string
	Requests  atomic.Int64
	HostsSeen sync.Map
}

type tReq struct {
	ID int    `json:"id"`
	En string `json:"en"`
}

type tResp struct {
	ID int    `json:"id"`
	Si string `json:"si"`
}

type callResult struct {
	Class        ErrClass
	Items        []tResp
	Detail       string
	RetryAfter   time.Duration
	HTTPStatus   int
	FinishReason string
	PromptTokens int
	OutTokens    int
	ThinkTokens  int
	Latency      time.Duration
}

func (g *GeminiClient) buildPrompt(batch []*Cue, before, after []Cue) string {
	var b strings.Builder
	b.WriteString("You translate English film/TV subtitle cues into natural, concise Sri Lankan Sinhala for on-screen subtitles.\n\n")
	b.WriteString("Rules:\n")
	b.WriteString("- Return a JSON array with exactly one object {\"id\": <same id>, \"si\": <Sinhala>} for every input cue, same ids, no extra entries.\n")
	b.WriteString("- Translate meaning, tone, slang and emotion; prefer natural spoken Sinhala over formal textbook Sinhala.\n")
	b.WriteString("- Use Sinhala Unicode script. Keep personal names, ranks and proper nouns as names (Sinhala transliteration or the original), never translate their meaning.\n")
	b.WriteString("- Keep each result short enough to read on screen; at most two lines. Do not merge or split cues.\n")
	b.WriteString("- No explanations, notes, romanization or quotation marks around the whole line.\n")
	b.WriteString("- The CONTEXT lines are for understanding only. Do not translate or return them.\n\n")
	if g.Title != "" {
		fmt.Fprintf(&b, "TITLE: %s\n", g.Title)
	}
	if len(before) > 0 {
		b.WriteString("CONTEXT BEFORE (already shown):\n")
		for _, c := range before {
			if c.Status == StatusTranslated && c.Sinhala != "" {
				fmt.Fprintf(&b, "- %s => %s\n", oneLine(c.English), oneLine(c.Sinhala))
			} else {
				fmt.Fprintf(&b, "- %s\n", oneLine(c.English))
			}
		}
	}
	if len(after) > 0 {
		b.WriteString("CONTEXT AFTER:\n")
		for _, c := range after {
			fmt.Fprintf(&b, "- %s\n", oneLine(c.English))
		}
	}
	items := make([]tReq, len(batch))
	for i, c := range batch {
		items[i] = tReq{ID: c.ID, En: c.English}
	}
	js, _ := json.Marshal(items)
	b.WriteString("\nCUES TO TRANSLATE (JSON):\n")
	b.Write(js)
	b.WriteString("\n")
	return b.String()
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func (g *GeminiClient) Translate(ctx context.Context, batch []*Cue, before, after []Cue) callResult {
	prompt := g.buildPrompt(batch, before, after)
	gen := map[string]any{
		"responseMimeType": "application/json",
		"responseSchema": map[string]any{
			"type": "ARRAY",
			"items": map[string]any{
				"type": "OBJECT",
				"properties": map[string]any{
					"id": map[string]any{"type": "INTEGER"},
					"si": map[string]any{"type": "STRING"},
				},
				"required": []string{"id", "si"},
			},
		},
		"maxOutputTokens": 8192,
	}
	if g.Thinking != "" && g.Thinking != "omit" {
		gen["thinkingConfig"] = map[string]any{"thinkingLevel": g.Thinking}
	}
	body, _ := json.Marshal(map[string]any{
		"contents":         []any{map[string]any{"role": "user", "parts": []any{map[string]any{"text": prompt}}}},
		"generationConfig": gen,
	})
	u := strings.TrimRight(g.Endpoint, "/") + "/v1beta/models/" + url.PathEscape(g.Model) + ":generateContent"
	if pu, err := url.Parse(u); err == nil {
		g.HostsSeen.Store(pu.Host, true)
	}
	req, _ := http.NewRequestWithContext(ctx, "POST", u, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", g.Key) // header, never the URL
	g.Requests.Add(1)
	t0 := time.Now()
	resp, err := g.HTTP.Do(req)
	lat := time.Since(t0)
	if err != nil {
		return callResult{Class: ClassTransient, Detail: redact(err.Error(), g.Key), Latency: lat}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	r := classifyHTTP(resp.StatusCode, resp.Header, raw)
	r.Latency = lat
	r.HTTPStatus = resp.StatusCode
	r.Detail = redact(r.Detail, g.Key)
	if r.Class != ClassOK {
		return r
	}
	return parseGenerateResponse(raw, r)
}

func redact(s, key string) string {
	if key != "" {
		s = strings.ReplaceAll(s, key, "<key>")
	}
	return s
}

var retryDelayRe = regexp.MustCompile(`"retryDelay"\s*:\s*"([0-9.]+)s"`)

func classifyHTTP(status int, hdr http.Header, raw []byte) callResult {
	if status >= 200 && status < 300 {
		return callResult{Class: ClassOK}
	}
	low := strings.ToLower(string(raw))
	detail := string(raw)
	if len(detail) > 600 {
		detail = detail[:600]
	}
	r := callResult{Detail: detail}
	if m := retryDelayRe.FindStringSubmatch(string(raw)); m != nil {
		if f, err := parseFloat(m[1]); err == nil {
			r.RetryAfter = time.Duration(f * float64(time.Second))
		}
	} else if ra := hdr.Get("Retry-After"); ra != "" {
		if f, err := parseFloat(ra); err == nil {
			r.RetryAfter = time.Duration(f * float64(time.Second))
		}
	}
	switch {
	case status == 429:
		daily := strings.Contains(low, "quota_exceeded") || strings.Contains(low, "perday") ||
			strings.Contains(low, "per day") || strings.Contains(low, "daily")
		if daily {
			r.Class = ClassDailyQuota
		} else {
			r.Class = ClassRateLimit
		}
	case status == 402:
		r.Class = ClassDailyQuota
	case status == 401 || status == 403:
		r.Class = ClassAuth
	case status == 400 && (strings.Contains(low, "api_key") || strings.Contains(low, "api key") || strings.Contains(low, "failed_precondition") || strings.Contains(low, "billing")):
		r.Class = ClassAuth
	case status == 400 || status == 404 || status == 416 || status == 501:
		r.Class = ClassConfig
	case status == 408 || status == 409 || status == 499 || status >= 500:
		r.Class = ClassTransient
	default:
		r.Class = ClassConfig
	}
	return r
}

func parseFloat(s string) (float64, error) {
	var f float64
	_, err := fmt.Sscanf(strings.TrimSpace(s), "%g", &f)
	return f, err
}

func parseGenerateResponse(raw []byte, r callResult) callResult {
	var gr struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text    string `json:"text"`
					Thought bool   `json:"thought"`
				} `json:"parts"`
			} `json:"content"`
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
		PromptFeedback struct {
			BlockReason string `json:"blockReason"`
		} `json:"promptFeedback"`
		UsageMetadata struct {
			PromptTokenCount     int `json:"promptTokenCount"`
			CandidatesTokenCount int `json:"candidatesTokenCount"`
			ThoughtsTokenCount   int `json:"thoughtsTokenCount"`
		} `json:"usageMetadata"`
	}
	if err := json.Unmarshal(raw, &gr); err != nil {
		r.Class = ClassMalformed
		r.Detail = "response envelope not JSON"
		return r
	}
	r.PromptTokens = gr.UsageMetadata.PromptTokenCount
	r.OutTokens = gr.UsageMetadata.CandidatesTokenCount
	r.ThinkTokens = gr.UsageMetadata.ThoughtsTokenCount
	if gr.PromptFeedback.BlockReason != "" {
		r.Class = ClassRefusal
		r.Detail = "prompt blocked: " + gr.PromptFeedback.BlockReason
		return r
	}
	if len(gr.Candidates) == 0 {
		r.Class = ClassMalformed
		r.Detail = "no candidates"
		return r
	}
	c := gr.Candidates[0]
	r.FinishReason = c.FinishReason
	switch c.FinishReason {
	case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY":
		r.Class = ClassRefusal
		r.Detail = "finishReason " + c.FinishReason
		return r
	}
	var text strings.Builder
	for _, p := range c.Content.Parts {
		if !p.Thought {
			text.WriteString(p.Text)
		}
	}
	t := strings.TrimSpace(text.String())
	t = strings.TrimPrefix(t, "```json")
	t = strings.TrimPrefix(t, "```")
	t = strings.TrimSuffix(t, "```")
	var items []tResp
	if err := json.Unmarshal([]byte(strings.TrimSpace(t)), &items); err != nil {
		r.Class = ClassMalformed
		r.Detail = "items not JSON (finishReason " + c.FinishReason + ")"
		return r
	}
	r.Class = ClassOK
	r.Items = items
	return r
}

// ---------------------------------------------------------------------------
// Per-cue validation

var sinhalaRe = regexp.MustCompile(`[\x{0D80}-\x{0DFF}]`)
var latinWordRe = regexp.MustCompile(`[A-Za-z][A-Za-z'’-]+`)

// validateCue returns "" when the Sinhala output is acceptable for the cue.
func validateCue(en, si string) string {
	si = strings.TrimSpace(si)
	if si == "" {
		return "empty"
	}
	if strings.Contains(si, "\"id\"") || strings.Contains(si, "{\"") || strings.HasPrefix(si, "[") {
		return "json-fragment"
	}
	words := latinWordRe.FindAllString(en, -1)
	if len(words) >= 3 && !sinhalaRe.MatchString(si) && !looksLikeNamesOrLyrics(en) {
		return "no-sinhala-script"
	}
	enLen := len([]rune(en))
	if len([]rune(si)) > 4*enLen+40 {
		return "too-long"
	}
	if strings.Count(si, "\n") > 2 {
		return "too-many-lines"
	}
	return ""
}

func looksLikeNamesOrLyrics(en string) bool {
	t := strings.TrimSpace(en)
	if strings.ContainsAny(t, "♪♫") {
		return true
	}
	// "Rex! Cody! Obi-Wan!" style: every word capitalised.
	words := latinWordRe.FindAllString(t, -1)
	if len(words) == 0 {
		return false
	}
	for _, w := range words {
		if !unicode.IsUpper([]rune(w)[0]) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Worker pool

type TranslatorStats struct {
	mu           sync.Mutex
	Calls        []CallRecord
	Accepted     int
	Rejected     map[string]int
	Fallbacks    int
	DailyQuotaAt time.Time
	AuthError    string
	ConfigError  string
	ReRequested  int // cues requested again after already accepted (must stay 0)
}

type CallRecord struct {
	At           time.Time `json:"at"`
	Cues         int       `json:"cues"`
	Accepted     int       `json:"accepted"`
	Class        ErrClass  `json:"class"`
	HTTP         int       `json:"http"`
	LatencyMs    int64     `json:"latencyMs"`
	PromptTokens int       `json:"promptTokens"`
	OutTokens    int       `json:"outTokens"`
	ThinkTokens  int       `json:"thinkTokens"`
	Finish       string    `json:"finish,omitempty"`
	Detail       string    `json:"detail,omitempty"`
	FirstStartMs int64     `json:"firstStartMs"`
}

type Translator struct {
	g           *GeminiClient
	store       *Store
	journal     *Journal
	ev          *EventLog
	stats       *TranslatorStats
	concurrency int
	firstBatch  int
	batch       int
	maxAttempts int

	playhead    atomic.Int64
	extractIdle func() bool
	// Batching policy. Free-tier limits count requests, so partial batches
	// are sent only when a cue is genuinely needed soon:
	//   before playback: only once the start floor is fully extracted;
	//   during playback: when a pending cue starts within urgentMs of the
	//   playhead (criticalMs if another partial request is already running).
	urgentMs       int64
	criticalMs     int64
	prestartMs     int64
	inFlight       atomic.Int32
	playing        atomic.Bool
	floorExtracted func() bool

	mu          sync.Mutex
	pausedUntil time.Time
	stopped     bool // daily quota / auth / config: no more requests
	stopReason  ErrClass
	successes   int
	samples     []latSample // size and latency of completed requests
	rateCut     int         // temporary concurrency reduction after rate limits
	firstDone   bool
}

func NewTranslator(g *GeminiClient, s *Store, j *Journal, ev *EventLog, conc, firstBatch, batch int) *Translator {
	return &Translator{g: g, store: s, journal: j, ev: ev, concurrency: conc, firstBatch: firstBatch, batch: batch, maxAttempts: 3, urgentMs: 30_000, criticalMs: 12_000, prestartMs: 75_000,
		stats: &TranslatorStats{Rejected: map[string]int{}}}
}

func (t *Translator) SetPlayhead(ms int64) { t.playhead.Store(ms) }

func (t *Translator) Stopped() (bool, ErrClass) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.stopped, t.stopReason
}

type latSample struct {
	size int
	sec  float64
}

// Capacity estimates sustainable cues/second: usable concurrency × full batch
// size / estimated latency of a full batch. Latency grows with batch size,
// so a 1-cue request must not stand in for a 30-cue one. Conservative:
// p75 latency of near-full batches when available, otherwise a linear fit
// latency = a + c·size (a, c >= 0), never below the slowest request seen.
func (t *Translator) Capacity() (cuesPerSec float64, successes int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.samples) == 0 {
		return 0, t.successes
	}
	b := t.batch
	var big []float64
	maxLat := 0.0
	for _, x := range t.samples {
		if x.size*2 >= b {
			big = append(big, x.sec)
		}
		if x.sec > maxLat {
			maxLat = x.sec
		}
	}
	var lfull float64
	if len(big) >= 2 {
		sort.Float64s(big)
		lfull = big[int(math.Ceil(0.75*float64(len(big)-1)))]
	} else {
		var n, sx, sy, sxx, sxy float64
		for _, x := range t.samples {
			n++
			sx += float64(x.size)
			sy += x.sec
			sxx += float64(x.size * x.size)
			sxy += float64(x.size) * x.sec
		}
		c := 0.0
		if d := n*sxx - sx*sx; d > 0 {
			c = math.Max(0, (n*sxy-sx*sy)/d)
		}
		a := math.Max(0, (sy-c*sx)/n)
		lfull = math.Max(maxLat, a+c*float64(b))
	}
	conc := t.concurrency - t.rateCut
	if conc < 1 {
		conc = 1
	}
	if lfull <= 0 {
		return 0, t.successes
	}
	return float64(conc*b) / lfull, t.successes
}

func (t *Translator) Run(ctx context.Context) {
	var wg sync.WaitGroup
	for i := 0; i < t.concurrency; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			t.worker(ctx, worker)
		}(i)
	}
	wg.Wait()
}

func (t *Translator) worker(ctx context.Context, worker int) {
	for ctx.Err() == nil {
		t.mu.Lock()
		stopped := t.stopped
		wait := time.Until(t.pausedUntil)
		limit := t.concurrency - t.rateCut
		size := t.batch
		if !t.firstDone {
			size = t.firstBatch
		}
		t.mu.Unlock()
		if stopped {
			return
		}
		if wait > 0 {
			sleepCtx(ctx, wait)
			continue
		}
		if worker >= limit {
			sleepCtx(ctx, time.Second)
			continue
		}
		force := t.extractIdle != nil && t.extractIdle()
		// Partial batches cost requests (free-tier limits count requests).
		// Only one partial batch may be in flight, unless a cue is critical.
		var horizon int64 = math.MinInt64 / 2 // no partial batches
		minPartial := 0
		switch {
		case t.playing.Load():
			horizon = t.urgentMs
			if t.inFlight.Load() > 0 {
				horizon = t.criticalMs
			}
			minPartial = t.firstBatch
		case t.floorExtracted != nil && t.floorExtracted():
			horizon = t.prestartMs
			minPartial = t.firstBatch
		}
		batch := t.store.TakeBatchMin(size, t.playhead.Load(), horizon, minPartial, force)
		if len(batch) == 0 {
			select {
			case <-ctx.Done():
				return
			case <-t.store.changed:
			case <-time.After(700 * time.Millisecond):
			}
			continue
		}
		t.inFlight.Add(1)
		t.process(ctx, batch)
		t.inFlight.Add(-1)
	}
}

func (t *Translator) process(ctx context.Context, batch []*Cue) {
	if len(batch) == 0 {
		return
	}
	for _, c := range batch {
		if c.Source == "journal" || c.Source == "translated" {
			t.stats.mu.Lock()
			t.stats.ReRequested++
			t.stats.mu.Unlock()
		}
	}
	before, after := t.store.Context(batch[0], batch[len(batch)-1], 6, 3)
	rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	res := t.g.Translate(rctx, batch, before, after)
	cancel()

	rec := CallRecord{At: time.Now(), Cues: len(batch), Class: res.Class, HTTP: res.HTTPStatus, LatencyMs: res.Latency.Milliseconds(),
		PromptTokens: res.PromptTokens, OutTokens: res.OutTokens, ThinkTokens: res.ThinkTokens, Finish: res.FinishReason, Detail: res.Detail,
		FirstStartMs: batch[0].StartMs}

	switch res.Class {
	case ClassOK:
		accepted := t.acceptItems(batch, res.Items)
		rec.Accepted = accepted
		t.mu.Lock()
		t.successes++
		t.firstDone = true
		if res.Latency > 0 {
			t.samples = append(t.samples, latSample{len(batch), res.Latency.Seconds()})
			if len(t.samples) > 30 {
				t.samples = t.samples[len(t.samples)-30:]
			}
		}
		if t.rateCut > 0 && t.successes%5 == 0 {
			t.rateCut--
		}
		t.mu.Unlock()
	case ClassTransient, ClassMalformed:
		t.requeueAll(batch, string(res.Class)+": "+res.Detail, true)
		if res.Class == ClassMalformed && len(batch) > 1 {
			t.mu.Lock()
			t.batch = maxInt(8, t.batch*3/4) // smaller responses truncate less
			t.mu.Unlock()
		}
		t.backoff(len(batch), res)
	case ClassRefusal:
		if len(batch) == 1 {
			t.store.Fallback(batch[0], "refused: "+res.Detail)
			t.stats.mu.Lock()
			t.stats.Fallbacks++
			t.stats.mu.Unlock()
			t.ev.Log("cue-fallback", map[string]any{"startMs": batch[0].StartMs, "reason": "refusal"})
		} else {
			// Isolate the refused cue(s): split in halves and retry.
			mid := len(batch) / 2
			for _, c := range batch {
				t.store.Requeue(c, "refusal-isolate")
			}
			t.process(ctx, takeBack(t.store, batch[:mid]))
			t.process(ctx, takeBack(t.store, batch[mid:]))
		}
	case ClassRateLimit:
		t.requeueAll(batch, "rate-limit", false)
		t.mu.Lock()
		if t.rateCut < t.concurrency-1 {
			t.rateCut++
		}
		d := res.RetryAfter
		if d <= 0 {
			d = 10 * time.Second
		}
		t.pausedUntil = time.Now().Add(d)
		t.mu.Unlock()
	case ClassDailyQuota, ClassAuth, ClassConfig:
		t.requeueAll(batch, string(res.Class), false)
		t.mu.Lock()
		t.stopped = true
		t.stopReason = res.Class
		t.mu.Unlock()
		t.stats.mu.Lock()
		switch res.Class {
		case ClassDailyQuota:
			t.stats.DailyQuotaAt = time.Now()
		case ClassAuth:
			t.stats.AuthError = res.Detail
		default:
			t.stats.ConfigError = res.Detail
		}
		t.stats.mu.Unlock()
	}
	t.stats.mu.Lock()
	t.stats.Calls = append(t.stats.Calls, rec)
	t.stats.mu.Unlock()
	t.ev.Log("translate-call", rec)
}

// takeBack re-marks requeued cues as in-flight for an immediate isolated retry.
func takeBack(s *Store, cues []*Cue) []*Cue {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []*Cue{}
	for _, c := range cues {
		if c.Status == StatusPending {
			c.Status = StatusInFlight
			out = append(out, c)
		}
	}
	return out
}

func (t *Translator) acceptItems(batch []*Cue, items []tResp) int {
	byID := map[int]*Cue{}
	for _, c := range batch {
		byID[c.ID] = c
	}
	seen := map[int]int{}
	for _, it := range items {
		seen[it.ID]++
	}
	// Alignment-slip guard: identical Sinhala for different English cues.
	siCount := map[string]map[string]bool{}
	for _, it := range items {
		if c := byID[it.ID]; c != nil {
			s := strings.TrimSpace(it.Si)
			if len([]rune(s)) > 8 {
				if siCount[s] == nil {
					siCount[s] = map[string]bool{}
				}
				siCount[s][normalizeForKey(c.English)] = true
			}
		}
	}
	accepted := 0
	pairs := map[string]string{}
	done := map[int]bool{}
	for _, it := range items {
		c := byID[it.ID]
		reason := ""
		switch {
		case c == nil:
			reason = "unknown-id"
		case seen[it.ID] > 1:
			reason = "duplicate-id"
		case len(siCount[strings.TrimSpace(it.Si)]) > 1:
			reason = "alignment-slip"
		default:
			reason = validateCue(c.English, it.Si)
		}
		if c == nil {
			t.countReject(reason)
			continue
		}
		if done[c.ID] {
			continue
		}
		done[c.ID] = true
		if reason != "" {
			t.countReject(reason)
			t.retryOrFallback(c, reason)
			continue
		}
		si := strings.TrimSpace(it.Si)
		t.store.Accept(c, si)
		pairs[c.Key] = si
		accepted++
	}
	for _, c := range batch {
		if !done[c.ID] {
			t.countReject("missing-id")
			t.retryOrFallback(c, "missing-id")
		}
	}
	if err := t.journal.AppendBatch(pairs); err != nil {
		t.ev.Log("journal-error", map[string]any{"error": err.Error()})
	}
	t.stats.mu.Lock()
	t.stats.Accepted += accepted
	t.stats.mu.Unlock()
	return accepted
}

func (t *Translator) countReject(reason string) {
	t.stats.mu.Lock()
	t.stats.Rejected[reason]++
	t.stats.mu.Unlock()
}

func (t *Translator) retryOrFallback(c *Cue, reason string) {
	if c.Attempts+1 >= t.maxAttempts {
		t.store.Fallback(c, reason)
		t.stats.mu.Lock()
		t.stats.Fallbacks++
		t.stats.mu.Unlock()
		t.ev.Log("cue-fallback", map[string]any{"startMs": c.StartMs, "reason": reason})
		return
	}
	t.store.Requeue(c, reason)
}

func (t *Translator) requeueAll(batch []*Cue, reason string, countAttempt bool) {
	for _, c := range batch {
		if countAttempt {
			t.retryOrFallback(c, reason)
		} else {
			t.store.mu.Lock()
			c.Status = StatusPending
			c.LastErr = reason
			t.store.mu.Unlock()
		}
	}
}

func (t *Translator) backoff(n int, res callResult) {
	t.mu.Lock()
	defer t.mu.Unlock()
	d := res.RetryAfter
	if d <= 0 {
		d = time.Duration(1500+rand.Intn(1500)) * time.Millisecond
	}
	if until := time.Now().Add(d); until.After(t.pausedUntil) {
		t.pausedUntil = until
	}
}

func sleepCtx(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

var errStopped = errors.New("translator stopped")
