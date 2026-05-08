package phase4

import (
	"bytes"
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type implementation struct {
	name string
	bin  string
}

type runtimeObservation struct {
	env  string
	tool string
	size string
}

func TestProcessRuntimeCwdEnvPathAndPtySizeMatchGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goObservation := observeRuntimeProcess(t, implementation{name: "go", bin: goBin})
	zigObservation := observeRuntimeProcess(t, implementation{name: "zig", bin: zigBin})

	if zigObservation != goObservation {
		t.Fatalf("runtime process observation mismatch:\nGo:  %#v\nZig: %#v", goObservation, zigObservation)
	}
}

func TestOnKillRunsForUserStopAndNotNaturalExitLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goResult := observeOnKillBehavior(t, implementation{name: "go", bin: goBin})
	zigResult := observeOnKillBehavior(t, implementation{name: "zig", bin: zigBin})

	if zigResult != goResult {
		t.Fatalf("on_kill result mismatch:\nGo:  %q\nZig: %q", goResult, zigResult)
	}
	if goResult != "user\n" {
		t.Fatalf("expected only user stop hook to run, got %q", goResult)
	}
}

func observeRuntimeProcess(t *testing.T, impl implementation) runtimeObservation {
	t.Helper()

	return runWithPrimaryConfig(t, impl, func(tmpDir string) string {
		workDir := filepath.Join(tmpDir, "work")
		toolsDir := filepath.Join(tmpDir, "tools-bin")
		if err := os.MkdirAll(workDir, 0o755); err != nil {
			t.Fatalf("mkdir work dir: %v", err)
		}
		if err := os.MkdirAll(toolsDir, 0o755); err != nil {
			t.Fatalf("mkdir tools dir: %v", err)
		}
		toolPath := filepath.Join(toolsDir, "phase4-tool")
		if err := os.WriteFile(toolPath, []byte("#!/bin/sh\nprintf tool-ok\n"), 0o755); err != nil {
			t.Fatalf("write tool: %v", err)
		}

		return `
procs:
  inspect:
    shell: |
      printf 'cwd=%s env=%s tool=%s size=%s\n' "$PWD" "$PHASE4_TOKEN" "$(phase4-tool)" "$(stty size)"
      sleep 5
    cwd: "work"
    env:
      PHASE4_TOKEN: "env-ok"
    add_path: ["../tools-bin"]
    terminal_rows: 31
    terminal_cols: 90
`
	}, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) runtimeObservation {
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-switch", "inspect")
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "inspect")
		line := waitForPrimaryOutputLine(t, impl.name, primaryOutput, "cwd=", 5*time.Second)
		if !strings.Contains(line, string(filepath.Separator)+"work ") {
			t.Fatalf("%s process did not run in configured cwd:\nline: %s", impl.name, line)
		}
		return runtimeObservation{
			env:  fieldValue(line, "env="),
			tool: fieldValue(line, "tool="),
			size: fieldValue(line, "size="),
		}
	})
}

func observeOnKillBehavior(t *testing.T, impl implementation) string {
	t.Helper()

	return runWithPrimaryConfig(t, impl, func(tmpDir string) string {
		return `
procs:
  user-stop:
    shell: "sleep 60"
    on_kill: ["sh", "-c", "printf 'user\n' >> hook.txt"]
  natural-exit:
    shell: "true"
    on_kill: ["sh", "-c", "printf 'natural\n' >> hook.txt"]
`
	}, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) string {
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "user-stop")
		waitForSignalListContains(t, impl, configPath, tmpDir, primaryOutput, "user-stop\trunning")
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-stop", "user-stop")
		waitForSignalListContains(t, impl, configPath, tmpDir, primaryOutput, "user-stop\tstopped")

		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "natural-exit")
		waitForSignalListContains(t, impl, configPath, tmpDir, primaryOutput, "natural-exit\tstopped")
		time.Sleep(100 * time.Millisecond)

		data, err := os.ReadFile(filepath.Join(tmpDir, "hook.txt"))
		if err != nil {
			t.Fatalf("%s read hook file: %v\nprimary output:\n%s", impl.name, err, primaryOutput.String())
		}
		return string(data)
	})
}

