package main

import (
	"bufio"
	"encoding/json"
	"os"
	"sync"
)

// EnglishCache persists the extracted English timeline (cues + which media
// ranges were fully extracted) per source and subtitle stream, so a restart
// or a seek after a restart does not have to re-read the video.
type EnglishCache struct {
	mu sync.Mutex
	f  *os.File
}

type ecEntry struct {
	T     string `json:"t"` // "cue" | "cov"
	Start int64  `json:"s"`
	End   int64  `json:"e"`
	Text  string `json:"x,omitempty"`
}

func OpenEnglishCache(path string) (*EnglishCache, []rawCue, []interval, error) {
	var cues []rawCue
	var cov []interval
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
		for sc.Scan() {
			var e ecEntry
			if json.Unmarshal(sc.Bytes(), &e) != nil {
				continue
			}
			switch e.T {
			case "cue":
				cues = append(cues, rawCue{StartMs: e.Start, EndMs: e.End, Text: e.Text})
			case "cov":
				cov = mergeInterval(cov, interval{e.Start, e.End})
			}
		}
		f.Close()
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, nil, nil, err
	}
	return &EnglishCache{f: f}, cues, cov, nil
}

func (c *EnglishCache) write(e ecEntry) {
	if c == nil {
		return
	}
	b, _ := json.Marshal(e)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.f != nil {
		c.f.Write(append(b, '\n'))
	}
}

func (c *EnglishCache) Cue(rc rawCue) {
	c.write(ecEntry{T: "cue", Start: rc.StartMs, End: rc.EndMs, Text: rc.Text})
}
func (c *EnglishCache) Covered(iv interval) { c.write(ecEntry{T: "cov", Start: iv.From, End: iv.To}) }

func (c *EnglishCache) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.f != nil {
		c.f.Sync()
		c.f.Close()
		c.f = nil
	}
}
