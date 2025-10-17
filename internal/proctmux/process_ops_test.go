package proctmux

import (
	"path/filepath"
	"testing"
)

func TestStartProcessSetsState(t *testing.T) {
	mock := filepath.Join("testdata", "tmux-mock.sh")
	t.Setenv("PROCTMUX_TMUX_BIN", mock)
	cfg := &ProcTmuxConfig{}
	cfg.Procs = map[string]ProcessConfig{
		"A": {Cmd: []string{"echo", "A"}, Cwd: "."},
	}
	state := NewAppState(cfg)
	ctx, err := NewTmuxContext("_proctmux", true, 30)
	if err != nil {
		t.Fatalf("NewTmuxContext: %v", err)
	}
	proc := state.GetProcessByLabel("A")
	if proc == nil {
		t.Fatalf("process not found")
	}
	if proc.Status != StatusHalted {
		t.Fatalf("expected halted initially")
	}
	newState, err := startProcess(&state, ctx, proc, false)
	if err != nil {
		t.Fatalf("startProcess error: %v", err)
	}
	p := newState.GetProcessByLabel("A")
	if p.Status != StatusRunning || p.PID <= 0 || p.PaneID == "" {
		t.Fatalf("process not running with pane/pid: %+v", p)
	}
}
