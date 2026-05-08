package phase5

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

func TestSignalListMatchesGoReferenceForStoppedProcesses(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goOutput := runSignalListAgainstPrimary(t, implementation{name: "go", bin: goBin})
	zigOutput := runSignalListAgainstPrimary(t, implementation{name: "zig", bin: zigBin})

	if zigOutput != goOutput {
		t.Fatalf("signal-list mismatch:\nGo:\n%s\nZig:\n%s", goOutput, zigOutput)
	}

	const want = "NAME\tSTATUS\napi\tstopped\nworker\tstopped\n"
	if zigOutput != want {
		t.Fatalf("unexpected signal-list output:\nwant:\n%s\ngot:\n%s", want, zigOutput)
	}
}

func TestSignalStartStopLifecycleMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goResult := runSignalLifecycleAgainstPrimary(t, implementation{name: "go", bin: goBin})
	zigResult := runSignalLifecycleAgainstPrimary(t, implementation{name: "zig", bin: zigBin})

	if zigResult != goResult {
		t.Fatalf("signal lifecycle mismatch:\nGo:  %#v\nZig: %#v", goResult, zigResult)
	}

	if goResult.initial != "NAME\tSTATUS\napi\tstopped\nworker\tstopped\n" {
		t.Fatalf("unexpected initial status:\n%s", goResult.initial)
	}
	if goResult.afterStart != "NAME\tSTATUS\napi\trunning\nworker\tstopped\n" {
		t.Fatalf("unexpected status after signal-start:\n%s", goResult.afterStart)
	}
	if goResult.afterStop != "NAME\tSTATUS\napi\tstopped\nworker\tstopped\n" {
		t.Fatalf("unexpected status after signal-stop:\n%s", goResult.afterStop)
	}
	if goResult.startStdout != "" || goResult.stopStdout != "" {
		t.Fatalf("mutation signal commands should not write stdout: %#v", goResult)
	}
}

func TestSignalRestartSwitchAndRunningCommandsMatchGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goResult := runExtendedSignalLifecycleAgainstPrimary(t, implementation{name: "go", bin: goBin})
	zigResult := runExtendedSignalLifecycleAgainstPrimary(t, implementation{name: "zig", bin: zigBin})

	if zigResult != goResult {
		t.Fatalf("extended signal lifecycle mismatch:\nGo:  %#v\nZig: %#v", goResult, zigResult)
	}

	if goResult.afterStartAPI != "NAME\tSTATUS\napi\trunning\nworker\tstopped\n" {
		t.Fatalf("unexpected status after starting api:\n%s", goResult.afterStartAPI)
	}
	if goResult.afterRestartAPI != "NAME\tSTATUS\napi\trunning\nworker\tstopped\n" {
		t.Fatalf("unexpected status after restarting api:\n%s", goResult.afterRestartAPI)
	}
	if goResult.afterStartWorker != "NAME\tSTATUS\napi\trunning\nworker\trunning\n" {
		t.Fatalf("unexpected status after starting worker:\n%s", goResult.afterStartWorker)
	}
	if goResult.afterRestartRunning != "NAME\tSTATUS\napi\trunning\nworker\trunning\n" {
		t.Fatalf("unexpected status after restart-running:\n%s", goResult.afterRestartRunning)
	}
	if goResult.afterStopRunning != "NAME\tSTATUS\napi\tstopped\nworker\tstopped\n" {
		t.Fatalf("unexpected status after stop-running:\n%s", goResult.afterStopRunning)
	}
	if goResult.restartStdout != "" ||
		goResult.switchStdout != "" ||
		goResult.startWorkerStdout != "" ||
		goResult.restartRunningStdout != "" ||
		goResult.stopRunningStdout != "" {
		t.Fatalf("mutation signal commands should not write stdout: %#v", goResult)
	}
}

func TestSignalCommandFailureOutputMatchesGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goResult := runSignalFailureAgainstPrimary(t, implementation{name: "go", bin: goBin})
	zigResult := runSignalFailureAgainstPrimary(t, implementation{name: "zig", bin: zigBin})

	if zigResult != goResult {
		t.Fatalf("signal failure result mismatch:\nGo:  %#v\nZig: %#v", goResult, zigResult)
	}
	if goResult.exitCode == 0 {
		t.Fatalf("expected signal-start for missing process to fail")
	}
	if goResult.stdout != "" {
		t.Fatalf("failing signal command should not write stdout: %#v", goResult)
	}
}

