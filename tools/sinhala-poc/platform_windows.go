//go:build windows

package main

import (
	"io"
	"os"
	"os/exec"
	"syscall"
)

func dialIPC(endpoint string) (io.ReadWriteCloser, error) {
	// Synchronous client handle to mpv's named pipe (\\.\pipe\name). Safe
	// because Mpv never reads and writes concurrently.
	return os.OpenFile(endpoint, os.O_RDWR, 0)
}

func ipcEndpoint(name string) string { return `\\.\pipe\` + name }

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

const exeSuffix = ".exe"
