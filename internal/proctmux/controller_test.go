package proctmux

import (
	"sync/atomic"
	"testing"
)

func TestAddProcess(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	state := NewAppState(cfg)
	p := &Process{Name: "test"}
	state.AddProcess(p)
	if len(state.Processes) != 1 {
		t.Fatal("Process not added")
	}
	if state.Processes[0].ID != 0 {
		t.Fatal("Process ID not set correctly")
	}
}

func TestSetProcessStatus(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	state := NewAppState(cfg)
	p := &Process{Name: "test"}
	state.AddProcess(p)
	state.SetProcessStatus(0, StatusRunning)
	if state.Processes[0].Status != StatusRunning {
		t.Fatal("Process status not set correctly")
	}
}

func TestAddMessageAndError(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	state := NewAppState(cfg)
	state.AddMessage("info message")
	if state.Info != "info message" {
		t.Fatal("Info message not set correctly")
	}
	if len(state.Messages) != 1 {
		t.Fatal("Message not added to queue")
	}
	state.AddError(assertAnError())
	if state.Info == "" {
		t.Fatal("Error message not set correctly")
	}
	if len(state.Messages) != 2 {
		t.Fatal("Error not added to queue")
	}
}

func TestNavigationEdgeCases(t *testing.T) {
	cfg := &ProcTmuxConfig{}
	state := NewAppState(cfg)
	controller := NewController(state, &TmuxContext{}, newAtomicBool())
	controller.OnKeypressDown()
	controller.OnKeypressUp()
	if state.ActiveIdx != 0 {
		t.Fatal("ActiveIdx should remain 0 with no processes")
	}
	state.AddProcess(&Process{Name: "p1"})
	controller.OnKeypressDown()
	controller.OnKeypressUp()
	if state.ActiveIdx != 0 {
		t.Fatal("ActiveIdx should remain 0 with one process")
	}
}

func newAtomicBool() *atomic.Bool {
	b := new(atomic.Bool)
	b.Store(true)
	return b
}

func assertAnError() error {
	return &testError{"fail"}
}

type testError struct{ msg string }

func (e *testError) Error() string { return e.msg }
