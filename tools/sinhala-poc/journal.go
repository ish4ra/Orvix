package main

import (
	"bufio"
	"encoding/json"
	"os"
	"sync"
	"time"
)

// Journal persists accepted translations so a retry or restart never starts
// from zero. One JSON object per line, appended and fsynced per batch.
// Entries are only reused when model and prompt version match.
type Journal struct {
	mu      sync.Mutex
	path    string
	f       *os.File
	entries map[string]string
	Loaded  int
	model   string
	prompt  string
}

type journalEntry struct {
	Key    string `json:"k"`
	Si     string `json:"si"`
	Model  string `json:"m"`
	Prompt string `json:"pv"`
	At     string `json:"t"`
}

func OpenJournal(path, model, promptVersion string) (*Journal, error) {
	j := &Journal{path: path, entries: map[string]string{}, model: model, prompt: promptVersion}
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
		for sc.Scan() {
			var e journalEntry
			if json.Unmarshal(sc.Bytes(), &e) != nil {
				continue // a torn final line after a crash is ignored
			}
			if e.Model == model && e.Prompt == promptVersion && e.Si != "" {
				j.entries[e.Key] = e.Si
			}
		}
		f.Close()
	}
	j.Loaded = len(j.entries)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	j.f = f
	return j, nil
}

func (j *Journal) Lookup(key string) (string, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	si, ok := j.entries[key]
	return si, ok
}

func (j *Journal) AppendBatch(pairs map[string]string) error {
	if len(pairs) == 0 {
		return nil
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	w := bufio.NewWriter(j.f)
	for k, si := range pairs {
		b, _ := json.Marshal(journalEntry{Key: k, Si: si, Model: j.model, Prompt: j.prompt, At: now})
		w.Write(b)
		w.WriteByte('\n')
		j.entries[k] = si
	}
	if err := w.Flush(); err != nil {
		return err
	}
	return j.f.Sync()
}

func (j *Journal) Close() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.f != nil {
		j.f.Close()
		j.f = nil
	}
}
