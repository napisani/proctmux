package process

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

func TestNewController(t *testing.T) {
	ctrl := NewController(nil)

	if ctrl == nil {
		t.Fatal("Expected controller to be created")
	}

	if ctrl.processes == nil {
		t.Error("Expected processes map to be initialized")
	}

	if len(ctrl.processes) != 0 {
		t.Errorf("Expected empty processes map, got %d processes", len(ctrl.processes))
	}
}

func TestController_GetProcess_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	_, err := ctrl.GetProcess(999)
	if err == nil {
		t.Fatal("Expected error when process not found")
	}

	expectedError := "process 999 not found"
	if err.Error() != expectedError {
		t.Errorf("Expected error %q, got %q", expectedError, err.Error())
	}
}

func TestController_GetPID_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	pid := ctrl.GetPID(999)
	if pid != -1 {
		t.Errorf("Expected PID -1 for non-existent process, got %d", pid)
	}
}

func TestController_GetProcessStatus_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	status := ctrl.GetProcessStatus(999)
	if status != domain.StatusHalted {
		t.Errorf("Expected StatusHalted for non-existent process, got %v", status)
	}
}

func TestController_IsRunning_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	running := ctrl.IsRunning(999)
	if running {
		t.Error("Expected IsRunning to be false for non-existent process")
	}
}

func TestController_GetAllProcessIDs_Empty(t *testing.T) {
	ctrl := NewController(nil)

	ids := ctrl.GetAllProcessIDs()
	if len(ids) != 0 {
		t.Errorf("Expected empty ID list, got %v", ids)
	}

	// Should return non-nil slice
	if ids == nil {
		t.Error("Expected non-nil slice")
	}
}

func TestController_StopProcess_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	err := ctrl.StopProcess(999)
	if err == nil {
		t.Fatal("Expected error when stopping non-existent process")
	}

	expectedError := "process 999 not found"
	if err.Error() != expectedError {
		t.Errorf("Expected error %q, got %q", expectedError, err.Error())
	}
}

func TestController_GetScrollback_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	_, err := ctrl.GetScrollback(999)
	if err == nil {
		t.Fatal("Expected error when getting scrollback for non-existent process")
	}
}

func TestController_GetReader_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	_, err := ctrl.GetReader(999)
	if err == nil {
		t.Fatal("Expected error when getting reader for non-existent process")
	}
}

func TestController_GetWriter_NotFound(t *testing.T) {
	ctrl := NewController(nil)

	_, err := ctrl.GetWriter(999)
	if err == nil {
		t.Fatal("Expected error when getting writer for non-existent process")
	}
}

func TestStartProcessFailsWhenRawModeConfigurationFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires POSIX shell")
	}

	originalConfigure := configurePTYRawMode
	configurePTYRawMode = func(f *os.File) error {
		return fmt.Errorf("boom")
	}
	t.Cleanup(func() {
		configurePTYRawMode = originalConfigure
	})

	ctrl := NewController(nil)
	cfg := &config.ProcessConfig{
		Cmd: []string{"sh", "-c", "sleep 1"},
	}

	if _, err := ctrl.StartProcess(1, cfg); err == nil {
		t.Fatalf("expected StartProcess to fail when raw mode configuration fails")
	} else if !strings.Contains(err.Error(), "configure PTY") {
		t.Fatalf("unexpected error: %v", err)
	}

	if _, err := ctrl.GetProcess(1); err == nil {
		t.Fatalf("process should not remain registered after startup failure")
	}
}

// Note: Full lifecycle tests (StartProcess, StopProcess with actual processes)
// are more suitable for integration tests as they require PTY/process management.
// These tests focus on the controller's behavior when processes don't exist.

func TestStopProcessRunsOnKill(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires POSIX shell")
	}

	tmpDir := t.TempDir()
	hookFile := filepath.Join(tmpDir, "on_kill.txt")

	ctrl := NewController(nil)

	cfg := &config.ProcessConfig{
		Cmd: []string{"sh", "-c", "trap 'exit 0' TERM; while true; do sleep 0.05; done"},
		Cwd: tmpDir,
		OnKill: []string{
			"sh", "-c", fmt.Sprintf("echo hook >> %s", hookFile),
		},
	}

	if _, err := ctrl.StartProcess(1, cfg); err != nil {
		t.Fatalf("StartProcess error: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	if err := ctrl.StopProcess(1); err != nil {
		t.Fatalf("StopProcess error: %v", err)
	}

	data, err := os.ReadFile(hookFile)
	if err != nil {
		t.Fatalf("expected on-kill file to exist: %v", err)
	}

	if strings.TrimSpace(string(data)) != "hook" {
		t.Fatalf("unexpected on-kill file contents: %q", string(data))
	}
}

func TestCleanupProcessDoesNotRunOnKill(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires POSIX shell")
	}

	tmpDir := t.TempDir()
	hookFile := filepath.Join(tmpDir, "on_kill.txt")

	ctrl := NewController(nil)

	cfg := &config.ProcessConfig{
		Cmd:    []string{"sh", "-c", "echo done"},
		Cwd:    tmpDir,
		OnKill: []string{"sh", "-c", fmt.Sprintf("echo hook >> %s", hookFile)},
	}

	instance, err := ctrl.StartProcess(1, cfg)
	if err != nil {
		t.Fatalf("StartProcess error: %v", err)
	}

	select {
	case <-instance.WaitForExit():
	case <-time.After(2 * time.Second):
		t.Fatal("process did not exit in time")
	}

	if err := ctrl.CleanupProcess(1); err != nil {
		t.Fatalf("CleanupProcess error: %v", err)
	}

	if _, err := os.Stat(hookFile); err == nil {
		t.Fatalf("on-kill file should not exist for natural exit")
	} else if !os.IsNotExist(err) {
		t.Fatalf("unexpected error checking on-kill file: %v", err)
	}
}

func TestStopProcessOnKillFailurePropagates(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires POSIX shell")
	}

	ctrl := NewController(nil)

	cfg := &config.ProcessConfig{
		Cmd:    []string{"sh", "-c", "trap 'exit 0' TERM; while true; do sleep 0.05; done"},
		OnKill: []string{"sh", "-c", "exit 3"},
	}

	if _, err := ctrl.StartProcess(1, cfg); err != nil {
		t.Fatalf("StartProcess error: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	err := ctrl.StopProcess(1)
	if err == nil {
		t.Fatal("expected StopProcess to report on-kill failure")
	}

	if !strings.Contains(err.Error(), "exit status 3") {
		t.Fatalf("unexpected error: %v", err)
	}

	if _, err := ctrl.GetProcess(1); err == nil {
		t.Fatalf("process should have been removed after stop")
	}
}
