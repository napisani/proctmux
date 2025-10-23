package proctmux

import (
	"path/filepath"
	"sync/atomic"
	"testing"
)

func newTestController(t *testing.T, cfg *ProcTmuxConfig) (*Controller, *AppState, *TmuxContext) {
	t.Helper()
	mock := filepath.Join("testdata", "tmux-mock.sh")
	t.Setenv("PROCTMUX_TMUX_BIN", mock)
	state := NewAppState(cfg)
	ctx := NewTmuxContextWithIDs("%0", "$0", "$100", state.Config.Layout.ProcessesListWidth)
	var running atomic.Bool
	c := NewController(&state, ctx, &running)
	return c, &state, ctx
}

func TestController_OnStartup_AutostartsProcesses(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{
		"A": {Cmd: []string{"echo", "A"}, Cwd: ".", Autostart: true},
		"B": {Cmd: []string{"echo", "B"}, Cwd: "."},
	}}
	c, _, _ := newTestController(t, cfg)
	if err := c.OnStartup(); err != nil {
		t.Fatalf("OnStartup error: %v", err)
	}
	// Verify autostarted process is running
	var got Process
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		p := s.GetProcessByLabel("A")
		if p == nil {
			t.Fatalf("process A not found")
		}
		got = *p
		return s, nil
	})
	if got.Status != StatusRunning || got.PID <= 0 {
		t.Fatalf("autostarted process not running as expected: %+v", got)
	}
}

func TestController_StateSubscriptionEmitsUpdates(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{"A": {Cmd: []string{"echo"}}}}
	c, _, _ := newTestController(t, cfg)
	ch := make(chan StateUpdateMsg, 1)
	c.SubscribeToStateChanges(ch)
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		return NewStateMutation(s).SetExiting().Commit(), nil
	})
	select {
	case <-ch:
		// received update
	default:
		t.Fatalf("did not receive state update on subscription")
	}
}

func TestController_OnKeypressStart_StartsCurrent(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{
		"A": {Cmd: []string{"echo", "A"}, Cwd: "."},
		"B": {Cmd: []string{"echo", "B"}, Cwd: "."},
	}}
	c, _, _ := newTestController(t, cfg)
	// Select first non-dummy process
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		return NewStateMutation(s).SelectFirstProcess().Commit(), nil
	})
	if err := c.OnKeypressStart(); err != nil {
		t.Fatalf("OnKeypressStart error: %v", err)
	}
	var p *Process
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		p = s.GetCurrentProcess()
		return s, nil
	})
	if p == nil || p.Status != StatusRunning || p.PID <= 0 {
		t.Fatalf("current process not running as expected: %+v", p)
	}
}

func TestController_OnFilterStart_ClearsSelection(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{"A": {Cmd: []string{"echo"}}}}
	c, _, _ := newTestController(t, cfg)
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		return NewStateMutation(s).SelectFirstProcess().Commit(), nil
	})
	if err := c.OnFilterStart(); err != nil {
		t.Fatalf("OnFilterStart error: %v", err)
	}
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		if s.CurrentProcID != 0 {
			t.Fatalf("expected selection cleared; got %d", s.CurrentProcID)
		}
		return s, nil
	})
}

func TestController_OnPidTerminated_UpdatesState(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{"A": {Cmd: []string{"echo"}}}}
	c, _, _ := newTestController(t, cfg)
	var pid int
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		p := s.GetProcessByLabel("A")
		p.Status = StatusRunning
		p.PID = 12345
		p.PaneID = "%100"
		pid = p.PID
		return s, nil
	})
	c.OnPidTerminated(pid)
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		p := s.GetProcessByLabel("A")
		if p.Status != StatusHalted || p.PID != -1 {
			t.Fatalf("expected halted and pid=-1; got status=%v pid=%d", p.Status, p.PID)
		}
		return s, nil
	})
}

func TestController_OnKeypressDocs_ShowsPopup(t *testing.T) {
	cfg := &ProcTmuxConfig{Procs: map[string]ProcessConfig{"A": {Cmd: []string{"echo"}, Docs: "hello"}}}
	c, _, _ := newTestController(t, cfg)
	_ = c.LockAndLoad(func(s *AppState) (*AppState, error) {
		return NewStateMutation(s).SelectFirstProcess().Commit(), nil
	})
	if err := c.OnKeypressDocs(); err != nil {
		t.Fatalf("OnKeypressDocs error: %v", err)
	}
}
