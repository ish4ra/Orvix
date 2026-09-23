package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestOpenSubtitlesFingerprintUsesFirstAndLast64KiB(t *testing.T) {
	data := make([]byte, 200000)
	for i := range data {
		data[i] = byte((i * 31) % 251)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			w.WriteHeader(http.StatusOK)
			return
		}

		rangeHeader := r.Header.Get("Range")
		if rangeHeader == "" {
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			_, _ = w.Write(data)
			return
		}

		var start, end int
		if _, err := fmt.Sscanf(rangeHeader, "bytes=%d-%d", &start, &end); err != nil {
			http.Error(w, "bad range", http.StatusBadRequest)
			return
		}
		if start < 0 || end < start || end >= len(data) {
			http.Error(w, "bad range", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set(
			"Content-Range",
			fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)),
		)
		w.Header().Set("Content-Length", strconv.Itoa(end-start+1))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.Copy(w, bytes.NewReader(data[start:end+1]))
	})
	ts := httptest.NewServer(handler)
	defer ts.Close()

	s := &server{httpClient: ts.Client()}
	gotHash, gotSize, err := s.openSubtitlesFingerprint(context.Background(), ts.URL+"/video.mkv")
	if err != nil {
		t.Fatalf("fingerprint failed: %v", err)
	}
	if gotSize != int64(len(data)) {
		t.Fatalf("size = %d, want %d", gotSize, len(data))
	}

	sum := uint64(len(data))
	for _, buf := range [][]byte{data[:65536], data[len(data)-65536:]} {
		for i := 0; i < len(buf); i += 8 {
			sum += binary.LittleEndian.Uint64(buf[i : i+8])
		}
	}
	wantHash := fmt.Sprintf("%016x", sum)
	if gotHash != wantHash {
		t.Fatalf("hash = %s, want %s", gotHash, wantHash)
	}
}

func TestEnglishScoringRejectsCommentaryAndBitmap(t *testing.T) {
	normal := englishScore("eng", "English", "subrip", "", false, false)
	commentary := englishScore("eng", "English Commentary", "ass", "", false, false)
	if normal <= commentary {
		t.Fatalf("normal score %d should beat commentary %d", normal, commentary)
	}
	if !isBitmapSubtitle("hdmv_pgs_subtitle") {
		t.Fatal("PGS must be classified as bitmap")
	}
	if knownNonEnglish("eng") {
		t.Fatal("English must not be classified as non-English")
	}
	if !knownNonEnglish("spa") {
		t.Fatal("Spanish must be classified as non-English")
	}
}

func TestPreparedMediaSessionProxiesExactRanges(t *testing.T) {
	data := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			w.Header().Set("Accept-Ranges", "bytes")
			w.WriteHeader(http.StatusOK)
			return
		}
		if value := r.Header.Get("Range"); value != "" {
			var start, end int
			if _, err := fmt.Sscanf(value, "bytes=%d-%d", &start, &end); err != nil {
				http.Error(w, "bad range", http.StatusBadRequest)
				return
			}
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set(
				"Content-Range",
				fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)),
			)
			w.Header().Set("Content-Length", strconv.Itoa(end-start+1))
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(data[start : end+1])
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		_, _ = w.Write(data)
	}))
	defer origin.Close()

	s := &server{
		httpClient:  origin.Client(),
		proxyClient: origin.Client(),
		sessions:    make(map[string]string),
		lastRequest: time.Now(),
	}
	sessionID, err := s.newSession(origin.URL + "/video.mkv")
	if err != nil {
		t.Fatalf("newSession failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/media/"+sessionID, nil)
	req.Header.Set("Range", "bytes=5-12")
	rec := httptest.NewRecorder()
	s.media(rec, req)

	if rec.Code != http.StatusPartialContent {
		t.Fatalf("status = %d, want 206", rec.Code)
	}
	if got, want := rec.Body.String(), string(data[5:13]); got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
	if got := rec.Header().Get("Content-Range"); got == "" {
		t.Fatal("Content-Range must be forwarded")
	}
}

func TestLooksEnglish(t *testing.T) {
	text := strings.Repeat(
		"the way you know this is what we have and this is where you are going\n",
		4,
	)
	if !looksEnglish(text) {
		t.Fatal("expected English dialogue to be recognized")
	}
}
