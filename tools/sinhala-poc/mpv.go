package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Mpv is a strictly sequential JSON-IPC client: one request, then read lines
// until the matching reply. All events are disabled, so no concurrent reader
// is needed (Windows named pipes opened synchronously cannot read and write
// at the same time).
type Mpv struct {
	mu   sync.Mutex
	conn io.ReadWriteCloser
	rd   *bufio.Reader
	next int
	cmd  *exec.Cmd
}

var errMpvGone = errors.New("mpv IPC closed")

func ConnectMpv(endpoint string, timeout time.Duration) (*Mpv, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		c, err := dialIPC(endpoint)
		if err == nil {
			m := &Mpv{conn: c, rd: bufio.NewReaderSize(c, 1<<20)}
			if _, err := m.Command("disable_event", "all"); err != nil {
				c.Close()
				return nil, err
			}
			return m, nil
		}
		lastErr = err
		time.Sleep(150 * time.Millisecond)
	}
	return nil, fmt.Errorf("could not connect to mpv IPC %s: %v", endpoint, lastErr)
}

type mpvReply struct {
	Error     string          `json:"error"`
	Data      json.RawMessage `json:"data"`
	RequestID int             `json:"request_id"`
	Event     string          `json:"event"`
}

func (m *Mpv) Command(args ...any) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.conn == nil {
		return nil, errMpvGone
	}
	m.next++
	id := m.next
	b, _ := json.Marshal(map[string]any{"command": args, "request_id": id})
	b = append(b, '\n')
	if _, err := m.conn.Write(b); err != nil {
		m.conn.Close()
		m.conn = nil
		return nil, errMpvGone
	}
	for {
		line, err := m.rd.ReadBytes('\n')
		if err != nil {
			m.conn.Close()
			m.conn = nil
			return nil, errMpvGone
		}
		var r mpvReply
		if json.Unmarshal(line, &r) != nil || r.Event != "" {
			continue
		}
		if r.RequestID != id {
			continue
		}
		if r.Error != "success" {
			return nil, fmt.Errorf("mpv %v: %s", args[0], r.Error)
		}
		return r.Data, nil
	}
}

func (m *Mpv) GetFloat(prop string) (float64, bool) {
	d, err := m.Command("get_property", prop)
	if err != nil || len(d) == 0 || string(d) == "null" {
		return 0, false
	}
	var f float64
	if json.Unmarshal(d, &f) != nil {
		return 0, false
	}
	return f, true
}

func (m *Mpv) GetBool(prop string) (bool, bool) {
	d, err := m.Command("get_property", prop)
	if err != nil {
		return false, false
	}
	var v bool
	if json.Unmarshal(d, &v) != nil {
		return false, false
	}
	return v, true
}

func (m *Mpv) GetString(prop string) (string, bool) {
	d, err := m.Command("get_property", prop)
	if err != nil {
		return "", false
	}
	var v string
	if json.Unmarshal(d, &v) != nil {
		return "", false
	}
	return v, true
}

func (m *Mpv) Set(prop string, v any) error {
	_, err := m.Command("set_property", prop, v)
	return err
}

type mpvTrack struct {
	ID               int    `json:"id"`
	Type             string `json:"type"`
	Selected         bool   `json:"selected"`
	External         bool   `json:"external"`
	ExternalFilename string `json:"external-filename"`
	FFIndex          *int   `json:"ff-index"`
	Lang             string `json:"lang"`
	Title            string `json:"title"`
	MainSelection    *int   `json:"main-selection"`
}

func (m *Mpv) Tracks() ([]mpvTrack, error) {
	d, err := m.Command("get_property", "track-list")
	if err != nil {
		return nil, err
	}
	var t []mpvTrack
	return t, json.Unmarshal(d, &t)
}

func (m *Mpv) Alive() bool {
	_, err := m.Command("get_property", "pid")
	return err == nil || !errors.Is(err, errMpvGone)
}

func (m *Mpv) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.conn != nil {
		m.conn.Close()
		m.conn = nil
	}
}

func sameFile(a, b string) bool {
	norm := func(s string) string {
		s = strings.ReplaceAll(s, "\\", "/")
		return strings.ToLower(strings.TrimPrefix(s, "file://"))
	}
	return norm(a) == norm(b) || strings.HasSuffix(norm(a), "/"+lastPath(norm(b)))
}

func lastPath(s string) string {
	if i := strings.LastIndex(s, "/"); i >= 0 {
		return s[i+1:]
	}
	return s
}
