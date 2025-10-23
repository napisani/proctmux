package proctmux

import (
	"testing"
)

func TestStartProcessSetsState(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	cfg.Procs = map[string]ProcessConfig{
		"A": {Cmd: []string{"echo", "A"}, Cwd: "."},
	}
	state := NewAppState(cfg)
	server := NewProcessServer()
	proc := state.GetProcessByLabel("A")
	if proc == nil {
		t.Fatalf("process not found")
	}
	if proc.Status != StatusHalted {
		t.Fatalf("expected halted initially")
	}
	newState, err := startProcess(&state, server, proc, false)
	if err != nil {
		t.Fatalf("startProcess error: %v", err)
	}
	p := newState.GetProcessByLabel("A")
	if p.Status != StatusRunning || p.PID <= 0 {
		t.Fatalf("process not running with pid: %+v", p)
	}
}
