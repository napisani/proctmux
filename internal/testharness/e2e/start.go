package e2e

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/procdiscover"

	_ "github.com/nick/proctmux/internal/procdiscover/makefile"
	_ "github.com/nick/proctmux/internal/procdiscover/packagejson"
)

// StartUnifiedSession builds the proctmux binary (if needed) and launches it in unified mode.
func StartUnifiedSession(t testing.TB, cfgDir, cfgPath string, extraEnv ...string) *Session {
	t.Helper()

	return StartUnifiedSessionWithBinary(t, Binary(t), cfgDir, cfgPath, extraEnv...)
}

// StartUnifiedSessionWithBinary launches the provided proctmux binary in unified mode.
func StartUnifiedSessionWithBinary(t testing.TB, binary, cfgDir, cfgPath string, extraEnv ...string) *Session {
	t.Helper()

	return StartUnifiedSessionWithBinaryArgs(t, binary, cfgDir, cfgPath, []string{"--unified"}, extraEnv...)
}

// StartUnifiedSessionWithBinaryArgs launches the provided proctmux binary in unified mode with explicit unified flags.
func StartUnifiedSessionWithBinaryArgs(
	t testing.TB,
	binary string,
	cfgDir string,
	cfgPath string,
	unifiedArgs []string,
	extraEnv ...string,
) *Session {
	t.Helper()

	return StartUnifiedSessionWithBinaryArgsAndSize(t, binary, cfgDir, cfgPath, unifiedArgs, TerminalSize{}, extraEnv...)
}

// StartUnifiedSessionWithBinaryArgsAndSize launches the provided proctmux binary in unified mode with explicit unified flags and terminal size.
func StartUnifiedSessionWithBinaryArgsAndSize(
	t testing.TB,
	binary string,
	cfgDir string,
	cfgPath string,
	unifiedArgs []string,
	size TerminalSize,
	extraEnv ...string,
) *Session {
	t.Helper()

	args := append([]string{}, unifiedArgs...)
	args = append(args, "-f", cfgPath)
	env := append([]string{"PROCTMUX_NO_ALTSCREEN=1", "TERM=xterm-256color"}, extraEnv...)

	sess, err := startSessionWithSize(binary, args, cfgDir, env, size)
	if err != nil {
		t.Fatalf("start unified session: %v", err)
	}

	t.Cleanup(func() {
		if err := sess.Stop(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: stopping unified session: %v\n", err)
		}
	})

	return sess
}

// StartClientSession starts a client-only proctmux instance using the provided configuration file.
func StartClientSession(t testing.TB, cfgDir, cfgPath string, extraEnv ...string) *Session {
	t.Helper()

	return StartClientSessionWithBinary(t, Binary(t), cfgDir, cfgPath, extraEnv...)
}

// StartClientSessionWithBinary starts a client-only instance using the provided binary.
func StartClientSessionWithBinary(t testing.TB, binary, cfgDir, cfgPath string, extraEnv ...string) *Session {
	t.Helper()

	args := []string{"--client", "-f", cfgPath}
	env := append([]string{"PROCTMUX_NO_ALTSCREEN=1", "TERM=xterm-256color"}, extraEnv...)

	sess, err := startSession(binary, args, cfgDir, env)
	if err != nil {
		t.Fatalf("start client session: %v", err)
	}

	t.Cleanup(func() {
		if err := sess.Stop(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: stopping client session: %v\n", err)
		}
	})

	return sess
}

// PrimaryProcess represents a running proctmux primary server.
type PrimaryProcess struct {
	Cmd     *exec.Cmd
	cancel  context.CancelFunc
	stdout  *bytes.Buffer
	stderr  *bytes.Buffer
	stopMux sync.Mutex
	stopped bool
	waitCh  chan error
}

// StartPrimaryProcess launches the proctmux primary server using the provided configuration.
func StartPrimaryProcess(t testing.TB, cfgDir, cfgPath string, extraEnv ...string) *PrimaryProcess {
	t.Helper()

	return StartPrimaryProcessWithBinary(t, Binary(t), cfgDir, cfgPath, extraEnv...)
}

