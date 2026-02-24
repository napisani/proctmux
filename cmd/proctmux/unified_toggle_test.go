package main

import (
	"testing"
	"time"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

func testConfig() *config.ProcTmuxConfig {
	return &config.ProcTmuxConfig{
		FilePath: "test.yaml",
		Procs: map[string]config.ProcessConfig{
			"web": {Shell: "echo hello"},
		},
	}
}

func TestLocalIPCServer_StartIsNoOp(t *testing.T) {
	s := newLocalIPCServer()
	if err := s.Start(""); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	if err := s.Start("/some/path"); err != nil {
		t.Fatalf("Start with path returned error: %v", err)
	}
}

func TestLocalIPCServer_StopIsNoOp(t *testing.T) {
	s := newLocalIPCServer()
	// Should not panic
	s.Stop()
}

func TestLocalIPCServer_BroadcastState(t *testing.T) {
	s := newLocalIPCServer()

	cfg := testConfig()
	state := domain.NewAppState(cfg)
	state.Processes = []domain.Process{
		{ID: 1, Label: "web", Config: &config.ProcessConfig{Shell: "echo hello"}},
	}

	pc := &mockProcessController{status: domain.StatusRunning, pid: 42}

	s.BroadcastState(&state, pc)

	select {
	case upd := <-s.updatesCh:
		if upd.State == nil {
			t.Fatal("expected state in update")
		}
		if len(upd.ProcessViews) != 1 {
			t.Fatalf("expected 1 process view, got %d", len(upd.ProcessViews))
		}
		if upd.ProcessViews[0].Label != "web" {
			t.Fatalf("expected label 'web', got %q", upd.ProcessViews[0].Label)
		}
		if upd.ProcessViews[0].Status != domain.StatusRunning {
			t.Fatalf("expected status Running, got %v", upd.ProcessViews[0].Status)
		}
		if upd.ProcessViews[0].PID != 42 {
			t.Fatalf("expected PID 42, got %d", upd.ProcessViews[0].PID)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for broadcast")
	}
}

func TestLocalIPCServer_BroadcastDropsOldestWhenFull(t *testing.T) {
	s := newLocalIPCServer()

	cfg := testConfig()
	state := domain.NewAppState(cfg)
	pc := &mockProcessController{status: domain.StatusHalted, pid: -1}

	// Fill the channel (capacity 10)
	for range 10 {
		s.BroadcastState(&state, pc)
	}

	// This broadcast should not block — it drops the oldest
	done := make(chan struct{})
	go func() {
		s.BroadcastState(&state, pc)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("BroadcastState blocked when channel was full")
	}
}

// mockProcessController for testing
type mockProcessController struct {
	status domain.ProcessStatus
	pid    int
}

func (m *mockProcessController) GetProcessStatus(id int) domain.ProcessStatus {
	return m.status
}

func (m *mockProcessController) GetPID(id int) int {
	return m.pid
}
