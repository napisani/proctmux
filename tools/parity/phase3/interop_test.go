package phase3

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/nick/proctmux/internal/ipc"
)

func TestGoClientListsProcessesFromZigServer(t *testing.T) {
	defer silenceStandardLog(t)()

	zigBin := os.Getenv("PROCTMUX_ZIG_BIN")
	if zigBin == "" {
		t.Fatalf("PROCTMUX_ZIG_BIN must point to the Zig proctmux binary")
	}

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "proctmux.yaml")
	if err := os.WriteFile(configPath, []byte(`
procs:
  api:
    shell: "sleep 5"
  worker:
    shell: "sleep 5"
`), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	beforeSockets := snapshotProctmuxSockets(t)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, zigBin, "-f", configPath)
	cmd.Dir = tmpDir
	cmd.Stdin = nil
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatalf("start zig server: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer stopInteropProcess(t, cancel, done, &output)

	socketPath := waitForNewResponsiveSocket(t, beforeSockets, done, &output, 5*time.Second)
	defer os.Remove(socketPath)

	client, err := ipc.NewClient(socketPath)
	if err != nil {
		t.Fatalf("connect Go client to Zig server: %v", err)
	}
	defer client.Close()

	data, err := client.GetProcessList()
	if err != nil {
		t.Fatalf("Go client list from Zig server: %v", err)
	}

	var response struct {
		ProcessList []map[string]any `json:"process_list"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		t.Fatalf("parse process list: %v", err)
	}
	if len(response.ProcessList) != 2 {
		t.Fatalf("expected 2 processes, got %#v", response.ProcessList)
	}
	if response.ProcessList[0]["name"] != "api" || response.ProcessList[0]["running"] != false {
		t.Fatalf("unexpected first process: %#v", response.ProcessList[0])
	}
	if response.ProcessList[1]["name"] != "worker" || response.ProcessList[1]["running"] != false {
		t.Fatalf("unexpected second process: %#v", response.ProcessList[1])
	}
}

func silenceStandardLog(t *testing.T) func() {
	t.Helper()

	previous := log.Writer()
	log.SetOutput(io.Discard)
	return func() {
		log.SetOutput(previous)
	}
}

func snapshotProctmuxSockets(t *testing.T) map[string]struct{} {
	t.Helper()

	paths, err := filepath.Glob("/tmp/proctmux-*.socket")
	if err != nil {
		t.Fatalf("glob proctmux sockets: %v", err)
	}
	out := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		out[path] = struct{}{}
	}
	return out
}

func waitForNewResponsiveSocket(
	t *testing.T,
	before map[string]struct{},
	serverDone <-chan error,
	output *bytes.Buffer,
	timeout time.Duration,
) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		select {
		case err := <-serverDone:
			t.Fatalf("zig server exited before socket became ready: %v\noutput:\n%s", err, output.String())
		default:
		}

		paths, err := filepath.Glob("/tmp/proctmux-*.socket")
		if err != nil {
			t.Fatalf("glob proctmux sockets: %v", err)
		}
		for _, path := range paths {
			if _, existed := before[path]; existed {
				continue
			}
			if err := probeUnixSocket(path); err == nil {
				return path
			} else {
				lastErr = err
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for responsive socket: %v", lastErr)
	return ""
}

func probeUnixSocket(path string) error {
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err != nil {
		return err
	}
	return conn.Close()
}

func stopInteropProcess(t *testing.T, cancel context.CancelFunc, done <-chan error, output *bytes.Buffer) {
	t.Helper()

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out stopping zig server\noutput:\n%s", output.String())
	}
}
