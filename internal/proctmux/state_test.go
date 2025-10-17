package proctmux

import "testing"

func TestMoveProcessSelectionWrapAround(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	cfg.Layout.CategorySearchPrefix = "cat:"
	cfg.Procs = map[string]ProcessConfig{
		"A": {Cmd: []string{"echo", "A"}},
		"B": {Cmd: []string{"echo", "B"}},
	}
	state := NewAppState(cfg)
	state.SelectFirstProcess()
	first := state.CurrentProcID
	state.MoveProcessSelection(1)
	second := state.CurrentProcID
	if second == first {
		t.Fatalf("expected selection to change")
	}
	state.MoveProcessSelection(1)
	// wrap around back to first
	if state.CurrentProcID != first {
		t.Fatalf("expected wrap-around to first; got %d, want %d", state.CurrentProcID, first)
	}
}
