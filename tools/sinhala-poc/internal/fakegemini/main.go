// fakegemini imitates the Gemini generateContent endpoint for automated
// tests: it echoes each cue id with Sinhala-script text, after a delay, and
// can inject failures. It is NOT evidence about the real API.
//
// Env: FAKE_GEMINI_ADDR (listen), FAKE_GEMINI_LATENCY_MS (base + per-cue),
// FAKE_GEMINI_FAULTS comma list: "ratelimit@3,malformed@5,dup@7,refuse:<word>,daily@40,english@9".
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var mu sync.Mutex
var calls int
var keysSeen = map[string]int{}

func main() {
	addr := os.Getenv("FAKE_GEMINI_ADDR")
	lat, _ := strconv.Atoi(os.Getenv("FAKE_GEMINI_LATENCY_MS"))
	faults := map[string]int{}
	refuseWord := ""
	for _, f := range strings.Split(os.Getenv("FAKE_GEMINI_FAULTS"), ",") {
		f = strings.TrimSpace(f)
		if strings.HasPrefix(f, "refuse:") {
			refuseWord = strings.TrimPrefix(f, "refuse:")
			continue
		}
		if kv := strings.SplitN(f, "@", 2); len(kv) == 2 {
			n, _ := strconv.Atoi(kv[1])
			faults[kv[0]] = n
		}
	}
	itemsRe := regexp.MustCompile(`(?s)CUES TO TRANSLATE \(JSON\):\n(\[.*\])`)
	http.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(w).Encode(keysSeen)
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls++
		n := calls
		keysSeen[r.Header.Get("x-goog-api-key")+"|url-key="+r.URL.Query().Get("key")]++
		mu.Unlock()
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Contents []struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"contents"`
		}
		json.Unmarshal(body, &req)
		prompt := req.Contents[0].Parts[0].Text
		m := itemsRe.FindStringSubmatch(prompt)
		var items []struct {
			ID int    `json:"id"`
			En string `json:"en"`
		}
		if m != nil {
			json.Unmarshal([]byte(strings.TrimSpace(m[1])), &items)
		}
		time.Sleep(time.Duration(lat+20*len(items)) * time.Millisecond)
		if d := faults["daily"]; d > 0 && n >= d {
			w.WriteHeader(429)
			fmt.Fprint(w, `{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded for metric: generate_content_free_tier_requests, limit: 20 per day","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}`)
			return
		}
		if faults["ratelimit"] == n {
			w.WriteHeader(429)
			fmt.Fprint(w, `{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"rate","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"2s"}]}}`)
			return
		}
		if faults["malformed"] == n {
			fmt.Fprint(w, `{"candidates":[{"content":{"parts":[{"text":"[{\"id\": 1, \"si\": \"trunc"}]},"finishReason":"MAX_TOKENS"}]}`)
			return
		}
		type out struct {
			ID int    `json:"id"`
			Si string `json:"si"`
		}
		var res []out
		for i, it := range items {
			if refuseWord != "" && strings.Contains(it.En, refuseWord) {
				fmt.Fprint(w, `{"promptFeedback":{"blockReason":"SAFETY"}}`)
				return
			}
			si := fmt.Sprintf("සිංහල පරිවර්තනය %d", it.ID)
			if faults["english"] == n && i == 0 {
				si = it.En // untranslated English -> must be rejected per cue
			}
			res = append(res, out{it.ID, si})
			if faults["dup"] == n && i == 1 {
				res = append(res, out{it.ID, si})
			}
		}
		js, _ := json.Marshal(res)
		resp := map[string]any{
			"candidates":    []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": string(js)}}}, "finishReason": "STOP"}},
			"usageMetadata": map[string]any{"promptTokenCount": len(prompt) / 4, "candidatesTokenCount": len(js) / 3},
		}
		json.NewEncoder(w).Encode(resp)
	})
	log.Fatal(http.ListenAndServe(addr, nil))
}