// StartPrimaryProcessWithBinary launches the provided proctmux binary as a primary server.
func StartPrimaryProcessWithBinary(t testing.TB, binary, cfgDir, cfgPath string, extraEnv ...string) *PrimaryProcess {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())

	cmd := exec.CommandContext(ctx, binary, "-f", cfgPath)
	cmd.Dir = cfgDir
	env := append([]string{"PROCTMUX_TEST_MODE=1", "TERM=xterm-256color"}, extraEnv...)
	cmd.Env = mergeEnv(env)

	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start primary: %v", err)
	}

	waitCh := make(chan error, 1)
	primary := &PrimaryProcess{
		Cmd:    cmd,
		cancel: cancel,
		stdout: stdout,
		stderr: stderr,
		waitCh: waitCh,
	}

	go func() {
		waitCh <- cmd.Wait()
	}()

	t.Cleanup(func() {
		if err := primary.Stop(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: stopping primary: %v\n", err)
		}
	})

	return primary
}

// Stop terminates the primary process.
func (p *PrimaryProcess) Stop() error {
	if p == nil {
		return nil
	}

	p.stopMux.Lock()
	if p.stopped {
		p.stopMux.Unlock()
		return nil
	}
	p.stopped = true
	p.stopMux.Unlock()

	defer p.cancel()

	if p.Cmd.Process != nil {
		_ = p.Cmd.Process.Signal(syscall.SIGINT)
	}

	var err error
	select {
	case err = <-p.waitCh:
	case <-time.After(5 * time.Second):
		if p.Cmd.Process != nil {
			_ = p.Cmd.Process.Kill()
		}
		if p.waitCh != nil {
			err = <-p.waitCh
		}
	}

	if exitErr, ok := err.(*exec.ExitError); ok {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			if status.Signaled() && status.Signal() == syscall.SIGINT {
				err = nil
			}
		}
	}

	return err
}

// Logs returns combined primary stdout/stderr output.
func (p *PrimaryProcess) Logs() string {
	if p == nil {
		return ""
	}
	return p.stdout.String() + p.stderr.String()
}

func waitForSocket(cfgPath string) (string, error) {
	cfg, err := config.LoadConfig(cfgPath)
	if err != nil {
		return "", err
	}
	procdiscover.Apply(cfg, filepath.Dir(cfg.FilePath))
	return ipc.WaitForSocket(cfg)
}

// StartPrimaryAndClient starts a primary server and a client session connected to it.
func StartPrimaryAndClient(t testing.TB, cfgDir, cfgPath string, extraEnv ...string) (*PrimaryProcess, *Session) {
	t.Helper()

	binary := Binary(t)
	return StartPrimaryAndClientWithBinary(t, binary, binary, cfgDir, cfgPath, extraEnv...)
}

// StartPrimaryAndClientWithBinary starts a primary and client using provided binaries.
func StartPrimaryAndClientWithBinary(
	t testing.TB,
	primaryBinary string,
	clientBinary string,
	cfgDir string,
	cfgPath string,
	extraEnv ...string,
) (*PrimaryProcess, *Session) {
	t.Helper()

	primary := StartPrimaryProcessWithBinary(t, primaryBinary, cfgDir, cfgPath, extraEnv...)

	// Wait for the IPC socket before launching the client.
	if _, err := waitForSocket(cfgPath); err != nil {
		t.Fatalf("wait for socket: %v\nprimary logs:\n%s\nconfigured log:\n%s", err, primary.Logs(), configuredLogContents(cfgPath))
	}

	sess := StartClientSessionWithBinary(t, clientBinary, cfgDir, cfgPath, extraEnv...)

	return primary, sess
}

func configuredLogContents(cfgPath string) string {
	cfg, err := config.LoadConfig(cfgPath)
	if err != nil {
		return "<unable to reload config: " + err.Error() + ">"
	}
	if cfg.LogFile == "" {
		return "<no log_file configured>"
	}

	logPath := cfg.LogFile
	if !filepath.IsAbs(logPath) {
		logPath = filepath.Join(filepath.Dir(cfg.FilePath), logPath)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		return "<unable to read " + logPath + ": " + err.Error() + ">"
	}
	return string(data)
}
