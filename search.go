package main

import (
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "strings"
)

type imdbImage struct { ImageURL string `json:"imageUrl"` }
type imdbItem struct {
    ID string `json:"id"`
    Title string `json:"l"`
    Year int `json:"y"`
    Type string `json:"qid"`
    Stars string `json:"s"`
    Image *imdbImage `json:"i"`
}
type imdbResp struct { D []imdbItem `json:"d"` }

func searchIMDb(query string) ([]imdbItem, error) {
    query = strings.TrimSpace(query)
    if len([]rune(query)) < 2 { return []imdbItem{}, nil }
    endpoint := "https://v3.sg.media-imdb.com/suggestion/x/" + url.PathEscape(query) + ".json"
    req, err := http.NewRequest("GET", endpoint, nil); if err != nil { return nil, err }
    req.Header.Set("User-Agent", "Mozilla/5.0")
    resp, err := httpClient.Do(req); if err != nil { return nil, err }
    defer resp.Body.Close()
    if resp.StatusCode < 200 || resp.StatusCode >= 300 { return nil, fmt.Errorf("title search unavailable") }
    var ir imdbResp
    if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&ir); err != nil { return nil, err }
    out := make([]imdbItem, 0, 12)
    for _, it := range ir.D {
        t := strings.ToLower(it.Type)
        if strings.Contains(t, "movie") || strings.Contains(t, "tv") || strings.Contains(t, "series") || strings.Contains(t, "mini") || t == "feature" {
            out = append(out, it)
        }
        if len(out) >= 12 { break }
    }
    if len(out) == 0 {
        for _, it := range ir.D { out = append(out, it); if len(out) >= 10 { break } }
    }
    return out, nil
}
