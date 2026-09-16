package main

import (
    "bytes"
    "crypto/md5"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "regexp"
    "strings"
    "sync"
    "time"
)

const (
    clientID = "YUMx5nI8ZU8Ap8pm"
    clientSecret = "dbw2OtmVEeuUvIptb1Coygx"
    clientVersion = "1.0.0"
    packageName = "mypikpak.com"
)

var salts = []string{
    "mg3UtlOJ5/6WjxHsGXtAthe", "kRG2RIlL/eScz3oDbzeF1", "uOIOBDcR5QALlRUUK4JVoreEI0i3RG8ZiUf2hMOH",
    "wa+0OkzHAzpyZ0S/JAnHmF2BlMR9Y", "ZWV2OkSLoNkmbr58v0f6U3udtqUNP7XON", "Jg4cDxtvbmlakZIOpQN0oY1P0eYkA4xquMY9/xqwZE5sjrcHwufR",
    "XHfs", "S4/mRgYpWyNGEUxVsYBw8n//zlywe5Ga1R8ffWJSOPZnMqWb4w",
}

var (
    httpClient = &http.Client{Timeout: 35 * time.Second}
    stateMu sync.RWMutex
    accessToken, refreshToken, userSub, deviceID, loginUser string
    pendingCaptcha, pendingCaptchaURL string
    pendingCaptchaUntil time.Time
)

func md5hex(s string) string { h := md5.Sum([]byte(s)); return hex.EncodeToString(h[:]) }
func captchaSign(dev string) (string, string) {
    ts := fmt.Sprintf("%d", time.Now().UnixMilli())
    sign := clientID + clientVersion + packageName + dev + ts
    for _, salt := range salts { sign = md5hex(sign + salt) }
    return "1." + sign, ts
}

type captchaResp struct { CaptchaToken string `json:"captcha_token"`; ExpiresIn int64 `json:"expires_in"`; URL string `json:"url"` }
type apiErrBody struct { ErrorCode any `json:"error_code"`; Error string `json:"error"`; ErrorDescription string `json:"error_description"`; Message string `json:"message"` }

func doJSON(method, endpoint string, body any, bearer string, headers map[string]string) (*http.Response, []byte, error) {
    var r io.Reader
    if body != nil { b, err := json.Marshal(body); if err != nil { return nil, nil, err }; r = bytes.NewReader(b) }
    req, err := http.NewRequest(method, endpoint, r); if err != nil { return nil, nil, err }
    req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:129.0) Gecko/20100101 Firefox/129.0")
    req.Header.Set("Content-Type", "application/json; charset=utf-8")
    if bearer != "" { req.Header.Set("Authorization", "Bearer "+bearer) }
    for k, v := range headers { if v != "" { req.Header.Set(k, v) } }
    resp, err := httpClient.Do(req); if err != nil { return nil, nil, err }
    defer resp.Body.Close()
    data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
    return resp, data, err
}

func apiError(status string, data []byte) string {
    var e apiErrBody
    if json.Unmarshal(data, &e) == nil {
        if e.ErrorDescription != "" { return e.ErrorDescription }
        if e.Message != "" { return e.Message }
        if e.Error != "" { return e.Error }
        if e.ErrorCode != nil { return fmt.Sprint(e.ErrorCode) }
    }
    s := strings.TrimSpace(string(data)); if s == "" { s = status }; if len(s) > 280 { s = s[:280] }; return s
}

func initCaptcha(action, username, dev, sub, oldToken string) (captchaResp, error) {
    sign, ts := captchaSign(dev)
    meta := map[string]string{"captcha_sign": sign, "client_version": clientVersion, "package_name": packageName, "timestamp": ts, "user_id": sub}
    if username != "" { meta["email"] = username }
    body := map[string]any{"action": action, "client_id": clientID, "device_id": dev, "captcha_token": oldToken, "meta": meta, "redirect_uri": "https://api.mypikpak.com/v1/auth/callback"}
    endpoint := "https://user.mypikpak.com/v1/shield/captcha/init?client_id=" + url.QueryEscape(clientID)
    resp, data, err := doJSON("POST", endpoint, body, "", map[string]string{"X-Device-Id": dev})
    if err != nil { return captchaResp{}, err }
    if resp.StatusCode < 200 || resp.StatusCode >= 300 { return captchaResp{}, fmt.Errorf("%s", apiError(resp.Status, data)) }
    var cr captchaResp
    if err := json.Unmarshal(data, &cr); err != nil { return cr, err }
    if cr.CaptchaToken == "" { return cr, fmt.Errorf("PikPak returned no captcha token") }
    return cr, nil
}

