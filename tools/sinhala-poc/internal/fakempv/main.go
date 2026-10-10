// fakempv simulates the small part of mpv's JSON IPC that sinhala-poc uses,
// for automated tests on machines without a real player. It is NOT playback
// evidence. It models: a clock (with speed factor), pause, seek, keep-open,
// one external subtitle file (sub-add / sub-reload) and an embedded
// reference subtitle track whose cue times follow mpv's start-time rebase.
//
// Env: FAKE_MPV_REF_SRT (embedded track, already on the rebased timeline),
// FAKE_MPV_DURATION (seconds), FAKE_MPV_SPEED (clock multiplier).
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type cue struct {
	start, end float64
	text       string
}

var timeRe = regexp.MustCompile(`(\d+):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d+):(\d{2}):(\d{2})[,.](\d{3})`)

func ts(h, m, s, ms string) float64 {
	a, _ := strconv.Atoi(h)
	b, _ := strconv.Atoi(m)
	c, _ := strconv.Atoi(s)
	d, _ := strconv.Atoi(ms)
	return float64(a*3600+b*60+c) + float64(d)/1000
}

func loadSRT(path string) []cue {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []cue
	for _, block := range strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n\n") {
		lines := strings.Split(strings.TrimSpace(block), "\n")
		for i, l := range lines {
			if m := timeRe.FindStringSubmatch(l); m != nil {
				out = append(out, cue{ts(m[1], m[2], m[3], m[4]), ts(m[5], m[6], m[7], m[8]), strings.Join(lines[i+1:], "\n")})
				break
			}
		}
	}
	return out
}

func at(cs []cue, t float64) *cue {
	for i := range cs {
		if t >= cs[i].start && t < cs[i].end {
			return &cs[i]
		}
	}
	return nil
}

type player struct {
	mu       sync.Mutex
	pos      float64
	last     time.Time
	paused   bool
	speed    float64
	duration float64
	ext      []cue
	extPath  string
	extID    int
	sid      int
	secSid   int
	ref      []cue
	nextID   int
}

func (p *player) tick() {
	now := time.Now()
	if !p.paused {
		p.pos += now.Sub(p.last).Seconds() * p.speed
		if p.pos > p.duration {
			p.pos = p.duration
		}
	}
	p.last = now
}

func main() {
	var ipc, start string
	for _, a := range os.Args[1:] {
		if strings.HasPrefix(a, "--input-ipc-server=") {
			ipc = strings.TrimPrefix(a, "--input-ipc-server=")
		}
		if strings.HasPrefix(a, "--start=") {
			start = strings.TrimPrefix(a, "--start=")
		}
	}
	speed, _ := strconv.ParseFloat(os.Getenv("FAKE_MPV_SPEED"), 64)
	if speed <= 0 {
		speed = 1
	}
	dur, _ := strconv.ParseFloat(os.Getenv("FAKE_MPV_DURATION"), 64)
	st, _ := strconv.ParseFloat(start, 64)
	p := &player{pos: st, last: time.Now(), paused: true, speed: speed, duration: dur, ref: loadSRT(os.Getenv("FAKE_MPV_REF_SRT")), nextID: 1}
	os.Remove(ipc)
	ln, err := net.Listen("unix", ipc)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	conn, err := ln.Accept()
	if err != nil {
		os.Exit(1)
	}
	rd := bufio.NewReader(conn)
	for {
		line, err := rd.ReadBytes('\n')
		if err != nil {
			os.Exit(0)
		}
		var req struct {
			Command []any `json:"command"`
			ID      int   `json:"request_id"`
		}
		json.Unmarshal(line, &req)
		data, errStr := p.handle(req.Command)
		b, _ := json.Marshal(map[string]any{"error": errStr, "data": data, "request_id": req.ID})
		conn.Write(append(b, '\n'))
	}
}

func (p *player) handle(cmd []any) (any, string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tick()
	if len(cmd) == 0 {
		return nil, "invalid parameter"
	}
	name, _ := cmd[0].(string)
	arg := func(i int) string {
		if i < len(cmd) {
			return fmt.Sprint(cmd[i])
		}
		return ""
	}
	switch name {
	case "disable_event", "show-text":
		return nil, "success"
	case "get_property":
		var cur *cue
		if p.sid != 0 && p.sid == p.extID {
			cur = at(p.ext, p.pos)
		}
		var sec *cue
		if p.secSid != 0 {
			sec = at(p.ref, p.pos)
		}
		switch arg(1) {
		case "time-pos":
			return p.pos, "success"
		case "pause":
			return p.paused, "success"
		case "eof-reached":
			return p.pos >= p.duration, "success"
		case "duration":
			return p.duration, "success"
		case "demuxer-cache-duration":
			return 10.0, "success"
		case "pid":
			return os.Getpid(), "success"
		case "sub-text":
			if cur == nil {
				return "", "success"
			}
			return cur.text, "success"
		case "sub-start":
			if cur == nil {
				return nil, "success"
			}
			return cur.start, "success"
		case "secondary-sub-start":
			if sec == nil {
				return nil, "success"
			}
			return sec.start, "success"
		case "secondary-sub-text":
			if sec == nil {
				return "", "success"
			}
			return sec.text, "success"
		case "track-list":
			ff := 2
			tracks := []map[string]any{{"id": 1, "type": "sub", "external": false, "ff-index": ff, "selected": p.secSid == 1}}
			if p.extID != 0 {
				ms := 0
				tracks = append(tracks, map[string]any{"id": p.extID, "type": "sub", "external": true, "external-filename": p.extPath, "selected": p.sid == p.extID, "main-selection": ms})
			}
			return tracks, "success"
		}
		return nil, "property unavailable"
	case "set_property":
		switch arg(1) {
		case "pause":
			v, _ := cmd[2].(bool)
			p.paused = v
		case "sid":
			f, _ := cmd[2].(float64)
			p.sid = int(f)
		case "secondary-sid":
			f, _ := cmd[2].(float64)
			p.secSid = int(f)
		}
		return nil, "success"
	case "sub-add":
		p.extPath = arg(1)
		p.ext = loadSRT(p.extPath)
		p.nextID++
		p.extID = p.nextID
		p.sid = p.extID
		return nil, "success"
	case "sub-reload":
		// Real mpv unloads and re-adds the track; model the id change.
		p.ext = loadSRT(p.extPath)
		p.nextID++
		p.extID = p.nextID
		p.sid = p.extID
		return nil, "success"
	case "seek":
		f, _ := strconv.ParseFloat(arg(1), 64)
		if arg(2) == "absolute" {
			p.pos = f
		} else {
			p.pos += f
		}
		return nil, "success"
	}
	return nil, "invalid parameter"
}
