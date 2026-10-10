package main

import (
	"bytes"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// P2P uses the Orvix stream server (the same engine Orvix uses for Free P2P)
// on 127.0.0.1:11470 to turn a magnet + file index into a local HTTP URL.

const streamBase = "http://127.0.0.1:11470"

var btihRe = regexp.MustCompile(`(?i)xt=urn:btih:([a-z0-9]+)`)

func infoHashFromMagnet(magnet string) (string, error) {
	m := btihRe.FindStringSubmatch(magnet)
	if m == nil {
		if len(magnet) == 40 {
			if _, err := hex.DecodeString(magnet); err == nil {
				return strings.ToLower(magnet), nil
			}
		}
		return "", fmt.Errorf("no btih info hash in magnet")
	}
	h := m[1]
	switch len(h) {
	case 40:
		return strings.ToLower(h), nil
	case 32:
		b, err := base32.StdEncoding.DecodeString(strings.ToUpper(h))
		if err != nil {
			return "", err
		}
		return hex.EncodeToString(b), nil
	}
	return "", fmt.Errorf("unexpected info hash length %d", len(h))
}

func streamServerAlive() bool {
	c := http.Client{Timeout: 2 * time.Second}
	r, err := c.Get(streamBase + "/heartbeat")
	if err != nil {
		return false
	}
	r.Body.Close()
	return r.StatusCode < 500
}

// startStreamServer launches the stream server bundled with an installed Orvix.
func startStreamServer(orvixDir string, ev *EventLog) (*exec.Cmd, error) {
	exe := filepath.Join(orvixDir, "orvix-stream-server"+exeSuffix)
	if _, err := os.Stat(exe); err != nil {
		return nil, fmt.Errorf("stream server not found at %s", exe)
	}
	work := filepath.Join(os.Getenv("LOCALAPPDATA"), "Orvix", "torrent-engine")
	if os.Getenv("LOCALAPPDATA") == "" {
		work = filepath.Join(os.TempDir(), "orvix-poc-torrent-engine")
	}
	os.MkdirAll(work, 0o755)
	cmd := exec.Command(exe, "--no-tray")
	cmd.Dir = work
	ffbin := filepath.Join(orvixDir, "tools", "ffmpeg", "bin")
	cmd.Env = append(os.Environ(), "PATH="+ffbin+string(os.PathListSeparator)+os.Getenv("PATH"))
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	for i := 0; i < 80; i++ {
		if streamServerAlive() {
			ev.Log("stream-server-started", map[string]any{"exe": exe})
			return cmd, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	cmd.Process.Kill()
	return nil, fmt.Errorf("stream server did not answer /heartbeat")
}

var fallbackTrackers = []string{
	"udp://tracker.opentrackr.org:1337/announce",
	"udp://open.stealth.si:80/announce",
	"udp://tracker.openbittorrent.com:6969/announce",
	"udp://exodus.desync.com:6969/announce",
	"udp://tracker.torrent.eu.org:451/announce",
}

type p2pSource struct {
	InfoHash string
	FileIdx  int
	FileName string
	URL      string
}

func createP2PStream(magnet string, fileIdx int, fileHint string, ev *EventLog) (*p2pSource, error) {
	hash, err := infoHashFromMagnet(magnet)
	if err != nil {
		return nil, err
	}
	sources := []string{"dht:" + hash}
	if u, err := url.Parse(magnet); err == nil {
		for _, tr := range u.Query()["tr"] {
			sources = append(sources, "tracker:"+tr)
		}
	}
	for _, tr := range fallbackTrackers {
		sources = append(sources, "tracker:"+tr)
	}
	from := magnet
	if !strings.HasPrefix(strings.ToLower(magnet), "magnet:") {
		from = "magnet:?xt=urn:btih:" + hash
	}
	body := map[string]any{"from": from, "guessFileIdx": true, "peerSearch": map[string]any{"sources": sources}}
	if fileHint != "" {
		body["fileMustInclude"] = []string{fileHint}
	}
	js, _ := json.Marshal(body)
	c := http.Client{Timeout: 90 * time.Second}
	t0 := time.Now()
	resp, err := c.Post(streamBase+"/create", "application/json", bytes.NewReader(js))
	if err != nil {
		return nil, fmt.Errorf("stream server /create: %w", err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("stream server /create HTTP %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var payload map[string]any
	json.Unmarshal(raw, &payload)
	type file struct {
		name string
		size float64
	}
	var files []file
	if arr, ok := payload["files"].([]any); ok {
		for _, f := range arr {
			if m, ok := f.(map[string]any); ok {
				name, _ := m["name"].(string)
				if name == "" {
					name, _ = m["path"].(string)
				}
				size, _ := m["length"].(float64)
				files = append(files, file{name, size})
			}
		}
	}
	chosen := fileIdx
	if chosen < 0 && fileHint != "" {
		for i, f := range files {
			if strings.Contains(strings.ToLower(f.name), strings.ToLower(fileHint)) {
				chosen = i
				break
			}
		}
	}
	if chosen < 0 {
		if g, ok := payload["guessedFileIdx"].(float64); ok {
			chosen = int(g)
		}
	}
	if chosen < 0 {
		best := -1.0
		for i, f := range files {
			if isVideoName(f.name) && f.size > best {
				best, chosen = f.size, i
			}
		}
	}
	if chosen < 0 {
		return nil, fmt.Errorf("could not choose a file; pass --file-idx (files: %d)", len(files))
	}
	name := ""
	if chosen < len(files) {
		name = files[chosen].name
	}
	src := &p2pSource{InfoHash: hash, FileIdx: chosen, FileName: name, URL: fmt.Sprintf("%s/%s/%d", streamBase, hash, chosen)}
	list := []string{}
	for i, f := range files {
		if i < 60 {
			list = append(list, fmt.Sprintf("%d: %s (%.0f MB)", i, f.name, f.size/1e6))
		}
	}
	ev.Log("p2p-created", map[string]any{"infoHash": hash, "fileIdx": chosen, "fileName": name, "createMs": time.Since(t0).Milliseconds(), "files": list})
	return src, nil
}

func p2pStats(src *p2pSource) map[string]any {
	c := http.Client{Timeout: 3 * time.Second}
	r, err := c.Get(fmt.Sprintf("%s/%s/%d/stats.json", streamBase, src.InfoHash, src.FileIdx))
	if err != nil {
		return nil
	}
	defer r.Body.Close()
	var m map[string]any
	json.NewDecoder(r.Body).Decode(&m)
	keep := map[string]any{}
	for _, k := range []string{"downloaded", "uploaded", "downloadSpeed", "peers", "streamProgress", "streamLen", "unchoked", "queued"} {
		if v, ok := m[k]; ok {
			keep[k] = v
		}
	}
	return keep
}

func isVideoName(n string) bool {
	n = strings.ToLower(n)
	for _, e := range []string{".mkv", ".mp4", ".avi", ".m4v", ".mov", ".webm", ".ts"} {
		if strings.HasSuffix(n, e) {
			return true
		}
	}
	return false
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
