package domain

import (
	"testing"

	"github.com/nick/proctmux/internal/config"
)

func TestProcessStatus_String(t *testing.T) {
	tests := []struct {
		status   ProcessStatus
		expected string
	}{
		{StatusRunning, "Running"},
		{StatusHalting, "Halting"},
		{StatusHalted, "Halted"},
		{StatusExited, "Exited"},
		{StatusUnknown, "Unknown"},
		{ProcessStatus(999), "Unknown"}, // Invalid status
	}

	for _, tt := range tests {
		t.Run(tt.expected, func(t *testing.T) {
			result := tt.status.String()
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestNewFromProcessConfig(t *testing.T) {
	cfg := &config.ProcessConfig{
		Shell:       "echo hello",
		Description: "Test process",
	}

	proc := NewFromProcessConfig(42, "test-label", cfg)

	if proc.ID != 42 {
		t.Errorf("Expected ID 42, got %d", proc.ID)
	}
	if proc.Label != "test-label" {
		t.Errorf("Expected label 'test-label', got %q", proc.Label)
	}
	if proc.Config != cfg {
		t.Error("Expected config to be linked")
	}
}

func TestProcess_Command_Shell(t *testing.T) {
	proc := Process{
		ID:    1,
		Label: "test",
		Config: &config.ProcessConfig{
			Shell: "tail -f /var/log/syslog",
		},
	}

	cmd := proc.Command()
	expected := "tail -f /var/log/syslog"
	if cmd != expected {
		t.Errorf("Expected %q, got %q", expected, cmd)
	}
}

func TestProcess_Command_CmdArray(t *testing.T) {
	proc := Process{
		ID:    1,
		Label: "test",
		Config: &config.ProcessConfig{
			Cmd: []string{"/bin/bash", "-c", "echo DONE"},
		},
	}

	cmd := proc.Command()
	expected := "'/bin/bash' '-c' 'echo DONE' "
	if cmd != expected {
		t.Errorf("Expected %q, got %q", expected, cmd)
	}
}

func TestProcess_Command_ShellPriority(t *testing.T) {
	// Shell takes priority over Cmd
	proc := Process{
		ID:    1,
		Label: "test",
		Config: &config.ProcessConfig{
			Shell: "shell command",
			Cmd:   []string{"cmd", "array"},
		},
	}

	cmd := proc.Command()
	if cmd != "shell command" {
		t.Errorf("Expected shell to take priority, got %q", cmd)
	}
}

func TestProcess_Command_Empty(t *testing.T) {
	proc := Process{
		ID:     1,
		Label:  "test",
		Config: &config.ProcessConfig{},
	}

	cmd := proc.Command()
	if cmd != "" {
		t.Errorf("Expected empty string, got %q", cmd)
	}
}

func TestProcessView_Command(t *testing.T) {
	// ProcessView.Command() should behave the same as Process.Command()
	pv := ProcessView{
		ID:     1,
		Label:  "test",
		Status: StatusRunning,
		PID:    123,
		Config: &config.ProcessConfig{
			Shell: "echo test",
		},
	}

	cmd := pv.Command()
	expected := "echo test"
	if cmd != expected {
		t.Errorf("Expected %q, got %q", expected, cmd)
	}
}

// Mock ProcessController for testing
type mockProcessController struct {
	status ProcessStatus
	pid    int
}

func (m *mockProcessController) GetProcessStatus(id int) ProcessStatus {
	return m.status
}

func (m *mockProcessController) GetPID(id int) int {
	return m.pid
}

func TestProcess_ToView_WithController(t *testing.T) {
	proc := Process{
		ID:    5,
		Label: "backend",
		Config: &config.ProcessConfig{
			Shell: "npm run dev",
		},
	}

	controller := &mockProcessController{
		status: StatusRunning,
		pid:    12345,
	}

	view := proc.ToView(controller)

	if view.ID != 5 {
		t.Errorf("Expected ID 5, got %d", view.ID)
	}
	if view.Label != "backend" {
		t.Errorf("Expected label 'backend', got %q", view.Label)
	}
	if view.Status != StatusRunning {
		t.Errorf("Expected status Running, got %v", view.Status)
	}
	if view.PID != 12345 {
		t.Errorf("Expected PID 12345, got %d", view.PID)
	}
	if view.Config == nil {
		t.Error("Expected config to be set")
	}
}

func TestProcess_ToView_NilController(t *testing.T) {
	proc := Process{
		ID:    5,
		Label: "backend",
		Config: &config.ProcessConfig{
			Shell: "npm run dev",
		},
	}

	view := proc.ToView(nil)

	if view.Status != StatusHalted {
		t.Errorf("Expected status Halted with nil controller, got %v", view.Status)
	}
	if view.PID != -1 {
		t.Errorf("Expected PID -1 with nil controller, got %d", view.PID)
	}
}

func TestProcess_ToView_HaltedProcess(t *testing.T) {
	proc := Process{
		ID:    10,
		Label: "stopped-service",
		Config: &config.ProcessConfig{
			Shell: "service start",
		},
	}

	controller := &mockProcessController{
		status: StatusHalted,
		pid:    -1,
	}

	view := proc.ToView(controller)

	if view.Status != StatusHalted {
		t.Errorf("Expected status Halted, got %v", view.Status)
	}
	if view.PID != -1 {
		t.Errorf("Expected PID -1, got %d", view.PID)
	}
}
