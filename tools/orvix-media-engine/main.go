package main

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	engineName    = "orvix-media-engine"
	engineVersion = 1
)

type prepareRequest struct {
	VideoURL            string `json:"videoUrl"`
	PreferredTrackLabel string `json:"preferredTrackLabel,omitempty"`
}

type prepareResponse struct {
	OK             bool   `json:"ok"`
	Engine         string `json:"engine"`
	Version        int    `json:"version"`
	EmbeddedFound  bool   `json:"embeddedFound"`
	EmbeddedSRT    string `json:"embeddedSrt,omitempty"`
	EmbeddedLabel  string `json:"embeddedLabel,omitempty"`
	EmbeddedCodec  string `json:"embeddedCodec,omitempty"`
	EmbeddedStream int    `json:"embeddedStreamIndex,omitempty"`
	MovieHash      string `json:"movieHash,omitempty"`
	MovieByteSize  int64  `json:"movieByteSize,omitempty"`
	ProbeError     string `json:"probeError,omitempty"`
	HashError      string `json:"hashError,omitempty"`
}

type ffprobeOutput struct {
	Streams []ffprobeStream `json:"streams"`
}

type ffprobeStream struct {
	Index       int               `json:"index"`
	CodecName   string            `json:"codec_name"`
	Tags        map[string]string `json:"tags"`
	Disposition struct {
		Forced          int `json:"forced"`
		HearingImpaired int `json:"hearing_impaired"`
	} `json:"disposition"`
}

type subtitleCandidate struct {
	Index    int
	Codec    string
	Language string
	Title    string
	Score    int
}

type server struct {
	httpClient  *http.Client
	idleTimeout time.Duration
	lastMu      sync.Mutex
	lastRequest time.Time
}

func main() {
	port := flag.Int("port", 11471, "loopback HTTP port")
	idle := flag.Duration("idle-timeout", 10*time.Minute, "exit after this much idle time")
	flag.Parse()

	s := &server{
		httpClient: &http.Client{
			Timeout: 35 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 8 {
					return errors.New("too many redirects")
				}
				return nil
			},
		},
		idleTimeout: *idle,
		lastRequest: time.Now(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/heartbeat", s.touch(s.heartbeat))
	mux.HandleFunc("/capabilities", s.touch(s.capabilities))
	mux.HandleFunc("/prepare", s.touch(s.prepare))

	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(*port))
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go s.watchIdle(httpServer)

	log.Printf("%s v%d listening on http://%s", engineName, engineVersion, addr)
	err := httpServer.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (s *server) touch(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.lastMu.Lock()
		s.lastRequest = time.Now()
		s.lastMu.Unlock()
		next(w, r)
	}
}

func (s *server) watchIdle(httpServer *http.Server) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.lastMu.Lock()
		idleFor := time.Since(s.lastRequest)
		s.lastMu.Unlock()
		if idleFor < s.idleTimeout {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_ = httpServer.Shutdown(ctx)
		cancel()
		return
	}
}

func (s *server) heartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"name":    engineName,
		"version": engineVersion,
	})
}

func (s *server) capabilities(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":                       engineName,
		"version":                    engineVersion,
		"prePlayerPreparation":       true,
		"embeddedTextExtraction":     true,
		"openSubtitlesFingerprint":   true,
		"requiresPlayerForDiscovery": false,
	})
}

func (s *server) prepare(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	var req prepareRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, 256*1024))
	if err := dec.Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	req.VideoURL = strings.TrimSpace(req.VideoURL)
	if !strings.HasPrefix(req.VideoURL, "http://") && !strings.HasPrefix(req.VideoURL, "https://") {
		http.Error(w, "videoUrl must be HTTP/HTTPS", http.StatusBadRequest)
		return
	}

	var (
		candidate *subtitleCandidate
		srt       string
		probeErr  error
		hash      string
		size      int64
		hashErr   error
		wg        sync.WaitGroup
	)

	wg.Add(2)
	go func() {
		defer wg.Done()
		candidate, srt, probeErr = probeAndExtract(r.Context(), req.VideoURL, req.PreferredTrackLabel)
	}()
	go func() {
		defer wg.Done()
		hash, size, hashErr = s.openSubtitlesFingerprint(r.Context(), req.VideoURL)
	}()
	wg.Wait()

	resp := prepareResponse{
		OK:            true,
		Engine:        engineName,
		Version:       engineVersion,
		MovieHash:     hash,
		MovieByteSize: size,
	}
	if probeErr != nil {
		resp.ProbeError = probeErr.Error()
	}
	if hashErr != nil {
		resp.HashError = hashErr.Error()
	}
	if candidate != nil && strings.Contains(srt, "-->") {
		resp.EmbeddedFound = true
		resp.EmbeddedSRT = srt
		resp.EmbeddedLabel = candidateLabel(*candidate)
		resp.EmbeddedCodec = candidate.Codec
		resp.EmbeddedStream = candidate.Index
	}
	writeJSON(w, http.StatusOK, resp)
}

