package main

import (
    "embed"
    "encoding/json"
    "io/fs"
    "net/http"
    "strings"
)

func jsonOut(w http.ResponseWriter, v any) {
    w.Header().Set("Content-Type", "application/json; charset=utf-8")
    w.Header().Set("Cache-Control", "no-store")
    _ = json.NewEncoder(w).Encode(v)
}

func registerAPI(mux *http.ServeMux) {
    mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
        stateMu.RLock(); connected := accessToken != ""; user := loginUser; stateMu.RUnlock()
        jsonOut(w, map[string]any{"connected": connected, "user": user})
    })
    mux.HandleFunc("/api/login", func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost { http.Error(w, "method", http.StatusMethodNotAllowed); return }
        var p struct{ Username, Password string }
        _ = json.NewDecoder(r.Body).Decode(&p)
        jsonOut(w, pikpakLogin(p.Username, p.Password))
    })
    mux.HandleFunc("/api/library", func(w http.ResponseWriter, r *http.Request) {
        files, err := listFolder("", 500)
        if err != nil { jsonOut(w, map[string]any{"ok": false, "message": err.Error()}); return }
        jsonOut(w, map[string]any{"ok": true, "files": files})
    })
    mux.HandleFunc("/api/find", func(w http.ResponseWriter, r *http.Request) {
        title := r.URL.Query().Get("title")
        files, err := allFiles(1200)
        if err != nil { jsonOut(w, map[string]any{"ok": false, "message": err.Error()}); return }
        jsonOut(w, map[string]any{"ok": true, "matches": findMatches(title, files)})
    })
    mux.HandleFunc("/api/play", func(w http.ResponseWriter, r *http.Request) {
        f, err := getFile(r.URL.Query().Get("id"))
        if err != nil { jsonOut(w, map[string]any{"ok": false, "message": err.Error()}); return }
        jsonOut(w, map[string]any{"ok": true, "url": f.WebContentLink, "name": f.Name})
    })
    mux.HandleFunc("/api/search", func(w http.ResponseWriter, r *http.Request) {
        items, err := searchIMDb(r.URL.Query().Get("q"))
        if err != nil { jsonOut(w, map[string]any{"ok": false, "message": err.Error()}); return }
        jsonOut(w, map[string]any{"ok": true, "results": items})
    })
}

func registerUI(mux *http.ServeMux, embedded embed.FS) {
    sub, _ := fs.Sub(embedded, "ui")
    fileServer := http.FileServer(http.FS(sub))
    mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        if strings.HasPrefix(r.URL.Path, "/api/") { http.NotFound(w, r); return }
        if r.URL.Path == "/" { r.URL.Path = "/index.html" }
        w.Header().Set("Cache-Control", "no-store")
        fileServer.ServeHTTP(w, r)
    })
}