func runWithPrimaryConfig[T any](
	t *testing.T,
	impl implementation,
	config func(tmpDir string) string,
	body func(configPath, tmpDir string, primaryOutput *bytes.Buffer) T,
) T {
	t.Helper()

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "proctmux.yaml")
	if err := os.WriteFile(configPath, []byte(config(tmpDir)), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	beforeSockets := snapshotProctmuxSockets(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	primary := exec.CommandContext(ctx, impl.bin, "-f", configPath)
	primary.Dir = tmpDir
	var primaryOutput bytes.Buffer
	primary.Stdout = &primaryOutput
	primary.Stderr = &primaryOutput
	if err := primary.Start(); err != nil {
		t.Fatalf("start %s primary: %v", impl.name, err)
	}
	done := make(chan error, 1)
	go func() { done <- primary.Wait() }()
	defer stopParityProcess(t, cancel, done, &primaryOutput, impl.name)

	socketPath := waitForNewResponsiveSocket(t, beforeSockets, done, &primaryOutput, impl.name, 5*time.Second)
	defer os.Remove(socketPath)

	return body(configPath, tmpDir, &primaryOutput)
}

func runSignalCommand(
	t *testing.T,
	impl implementation,
	configPath string,
	tmpDir string,
	primaryOutput *bytes.Buffer,
	subcommand string,
	args ...string,
) string {
	t.Helper()

	commandArgs := append([]string{"-f", configPath, subcommand}, args...)
	signal := exec.Command(impl.bin, commandArgs...)
	signal.Dir = tmpDir
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	signal.Stdout = &stdout
	signal.Stderr = &stderr
	if err := signal.Run(); err != nil {
		t.Fatalf(
			"%s %s failed: %v\nstdout:\n%s\nstderr:\n%s\nprimary output:\n%s",
			impl.name,
			subcommand,
			err,
			stdout.String(),
			stderr.String(),
			primaryOutput.String(),
		)
	}
	if stderr.String() != "" {
		t.Fatalf("%s %s wrote stderr:\n%s", impl.name, subcommand, stderr.String())
	}
	return stdout.String()
}

func waitForSignalListContains(
	t *testing.T,
	impl implementation,
	configPath string,
	tmpDir string,
	primaryOutput *bytes.Buffer,
	needle string,
) string {
	t.Helper()

	var last string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		last = runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-list")
		if strings.Contains(last, needle) {
			return last
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("%s signal-list did not contain %q\nlast:\n%s\nprimary output:\n%s", impl.name, needle, last, primaryOutput.String())
	return ""
}

func waitForPrimaryOutputLine(t *testing.T, name string, output *bytes.Buffer, needle string, timeout time.Duration) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, line := range strings.Split(output.String(), "\n") {
			if strings.Contains(line, needle) {
				return line
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s primary output to contain %q\noutput:\n%s", name, needle, output.String())
	return ""
}

func fieldValue(line string, key string) string {
	start := strings.Index(line, key)
	if start < 0 {
		return ""
	}
	value := line[start+len(key):]
	if end := strings.IndexByte(value, ' '); end >= 0 {
		return value[:end]
	}
	return value
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
	name string,
	timeout time.Duration,
) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		select {
		case err := <-serverDone:
			t.Fatalf("%s primary exited before socket became ready: %v\noutput:\n%s", name, err, output.String())
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
	t.Fatalf("timed out waiting for %s responsive socket: %v\noutput:\n%s", name, lastErr, output.String())
	return ""
}

func probeUnixSocket(path string) error {
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err != nil {
		return err
	}
	return conn.Close()
}

func stopParityProcess(t *testing.T, cancel context.CancelFunc, done <-chan error, output *bytes.Buffer, name string) {
	t.Helper()

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out stopping %s primary\noutput:\n%s", name, output.String())
	}
}

func requiredEnv(t *testing.T, name string) string {
	t.Helper()

	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s must be set", name)
	}
	return value
}
