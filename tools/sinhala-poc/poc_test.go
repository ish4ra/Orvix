package main

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStreamSRTParsesProgressiveOutput(t *testing.T) {
	in := "1\n00:00:01,500 --> 00:00:03,600\n<i>Hello</i> there.\nSecond line\n\n2\n00:01:02,005 --> 00:01:04,000\nNo blank before next\n3\n00:01:05,000 --> 00:01:06,000\nThird\n"
	var got []rawCue
	if err := StreamSRT(strings.NewReader(in), func(c rawCue) { got = append(got, c) }); err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 cues, got %d: %+v", len(got), got)
	}
	if got[0].StartMs != 1500 || got[0].EndMs != 3600 || got[0].Text != "Hello there.\nSecond line" {
		t.Fatalf("cue 1 wrong: %+v", got[0])
	}
	if got[1].Text != "No blank before next" || got[1].StartMs != 62005 {
		t.Fatalf("cue 2 wrong: %+v", got[1])
	}
}

func TestValidateCue(t *testing.T) {
	cases := []struct{ en, si, want string }{
		{"We move at dawn, General.", "අපි උදේ පාන්දර පිටත් වෙනවා.", ""},
		{"We move at dawn, General.", "We move at dawn, General.", "no-sinhala-script"},
		{"Rex! Cody! Obi-Wan!", "Rex! Cody! Obi-Wan!", ""},
		{"♪ la la la ♪", "♪ la la la ♪", ""},
		{"Hi.", "", "empty"},
		{"Go now, quickly.", `{"id": 4, "si": "x"}`, "json-fragment"},
	}
	for _, c := range cases {
		if got := validateCue(c.en, c.si); got != c.want {
			t.Errorf("validateCue(%q,%q)=%q want %q", c.en, c.si, got, c.want)
		}
	}
}

func TestClassifyGeminiErrors(t *testing.T) {
	perMin := `{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"17s"}]}}`
	r := classifyHTTP(429, http.Header{}, []byte(perMin))
	if r.Class != ClassRateLimit || r.RetryAfter != 17*time.Second {
		t.Fatalf("per-minute: %+v", r)
	}
	daily := `{"error":{"code":429,"details":[{"violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}`
	if c := classifyHTTP(429, http.Header{}, []byte(daily)).Class; c != ClassDailyQuota {
		t.Fatalf("daily: %v", c)
	}
	if c := classifyHTTP(429, http.Header{}, []byte(`{"error":{"code":"quota_exceeded"}}`)).Class; c != ClassDailyQuota {
		t.Fatalf("quota_exceeded: %v", c)
	}
	if c := classifyHTTP(400, http.Header{}, []byte(`{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}`)).Class; c != ClassAuth {
		t.Fatalf("bad key: %v", c)
	}
	if c := classifyHTTP(404, http.Header{}, []byte(`model not found`)).Class; c != ClassConfig {
		t.Fatalf("404: %v", c)
	}
	if c := classifyHTTP(503, http.Header{}, nil).Class; c != ClassTransient {
		t.Fatalf("503: %v", c)
	}
	blocked := parseGenerateResponse([]byte(`{"promptFeedback":{"blockReason":"SAFETY"}}`), callResult{})
	if blocked.Class != ClassRefusal {
		t.Fatalf("blocked: %+v", blocked)
	}
	trunc := parseGenerateResponse([]byte(`{"candidates":[{"content":{"parts":[{"text":"[{\"id\":1,\"si\":\"x"}]},"finishReason":"MAX_TOKENS"}]}`), callResult{})
	if trunc.Class != ClassMalformed {
		t.Fatalf("truncated: %+v", trunc)
	}
}

func TestJournalResumeAndVersioning(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "j.jsonl")
	j, err := OpenJournal(p, "m1", promptVersion)
	if err != nil {
		t.Fatal(err)
	}
	j.AppendBatch(map[string]string{"1|2|aa": "සිංහල"})
	j.Close()
	f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"k":"torn`) // simulated crash mid-write
	f.Close()
	j2, _ := OpenJournal(p, "m1", promptVersion)
	if si, ok := j2.Lookup("1|2|aa"); !ok || si != "සිංහල" || j2.Loaded != 1 {
		t.Fatalf("resume failed: %q %v %d", si, ok, j2.Loaded)
	}
	j2.Close()
	j3, _ := OpenJournal(p, "other-model", promptVersion)
	if j3.Loaded != 0 {
		t.Fatalf("a different model must not reuse translations")
	}
	j3.Close()
}

func TestAcceptItemsRejectsBadMapping(t *testing.T) {
	dir := t.TempDir()
	j, _ := OpenJournal(filepath.Join(dir, "j.jsonl"), "m", promptVersion)
	s := NewStore(j)
	for i, txt := range []string{"First line here.", "Second line here.", "Third line here.", "Fourth line here."} {
		s.Add(rawCue{StartMs: int64(i * 3000), EndMs: int64(i*3000 + 2000), Text: txt})
	}
	tr := NewTranslator(&GeminiClient{}, s, j, nil, 1, 4, 4)
	batch := s.TakeBatch(4, 0, 1e9, true)
	ids := []int{batch[0].ID, batch[1].ID, batch[2].ID, batch[3].ID}
	items := []tResp{
		{ids[0], "පළමු පේළිය"},
		{ids[1], "එකම පිළිතුර මෙතන"}, // alignment slip: same Sinhala twice
		{ids[2], "එකම පිළිතුර මෙතන"},
		{999, "unknown"},
		// ids[3] missing
	}
	n := tr.acceptItems(batch, items)
	if n != 1 {
		t.Fatalf("only the first cue should be accepted, got %d", n)
	}
	total, translated, _, pending := s.Counts()
	if total != 4 || translated != 1 || pending != 3 {
		t.Fatalf("counts total=%d translated=%d pending=%d", total, translated, pending)
	}
	if tr.stats.Rejected["alignment-slip"] != 2 || tr.stats.Rejected["missing-id"] != 1 || tr.stats.Rejected["unknown-id"] != 1 {
		t.Fatalf("reject reasons: %v", tr.stats.Rejected)
	}
}

