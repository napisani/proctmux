package process

import (
	"testing"

	"github.com/nick/proctmux/internal/domain"
)

func TestNewController(t *testing.T) {
	ctrl := NewController()

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
	ctrl := NewController()

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
	ctrl := NewController()

	pid := ctrl.GetPID(999)
	if pid != -1 {
		t.Errorf("Expected PID -1 for non-existent process, got %d", pid)
	}
}

func TestController_GetProcessStatus_NotFound(t *testing.T) {
	ctrl := NewController()

	status := ctrl.GetProcessStatus(999)
	if status != domain.StatusHalted {
		t.Errorf("Expected StatusHalted for non-existent process, got %v", status)
	}
}

func TestController_IsRunning_NotFound(t *testing.T) {
	ctrl := NewController()

	running := ctrl.IsRunning(999)
	if running {
		t.Error("Expected IsRunning to be false for non-existent process")
	}
}

func TestController_GetAllProcessIDs_Empty(t *testing.T) {
	ctrl := NewController()

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
	ctrl := NewController()

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
	ctrl := NewController()

	_, err := ctrl.GetScrollback(999)
	if err == nil {
		t.Fatal("Expected error when getting scrollback for non-existent process")
	}
}

func TestController_GetReader_NotFound(t *testing.T) {
	ctrl := NewController()

	_, err := ctrl.GetReader(999)
	if err == nil {
		t.Fatal("Expected error when getting reader for non-existent process")
	}
}

func TestController_GetWriter_NotFound(t *testing.T) {
	ctrl := NewController()

	_, err := ctrl.GetWriter(999)
	if err == nil {
		t.Fatal("Expected error when getting writer for non-existent process")
	}
}

// Note: Full lifecycle tests (StartProcess, StopProcess with actual processes)
// are more suitable for integration tests as they require PTY/process management.
// These tests focus on the controller's behavior when processes don't exist.