func probeAndExtract(ctx context.Context, videoURL, preferred string) (*subtitleCandidate, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 75*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ffprobe",
		"-v", "error",
		"-rw_timeout", "30000000",
		"-probesize", "12000000",
		"-analyzeduration", "12000000",
		"-select_streams", "s",
		"-show_entries", "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
		"-of", "json",
		videoURL,
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, "", fmt.Errorf("ffprobe failed: %w", err)
	}

	var parsed ffprobeOutput
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, "", fmt.Errorf("invalid ffprobe JSON: %w", err)
	}

	candidates := make([]subtitleCandidate, 0, len(parsed.Streams))
	for _, stream := range parsed.Streams {
		codec := strings.ToLower(strings.TrimSpace(stream.CodecName))
		if codec == "" || isBitmapSubtitle(codec) {
			continue
		}
		lang := strings.ToLower(strings.TrimSpace(stream.Tags["language"]))
		title := strings.TrimSpace(stream.Tags["title"])
		if knownNonEnglish(lang) {
			continue
		}
		score := englishScore(lang, title, codec, preferred, stream.Disposition.Forced != 0, stream.Disposition.HearingImpaired != 0)
		if score <= 0 && !safelyUnlabeled(lang, title, stream.Disposition.Forced != 0) {
			continue
		}
		candidates = append(candidates, subtitleCandidate{
			Index: stream.Index, Codec: codec, Language: lang, Title: title, Score: score,
		})
	}
	if len(candidates) == 0 {
		return nil, "", nil
	}

	for i := 0; i < len(candidates); i++ {
		for j := i + 1; j < len(candidates); j++ {
			if candidates[j].Score > candidates[i].Score {
				candidates[i], candidates[j] = candidates[j], candidates[i]
			}
		}
	}

	for _, candidate := range candidates {
		extractCtx, cancelExtract := context.WithTimeout(ctx, 4*time.Minute)
		mapArg := fmt.Sprintf("0:%d", candidate.Index)
		ffmpeg := exec.CommandContext(extractCtx, "ffmpeg",
			"-hide_banner", "-loglevel", "error", "-y",
			"-rw_timeout", "30000000",
			"-i", videoURL,
			"-map", mapArg,
			"-vn", "-an", "-dn",
			"-c:s", "srt",
			"-f", "srt",
			"-",
		)
		data, err := ffmpeg.Output()
		cancelExtract()
		if err != nil {
			continue
		}
		text := strings.TrimSpace(string(data))
		if strings.Count(text, "-->") < 8 {
			continue
		}
		if candidate.Score <= 0 && !looksEnglish(text) {
			continue
		}
		c := candidate
		return &c, text, nil
	}
	return nil, "", nil
}

func (s *server) openSubtitlesFingerprint(ctx context.Context, videoURL string) (string, int64, error) {
	size, err := s.remoteSize(ctx, videoURL)
	if err != nil {
		return "", 0, err
	}
	if size < 131072 {
		return "", size, fmt.Errorf("media too small for OpenSubtitles hash: %d", size)
	}

	first, err := s.readRange(ctx, videoURL, 0, 65535)
	if err != nil {
		return "", size, fmt.Errorf("first range: %w", err)
	}
	lastStart := size - 65536
	last, err := s.readRange(ctx, videoURL, lastStart, size-1)
	if err != nil {
		return "", size, fmt.Errorf("last range: %w", err)
	}
	if len(first) < 65536 || len(last) < 65536 {
		return "", size, errors.New("range server returned incomplete fingerprint windows")
	}

	sum := uint64(size)
	for _, buf := range [][]byte{first[:65536], last[:65536]} {
		for i := 0; i+8 <= len(buf); i += 8 {
			sum += binary.LittleEndian.Uint64(buf[i : i+8])
		}
	}
	raw := make([]byte, 8)
	binary.BigEndian.PutUint64(raw, sum)
	return hex.EncodeToString(raw), size, nil
}

