package ipc

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nick/proctmux/internal/config"
)

func makeTestConfig(t *testing.T, label string) *config.ProcTmuxConfig {
	t.Helper()
	return &config.ProcTmuxConfig{FilePath: filepath.Join(os.TempDir(), fmt.Sprintf("%s.yaml", label))}
}

func socketPathForConfig(t *testing.T, cfg *config.ProcTmuxConfig) string {
	t.Helper()
	hash, err := cfg.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}
	return fmt.Sprintf("%s/proctmux-%s.socket", getTmpDir(), hash)
}

func TestWaitForSocketRequiresListener(t *testing.T) {
	origDir := socketBaseDir
	customDir, err := os.MkdirTemp("/tmp", "proctmux-test-")
	if err != nil {
		t.Fatalf("failed to create custom dir: %v", err)
	}
	socketBaseDir = customDir
	defer func() {
		socketBaseDir = origDir
		os.RemoveAll(customDir)
	}()

	cfg := makeTestConfig(t, "wait-ready")
	path := socketPathForConfig(t, cfg)

	done := make(chan error, 1)
	go func() {
		_, err := WaitForSocket(cfg)
		done <- err
	}()

	time.Sleep(200 * time.Millisecond)
	select {
	case err := <-done:
		t.Fatalf("wait returned early: %v", err)
	default:
	}

	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatalf("failed to write stale file: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	select {
	case err := <-done:
		t.Fatalf("wait returned before listener was ready: %v", err)
	default:
	}
	os.Remove(path)

	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("failed to listen on socket: %v", err)
	}
	defer func() {
		ln.Close()
		os.Remove(path)
	}()
	go func() {
		conn, err := ln.Accept()
		if err == nil {
			conn.Close()
		}
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("wait returned error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("wait timed out after listener ready")
	}
}

func TestGetSocketChecksReadiness(t *testing.T) {
	origDir := socketBaseDir
	customDir, err := os.MkdirTemp("/tmp", "proctmux-test-")
	if err != nil {
		t.Fatalf("failed to create custom dir: %v", err)
	}
	socketBaseDir = customDir
	defer func() {
		socketBaseDir = origDir
		os.RemoveAll(customDir)
	}()

	cfg := makeTestConfig(t, "get-ready")
	path := socketPathForConfig(t, cfg)

	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatalf("failed to write stale file: %v", err)
	}
	if _, err := GetSocket(cfg); err == nil {
		t.Fatalf("expected GetSocket to fail when socket not ready")
	}
	os.Remove(path)

	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("failed to listen on socket: %v", err)
	}
	defer func() {
		ln.Close()
		os.Remove(path)
	}()
	go func() {
		conn, err := ln.Accept()
		if err == nil {
			conn.Close()
		}
	}()

	if _, err := GetSocket(cfg); err != nil {
		t.Fatalf("expected GetSocket to succeed after listener ready: %v", err)
	}
}