type loginResponse struct { AccessToken string `json:"access_token"`; RefreshToken string `json:"refresh_token"`; Sub string `json:"sub"` }
type loginResult struct { OK bool `json:"ok"`; Message string `json:"message,omitempty"`; VerifyURL string `json:"verify_url,omitempty"`; NeedVerify bool `json:"need_verify,omitempty"` }

func pikpakLogin(username, password string) loginResult {
    username = strings.TrimSpace(username)
    if username == "" || password == "" { return loginResult{Message: "Enter your PikPak email and password."} }
    dev := md5hex(strings.ToLower(username))

    stateMu.RLock(); pc := pendingCaptcha; valid := pc != "" && time.Now().Before(pendingCaptchaUntil) && loginUser == username; stateMu.RUnlock()
    if !valid {
        cr, err := initCaptcha("POST:/v1/auth/signin", username, dev, "", "")
        if err != nil { return loginResult{Message: "PikPak verification init failed: " + err.Error()} }
        ttl := cr.ExpiresIn; if ttl <= 0 { ttl = 300 }
        stateMu.Lock(); pendingCaptcha, pendingCaptchaURL, pendingCaptchaUntil, loginUser = cr.CaptchaToken, cr.URL, time.Now().Add(time.Duration(ttl)*time.Second), username; stateMu.Unlock()
        pc = cr.CaptchaToken
        if cr.URL != "" { return loginResult{NeedVerify: true, VerifyURL: cr.URL, Message: "PikPak needs a verification puzzle. Complete it, then press Sign in again."} }
    }

    body := map[string]any{"client_id": clientID, "client_secret": clientSecret, "username": username, "password": password, "captcha_token": pc}
    endpoint := "https://user.mypikpak.com/v1/auth/signin?client_id=" + url.QueryEscape(clientID)
    resp, data, err := doJSON("POST", endpoint, body, "", map[string]string{"X-Device-Id": dev, "x-captcha-token": pc})
    if err != nil { return loginResult{Message: "Login failed: " + err.Error()} }
    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        msg := apiError(resp.Status, data)
        if strings.Contains(strings.ToLower(msg), "captcha") || strings.Contains(strings.ToLower(msg), "verify") {
            if cr, ierr := initCaptcha("POST:/v1/auth/signin", username, dev, "", pc); ierr == nil {
                ttl := cr.ExpiresIn; if ttl <= 0 { ttl = 300 }
                stateMu.Lock(); pendingCaptcha, pendingCaptchaURL, pendingCaptchaUntil, loginUser = cr.CaptchaToken, cr.URL, time.Now().Add(time.Duration(ttl)*time.Second), username; stateMu.Unlock()
                if cr.URL != "" { return loginResult{NeedVerify: true, VerifyURL: cr.URL, Message: "Complete PikPak verification, then press Sign in again."} }
            }
        }
        return loginResult{Message: "Login failed: " + msg}
    }

    var lr loginResponse
    if err := json.Unmarshal(data, &lr); err != nil || lr.AccessToken == "" { return loginResult{Message: "Login failed: PikPak returned no access token."} }
    stateMu.Lock(); accessToken, refreshToken, userSub, deviceID, loginUser = lr.AccessToken, lr.RefreshToken, lr.Sub, dev, username; pendingCaptcha, pendingCaptchaURL = "", ""; pendingCaptchaUntil = time.Time{}; stateMu.Unlock()
    return loginResult{OK: true, Message: "Connected to PikPak."}
}