func TestPrimaryViewerShowsStartedSelectedProcessOutputLikeGoReference(t *testing.T) {
	goBin := requiredEnv(t, "PROCTMUX_GO_BIN")
	zigBin := requiredEnv(t, "PROCTMUX_ZIG_BIN")

	goOutput := runPrimaryViewerOutput(t, implementation{name: "go", bin: goBin})
	zigOutput := runPrimaryViewerOutput(t, implementation{name: "zig", bin: zigBin})

	const marker = "primary-output-marker"
	if !strings.Contains(goOutput, marker) {
		t.Fatalf("Go reference primary output did not contain marker %q:\n%s", marker, goOutput)
	}
	if !strings.Contains(zigOutput, marker) {
		t.Fatalf("Zig primary output did not contain marker %q like Go reference\nGo:\n%s\nZig:\n%s", marker, goOutput, zigOutput)
	}
}

type lifecycleResult struct {
	initial     string
	startStdout string
	afterStart  string
	stopStdout  string
	afterStop   string
}

type extendedLifecycleResult struct {
	afterStartAPI        string
	restartStdout        string
	afterRestartAPI      string
	switchStdout         string
	startWorkerStdout    string
	afterStartWorker     string
	restartRunningStdout string
	afterRestartRunning  string
	stopRunningStdout    string
	afterStopRunning     string
}

type signalCommandResult struct {
	exitCode int
	stdout   string
	stderr   string
}

func requiredEnv(t *testing.T, name string) string {
	t.Helper()

	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s must be set", name)
	}
	return value
}

func runSignalListAgainstPrimary(t *testing.T, impl implementation) string {
	t.Helper()

	result := runWithPrimary(t, impl, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) string {
		return runSignalListCommand(t, impl, configPath, tmpDir, primaryOutput)
	})
	return result
}

func runSignalLifecycleAgainstPrimary(t *testing.T, impl implementation) lifecycleResult {
	t.Helper()

	return runWithPrimary(t, impl, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) lifecycleResult {
		initial := runSignalListCommand(t, impl, configPath, tmpDir, primaryOutput)
		startStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "api")
		afterStart := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\trunning\nworker\tstopped\n",
		)
		stopStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-stop", "api")
		afterStop := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\tstopped\nworker\tstopped\n",
		)

		return lifecycleResult{
			initial:     initial,
			startStdout: startStdout,
			afterStart:  afterStart,
			stopStdout:  stopStdout,
			afterStop:   afterStop,
		}
	})
}

func runExtendedSignalLifecycleAgainstPrimary(t *testing.T, impl implementation) extendedLifecycleResult {
	t.Helper()

	return runWithPrimary(t, impl, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) extendedLifecycleResult {
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "api")
		afterStartAPI := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\trunning\nworker\tstopped\n",
		)
		restartStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-restart", "api")
		afterRestartAPI := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\trunning\nworker\tstopped\n",
		)
		switchStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-switch", "worker")
		startWorkerStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "worker")
		afterStartWorker := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\trunning\nworker\trunning\n",
		)
		restartRunningStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-restart-running")
		afterRestartRunning := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\trunning\nworker\trunning\n",
		)
		stopRunningStdout := runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-stop-running")
		afterStopRunning := waitForSignalList(
			t,
			impl,
			configPath,
			tmpDir,
			primaryOutput,
			"NAME\tSTATUS\napi\tstopped\nworker\tstopped\n",
		)

		return extendedLifecycleResult{
			afterStartAPI:        afterStartAPI,
			restartStdout:        restartStdout,
			afterRestartAPI:      afterRestartAPI,
			switchStdout:         switchStdout,
			startWorkerStdout:    startWorkerStdout,
			afterStartWorker:     afterStartWorker,
			restartRunningStdout: restartRunningStdout,
			afterRestartRunning:  afterRestartRunning,
			stopRunningStdout:    stopRunningStdout,
			afterStopRunning:     afterStopRunning,
		}
	})
}

