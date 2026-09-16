//go:build windows

package main

import (
    "embed"
    "fmt"
    "net"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
    "strings"
    "syscall"
    "unsafe"
)

const appName = "Pikora v0.2"

//go:embed ui/*
var uiFiles embed.FS

var (
    user32 = syscall.NewLazyDLL("user32.dll")
    procMessageBoxW = user32.NewProc("MessageBoxW")
)

func utf16(s string) *uint16 { return syscall.StringToUTF16Ptr(s) }
func messageBox(title, text string) {
    procMessageBoxW.Call(0, uintptr(unsafe.Pointer(utf16(text))), uintptr(unsafe.Pointer(utf16(title))), 0x10)
}

func findEdge() string {
    var candidates []string
    if p := os.Getenv("ProgramFiles(x86)"); p != "" { candidates = append(candidates, filepath.Join(p, "Microsoft", "Edge", "Application", "msedge.exe")) }
    if p := os.Getenv("ProgramFiles"); p != "" { candidates = append(candidates, filepath.Join(p, "Microsoft", "Edge", "Application", "msedge.exe")) }
    if p := os.Getenv("LOCALAPPDATA"); p != "" { candidates = append(candidates, filepath.Join(p, "Microsoft", "Edge", "Application", "msedge.exe")) }
    for _, p := range candidates { if _, err := os.Stat(p); err == nil { return p } }
    if p, err := exec.LookPath("msedge.exe"); err == nil { return p }
    return ""
}

func main() {
    ln, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil { messageBox(appName, "Could not start local Pikora service: "+err.Error()); return }

    mux := http.NewServeMux()
    registerAPI(mux)
    registerUI(mux, uiFiles)
    srv := &http.Server{Handler: mux}
    go srv.Serve(ln)

    addr := "http://" + ln.Addr().String() + "/"
    edge := findEdge()
    if edge == "" {
        messageBox(appName, "Microsoft Edge was not found. Pikora v0.2 currently launches its HTML UI using Edge --app mode. This dependency will be removed in the next desktop build.")
        _ = srv.Close()
        return
    }

    profile, err := os.MkdirTemp("", "pikora-edge-")
    if err != nil { profile = os.TempDir() }
    cmd := exec.Command(edge, "--app="+addr, "--user-data-dir="+profile, "--no-first-run", "--disable-features=msEdgeSidebarV2")
    cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
    if err := cmd.Run(); err != nil { messageBox(appName, "Could not open Pikora window: "+fmt.Sprint(err)) }
    _ = srv.Close()
    if strings.Contains(profile, "pikora-edge-") { _ = os.RemoveAll(profile) }
}
