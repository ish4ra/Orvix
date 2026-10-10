//go:build !windows

package main

import (
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
)

func dialIPC(endpoint string) (io.ReadWriteCloser, error) {
	return net.Dial("unix", endpoint)
}

func ipcEndpoint(name string) string { return filepath.Join(os.TempDir(), name+".sock") }

func hideWindow(cmd *exec.Cmd) {}

const exeSuffix = ""