func driveCaptcha(action string) (string, error) {
    stateMu.RLock(); tok, dev, sub, user := accessToken, deviceID, userSub, loginUser; stateMu.RUnlock()
    if tok == "" { return "", fmt.Errorf("not connected") }
    cr, err := initCaptcha(action, user, dev, sub, ""); if err != nil { return "", err }
    if cr.URL != "" { return "", fmt.Errorf("PikPak requires additional verification") }
    return cr.CaptchaToken, nil
}

type driveFile struct { ID string `json:"id"`; Name string `json:"name"`; Kind string `json:"kind"`; Size string `json:"size"`; MimeType string `json:"mime_type"`; WebContentLink string `json:"web_content_link"`; ThumbnailLink string `json:"thumbnail_link"` }
type fileListResp struct { Files []driveFile `json:"files"`; NextPageToken string `json:"next_page_token"` }

func listFolder(parent string, limit int) ([]driveFile, error) {
    stateMu.RLock(); tok, dev := accessToken, deviceID; stateMu.RUnlock(); if tok == "" { return nil, fmt.Errorf("Connect PikPak first") }
    capTok, err := driveCaptcha("GET:/drive/v1/files"); if err != nil { return nil, err }
    q := url.Values{}; q.Set("thumbnail_size", "SIZE_MEDIUM"); q.Set("limit", fmt.Sprint(limit)); q.Set("with_audit", "true"); q.Set("parent_id", parent); q.Set("filters", `{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}`)
    resp, data, err := doJSON("GET", "https://api-drive.mypikpak.com/drive/v1/files?"+q.Encode(), nil, tok, map[string]string{"x-captcha-token": capTok, "x-device-id": dev})
    if err != nil { return nil, err }; if resp.StatusCode < 200 || resp.StatusCode >= 300 { return nil, fmt.Errorf("%s", apiError(resp.Status, data)) }
    var fr fileListResp; if err := json.Unmarshal(data, &fr); err != nil { return nil, err }; return fr.Files, nil
}

func allFiles(maxItems int) ([]driveFile, error) {
    type node struct { id string; depth int }
    q := []node{{"", 0}}; out := make([]driveFile, 0, 256)
    for len(q) > 0 && len(out) < maxItems {
        n := q[0]; q = q[1:]
        files, err := listFolder(n.id, 500); if err != nil { return out, err }
        for _, f := range files {
            out = append(out, f); if len(out) >= maxItems { break }
            if strings.Contains(strings.ToLower(f.Kind), "folder") && n.depth < 5 { q = append(q, node{f.ID, n.depth + 1}) }
        }
    }
    return out, nil
}

var nonAlnum = regexp.MustCompile(`[^a-z0-9]+`)
func norm(s string) string { return strings.TrimSpace(nonAlnum.ReplaceAllString(strings.ToLower(s), " ")) }
func findMatches(title string, files []driveFile) []driveFile {
    n := norm(title); if n == "" { return nil }; words := strings.Fields(n); var out []driveFile
    for _, f := range files {
        if strings.Contains(strings.ToLower(f.Kind), "folder") { continue }
        fn := norm(f.Name); score := 0; if strings.Contains(fn, n) { score += 4 }
        for _, w := range words { if len(w) > 2 && strings.Contains(fn, w) { score++ } }
        if score >= 2 { out = append(out, f) }; if len(out) >= 20 { break }
    }
    return out
}

func getFile(id string) (driveFile, error) {
    stateMu.RLock(); tok, dev := accessToken, deviceID; stateMu.RUnlock(); if tok == "" { return driveFile{}, fmt.Errorf("Connect PikPak first") }
    capTok, err := driveCaptcha("GET:/drive/v1/files/"); if err != nil { return driveFile{}, err }
    endpoint := "https://api-drive.mypikpak.com/drive/v1/files/" + url.PathEscape(id) + "?usage=FETCH"
    resp, data, err := doJSON("GET", endpoint, nil, tok, map[string]string{"x-captcha-token": capTok, "x-device-id": dev})
    if err != nil { return driveFile{}, err }; if resp.StatusCode < 200 || resp.StatusCode >= 300 { return driveFile{}, fmt.Errorf("%s", apiError(resp.Status, data)) }
    var f driveFile; if err := json.Unmarshal(data, &f); err != nil { return f, err }; return f, nil
}