func TestTakeBatchPrioritisesPlayhead(t *testing.T) {
	s := NewStore(nil)
	for i := 0; i < 20; i++ {
		s.Add(rawCue{StartMs: int64(i * 10_000), EndMs: int64(i*10_000 + 2000), Text: "line " + string(rune('a'+i))})
	}
	b := s.TakeBatch(3, 100_000, 1e9, true)
	if len(b) != 3 || b[0].StartMs != 100_000 || b[2].StartMs != 120_000 {
		t.Fatalf("expected cues from the playhead first, got %d..%d", b[0].StartMs, b[len(b)-1].StartMs)
	}
}

// TestOffsetExtractionMatchesPlayerTimeline encodes a short MKV whose
// container start time is negative (AAC priming, as in many real releases),
// then checks that extraction started mid-file yields exactly the cue times
// ffmpeg produces for a full extraction (which matches mpv's rebased
// timeline for embedded tracks).
func TestOffsetExtractionMatchesPlayerTimeline(t *testing.T) {
	ff, err1 := exec.LookPath("ffmpeg")
	fp, err2 := exec.LookPath("ffprobe")
	if err1 != nil || err2 != nil {
		t.Skip("ffmpeg/ffprobe not installed")
	}
	dir := t.TempDir()
	var b strings.Builder
	for i := 0; i < 50; i++ {
		st := int64(1500 + i*2400 + (i%3)*111)
		b.WriteString(formatSrtTime(st) + " --> " + formatSrtTime(st+1800) + "\nCue number " + string(rune('A'+i%26)) + " " + strings.Repeat("x", i%5) + "\n\n")
	}
	srt := filepath.Join(dir, "en.srt")
	os.WriteFile(srt, []byte(numberSRT(b.String())), 0o644)
	mkv := filepath.Join(dir, "t.mkv")
	cmd := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=10",
		"-f", "lavfi", "-i", "sine=frequency=300:sample_rate=48000", "-i", srt, "-t", "125",
		"-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-preset", "ultrafast", "-g", "20",
		"-c:a", "aac", "-c:s", "srt", "-metadata:s:s:0", "language=eng", mkv)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("cannot encode test file: %v %s", err, out)
	}
	pr, err := ffprobe(context.Background(), fp, mkv, -1)
	if err != nil || pr.Chosen == nil {
		t.Fatalf("probe: %v %+v", err, pr)
	}
	if pr.StartTimeMs == 0 {
		t.Log("note: container start time is 0 on this ffmpeg build; correction not exercised")
	}
	// Reference: full extraction without -copyts (ffmpeg rebases to start time).
	full := filepath.Join(dir, "full.srt")
	if out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-y", "-i", mkv, "-map", "0:2", "-c:s", "srt", full).CombinedOutput(); err != nil {
		t.Fatalf("full extract: %v %s", err, out)
	}
	ref := map[string]bool{}
	f, _ := os.Open(full)
	StreamSRT(f, func(c rawCue) { ref[cueKey(c.StartMs, c.EndMs, c.Text)] = true })
	f.Close()

	s := NewStore(nil)
	x := NewExtractor(ff, mkv, pr.Chosen.Index, pr.StartTimeMs, pr.DurationMs, s, nil)
	x.StartAt(60_000)
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, complete, _ := x.FrontFor(70_000); complete {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	snap := s.Snapshot()
	if len(snap) < 20 {
		t.Fatalf("offset extraction produced only %d cues", len(snap))
	}
	for _, c := range snap {
		if !ref[c.Key] {
			t.Fatalf("cue %s --> %s %q not in full extraction (start time correction %d ms)", formatSrtTime(c.StartMs), formatSrtTime(c.EndMs), c.English, pr.StartTimeMs)
		}
	}
	t.Logf("%d offset-extracted cues identical to full extraction; start time %d ms", len(snap), pr.StartTimeMs)
}

func numberSRT(s string) string {
	var out strings.Builder
	n := 1
	for _, block := range strings.Split(strings.TrimSpace(s), "\n\n") {
		out.WriteString(itoa(n) + "\n" + block + "\n\n")
		n++
	}
	return out.String()
}

func itoa(n int) string { return strings.TrimSpace(strings.Repeat(" ", 0) + fmtInt(n)) }

func fmtInt(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}

func TestCapacityIgnoresTinyRequestBias(t *testing.T) {
	tr := NewTranslator(&GeminiClient{}, NewStore(nil), nil, nil, 2, 12, 30)
	// One 1-cue request that took 12 s (fixed overhead) and one 12-cue request at 12.3 s.
	tr.samples = []latSample{{1, 12.0}, {12, 12.3}}
	c, _ := tr.Capacity()
	// fit: ~11.98 + 0.027*size -> ~12.8 s for 30 cues -> 2*30/12.8 ≈ 4.7 cues/s
	if c < 3 || c > 6 {
		t.Fatalf("capacity %.2f cues/s; expected a full-batch estimate near 4.7", c)
	}
	tr.samples = []latSample{{30, 20}, {30, 24}, {28, 22}}
	c, _ = tr.Capacity()
	if c < 2.4 || c > 2.8 { // 2*30/24 = 2.5
		t.Fatalf("capacity %.2f with full batches; want ≈2.5", c)
	}
}
