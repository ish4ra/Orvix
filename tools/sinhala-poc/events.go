package main

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

// EventLog writes one JSON line per event with milliseconds since start.
type EventLog struct {
	mu  sync.Mutex
	f   *os.File
	t0  time.Time
	key string
}

func NewEventLog(path string, t0 time.Time, key string) (*EventLog, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &EventLog{f: f, t0: t0, key: key}, nil
}

func (e *EventLog) Log(kind string, data any) {
	if e == nil {
		return
	}
	b, _ := json.Marshal(map[string]any{"tMs": time.Since(e.t0).Milliseconds(), "kind": kind, "data": data})
	s := redact(string(b), e.key)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.f != nil {
		e.f.WriteString(s + "\n")
	}
}

func (e *EventLog) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.f != nil {
		e.f.Close()
		e.f = nil
	}
}