func runSignalFailureAgainstPrimary(t *testing.T, impl implementation) signalCommandResult {
	t.Helper()

	return runWithPrimary(t, impl, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) signalCommandResult {
		return runSignalCommandResult(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "missing")
	})
}

func runPrimaryViewerOutput(t *testing.T, impl implementation) string {
	t.Helper()

	return runWithPrimaryConfig(t, impl, `
procs:
  api:
    shell: "printf 'primary-output-marker\n'; sleep 5"
`, func(configPath, tmpDir string, primaryOutput *bytes.Buffer) string {
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-switch", "api")
		runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-start", "api")
		waitForPrimaryOutput(t, impl.name, primaryOutput, "primary-output-marker", 3*time.Second)
		return primaryOutput.String()
	})
}

func runWithPrimary[T any](
	t *testing.T,
	impl implementation,
	body func(configPath, tmpDir string, primaryOutput *bytes.Buffer) T,
) T {
	t.Helper()

	return runWithPrimaryConfig(t, impl, `
procs:
  api:
    shell: "sleep 5"
  worker:
    shell: "sleep 5"
`, body)
}

func runWithPrimaryConfig[T any](
	t *testing.T,
	impl implementation,
	config string,
	body func(configPath, tmpDir string, primaryOutput *bytes.Buffer) T,
) T {
	t.Helper()

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "proctmux.yaml")
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
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

func waitForPrimaryOutput(t *testing.T, name string, output *bytes.Buffer, needle string, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(output.String(), needle) {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s primary output to contain %q\noutput:\n%s", name, needle, output.String())
}

func runSignalListCommand(
	t *testing.T,
	impl implementation,
	configPath string,
	tmpDir string,
	primaryOutput *bytes.Buffer,
) string {
	t.Helper()
	return runSignalCommand(t, impl, configPath, tmpDir, primaryOutput, "signal-list")
}

func waitForSignalList(
	t *testing.T,
	impl implementation,
	configPath string,
	tmpDir string,
	primaryOutput *bytes.Buffer,
	want string,
) string {
	t.Helper()

	var last string
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		last = runSignalListCommand(t, impl, configPath, tmpDir, primaryOutput)
		if last == want {
			return last
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("%s signal-list did not reach expected state:\nwant:\n%s\nlast:\n%s", impl.name, want, last)
	return ""
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

	result := runSignalCommandResult(t, impl, configPath, tmpDir, primaryOutput, subcommand, args...)
	if result.exitCode != 0 {
		t.Fatalf(
			"%s %s failed with exit code %d\nstdout:\n%s\nstderr:\n%s\nprimary output:\n%s",
			impl.name,
			subcommand,
			result.exitCode,
			result.stdout,
			result.stderr,
			primaryOutput.String(),
		)
	}

	if result.stderr != "" {
		t.Fatalf("%s %s wrote stderr:\n%s", impl.name, subcommand, result.stderr)
	}
	return result.stdout
}

func runSignalCommandResult(
	t *testing.T,
	impl implementation,
	configPath string,
	tmpDir string,
	primaryOutput *bytes.Buffer,
	subcommand string,
	args ...string,
) signalCommandResult {
	t.Helper()

	commandArgs := append([]string{"-f", configPath, subcommand}, args...)
	signal := exec.Command(impl.bin, commandArgs...)
	signal.Dir = tmpDir
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	signal.Stdout = &stdout
	signal.Stderr = &stderr
	exitCode := 0
	if err := signal.Run(); err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf(
				"%s %s failed to run: %v\nstdout:\n%s\nstderr:\n%s\nprimary output:\n%s",
				impl.name,
				subcommand,
				err,
				stdout.String(),
				stderr.String(),
				primaryOutput.String(),
			)
		}
		exitCode = exitErr.ExitCode()
	}
	return signalCommandResult{
		exitCode: exitCode,
		stdout:   stdout.String(),
		stderr:   stderr.String(),
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
	t.Fatalf("timed out waiting for %s responsive socket: %v", name, lastErr)
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