func (s *server) remoteSize(ctx context.Context, videoURL string) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, videoURL, nil)
	if err == nil {
		if resp, e := s.httpClient.Do(req); e == nil {
			resp.Body.Close()
			if resp.ContentLength > 0 {
				return resp.ContentLength, nil
			}
		}
	}

	req, err = http.NewRequestWithContext(ctx, http.MethodGet, videoURL, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Range", "bytes=0-0")
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return 0, fmt.Errorf("range size probe returned HTTP %d", resp.StatusCode)
	}
	contentRange := resp.Header.Get("Content-Range")
	slash := strings.LastIndex(contentRange, "/")
	if slash < 0 {
		return 0, errors.New("missing total size in Content-Range")
	}
	total, err := strconv.ParseInt(strings.TrimSpace(contentRange[slash+1:]), 10, 64)
	if err != nil || total <= 0 {
		return 0, errors.New("invalid total size in Content-Range")
	}
	return total, nil
}

func (s *server) readRange(ctx context.Context, videoURL string, start, end int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, videoURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return nil, fmt.Errorf("expected HTTP 206, got %d", resp.StatusCode)
	}
	want := end - start + 1
	return io.ReadAll(io.LimitReader(resp.Body, want))
}

func candidateLabel(c subtitleCandidate) string {
	parts := make([]string, 0, 3)
	if c.Language != "" {
		parts = append(parts, c.Language)
	}
	if c.Title != "" {
		parts = append(parts, c.Title)
	}
	if c.Codec != "" {
		parts = append(parts, c.Codec)
	}
	if len(parts) == 0 {
		return "English embedded"
	}
	return strings.Join(parts, " • ")
}

func isBitmapSubtitle(codec string) bool {
	switch codec {
	case "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvb_subtitle", "dvb_teletext", "xsub":
		return true
	default:
		return false
	}
}

func knownNonEnglish(lang string) bool {
	lang = strings.ToLower(strings.TrimSpace(lang))
	if lang == "" || lang == "und" || lang == "unknown" || lang == "undefined" {
		return false
	}
	return lang != "eng" && lang != "en" && lang != "english" && !strings.HasPrefix(lang, "en-")
}

func safelyUnlabeled(lang, title string, forced bool) bool {
	if forced {
		return false
	}
	lang = strings.ToLower(strings.TrimSpace(lang))
	title = strings.ToLower(strings.TrimSpace(title))
	unknown := lang == "" || lang == "und" || lang == "unknown" || lang == "undefined"
	generic := title == "" || title == "default" || title == "subtitle" || title == "subtitles" || title == "full"
	return unknown && generic
}

func englishScore(lang, title, codec, preferred string, forced, hearing bool) int {
	combined := strings.ToLower(strings.TrimSpace(lang + " " + title + " " + codec))
	score := 0
	if lang == "eng" || lang == "en" || lang == "english" {
		score += 180
	}
	if strings.Contains(strings.ToLower(title), "english") {
		score += 150
	}
	if strings.Contains(combined, " eng ") || strings.HasPrefix(combined, "eng ") || strings.HasSuffix(combined, " eng") {
		score += 120
	}
	preferred = strings.ToLower(strings.TrimSpace(preferred))
	if preferred != "" {
		for _, token := range strings.Fields(preferred) {
			if len(token) >= 2 && strings.Contains(combined, token) {
				score += 16
			}
		}
	}
	titleLower := strings.ToLower(title)
	if forced || strings.Contains(titleLower, "forced") {
		score -= 120
	}
	if strings.Contains(titleLower, "commentary") {
		score -= 220
	}
	if strings.Contains(titleLower, "foreign") || strings.Contains(titleLower, "signs") || strings.Contains(titleLower, "songs") {
		score -= 100
	}
	if hearing || strings.Contains(titleLower, "sdh") || strings.Contains(titleLower, "hearing") {
		score -= 15
	}
	return score
}

func looksEnglish(raw string) bool {
	lower := strings.ToLower(raw)
	replacer := strings.NewReplacer("\r", " ", "\n", " ", "<i>", " ", "</i>", " ")
	lower = replacer.Replace(lower)
	fields := strings.Fields(lower)
	if len(fields) < 12 {
		return false
	}
	common := map[string]bool{
		"the": true, "and": true, "you": true, "that": true, "this": true,
		"with": true, "have": true, "what": true, "for": true, "not": true,
		"are": true, "your": true, "but": true, "from": true, "they": true,
		"will": true, "just": true, "can": true, "was": true, "there": true,
		"here": true, "about": true, "know": true, "like": true, "want": true,
		"get": true, "got": true,
	}
	hits := 0
	for _, field := range fields {
		word := strings.Trim(field, "0123456789:,.!?;\"'()[]{}<>-/\\")
		if common[word] {
			hits++
			if hits >= 3 {
				return true
			}
		}
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
