package domain

import (
	"slices"
	"testing"

	"github.com/nick/proctmux/internal/config"
)

func TestNewAppState_Basic(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			PlaceholderBanner: "TEST BANNER",
		},
		Procs: map[string]config.ProcessConfig{
			"backend": {
				Shell: "npm run dev",
			},
			"frontend": {
				Cmd: []string{"yarn", "start"},
			},
		},
	}

	state := NewAppState(cfg)

	// Check config is set
	if state.Config != cfg {
		t.Error("Config not set correctly")
	}

	if len(state.Processes) != 2 {
		t.Fatalf("Expected 2 processes, got %d", len(state.Processes))
	}

	labels := []string{state.Processes[0].Label, state.Processes[1].Label}
	if !(slices.Contains(labels, "backend") && slices.Contains(labels, "frontend")) {
		t.Fatalf("Expected backend and frontend processes, got %v", labels)
	}
	if state.Processes[0].ID != 1 || state.Processes[1].ID != 2 {
		t.Errorf("Expected sequential IDs starting at 1, got %d and %d", state.Processes[0].ID, state.Processes[1].ID)
	}

	// Check not exiting
	if state.Exiting {
		t.Error("State should not be exiting on initialization")
	}
}

func TestNewAppState_NoProcessesWhenOnlyBanner(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			PlaceholderBanner: "LINE1\nLINE2\n  \nLINE3",
		},
		Procs: map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)
	if len(state.Processes) != 0 {
		t.Fatalf("Expected no processes, got %d", len(state.Processes))
	}
}

func TestNewAppState_AlphabeticalSort(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			SortProcessListAlpha: true,
		},
		Procs: map[string]config.ProcessConfig{
			"zebra": {Shell: "echo zebra"},
			"apple": {Shell: "echo apple"},
			"mango": {Shell: "echo mango"},
		},
	}

	state := NewAppState(cfg)

	if len(state.Processes) != 3 {
		t.Fatalf("Expected 3 processes, got %d", len(state.Processes))
	}

	expected := []string{"apple", "mango", "zebra"}
	for i, expectedLabel := range expected {
		if state.Processes[i].Label != expectedLabel {
			t.Errorf("Position %d: expected %q, got %q", i, expectedLabel, state.Processes[i].Label)
		}
	}
}

func TestNewAppState_NoAlphabeticalSort(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			SortProcessListAlpha: false,
		},
		Procs: map[string]config.ProcessConfig{
			"zebra": {Shell: "echo zebra"},
			"apple": {Shell: "echo apple"},
		},
	}

	state := NewAppState(cfg)

	if len(state.Processes) != 2 {
		t.Fatalf("Expected 2 processes, got %d", len(state.Processes))
	}

	labels := []string{state.Processes[0].Label, state.Processes[1].Label}
	if !(slices.Contains(labels, "zebra") && slices.Contains(labels, "apple")) {
		t.Errorf("Expected zebra and apple processes, got %v", labels)
	}
}

func TestNewAppState_ProcessConfigsRemainDistinct(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"api": {
				Shell: "echo api",
				Env:   map[string]string{"ROLE": "api"},
			},
			"worker": {
				Shell: "echo worker",
				Env:   map[string]string{"ROLE": "worker"},
			},
		},
	}

	state := NewAppState(cfg)

	api := state.GetProcessByLabel("api")
	worker := state.GetProcessByLabel("worker")

	if api == nil || worker == nil {
		t.Fatalf("Expected both api and worker processes to be present")
	}

	if api.Config == worker.Config {
		t.Fatal("Processes should not share the same config pointer")
	}

	if api.Config.Shell != "echo api" {
		t.Fatalf("Expected api shell to remain intact, got %q", api.Config.Shell)
	}

	if worker.Config.Shell != "echo worker" {
		t.Fatalf("Expected worker shell to remain intact, got %q", worker.Config.Shell)
	}

	if api.Config.Env["ROLE"] != "api" {
		t.Fatalf("Expected api env to remain distinct, got %q", api.Config.Env["ROLE"])
	}

	if worker.Config.Env["ROLE"] != "worker" {
		t.Fatalf("Expected worker env to remain distinct, got %q", worker.Config.Env["ROLE"])
	}
}

func TestNewAppState_EmptyProcs(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{},
		Procs:  map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)

	if len(state.Processes) != 0 {
		t.Errorf("Expected no processes when config is empty, got %d", len(state.Processes))
	}
}

func TestAppState_GetProcessByID_Found(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"test": {Shell: "echo test"},
		},
	}

	state := NewAppState(cfg)

	test := state.GetProcessByID(1)
	if test == nil {
		t.Fatal("Expected to find test process")
	}
	if test.Label != "test" {
		t.Errorf("Expected label 'test', got %q", test.Label)
	}
}

func TestAppState_GetProcessByID_NotFound(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)

	result := state.GetProcessByID(999)
	if result != nil {
		t.Error("Expected nil for non-existent process ID")
	}
}

func TestAppState_GetProcessByLabel_Found(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"backend":  {Shell: "npm run dev"},
			"frontend": {Shell: "yarn start"},
		},
	}

	state := NewAppState(cfg)

	backend := state.GetProcessByLabel("backend")
	if backend == nil {
		t.Fatal("Expected to find backend process")
	}
	if backend.Label != "backend" {
		t.Errorf("Expected label 'backend', got %q", backend.Label)
	}

	frontend := state.GetProcessByLabel("frontend")
	if frontend == nil {
		t.Fatal("Expected to find frontend process")
	}
	if frontend.Label != "frontend" {
		t.Errorf("Expected label 'frontend', got %q", frontend.Label)
	}
}

func TestAppState_GetProcessByLabel_NotFound(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"backend": {Shell: "npm run dev"},
		},
	}

	state := NewAppState(cfg)

	result := state.GetProcessByLabel("nonexistent")
	if result != nil {
		t.Error("Expected nil for non-existent process label")
	}
}

func TestAppState_GetProcessByLabel_CaseSensitive(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"Backend": {Shell: "npm run dev"},
		},
	}

	state := NewAppState(cfg)

	// Exact match should work
	found := state.GetProcessByLabel("Backend")
	if found == nil {
		t.Error("Expected to find process with exact case match")
	}

	// Different case should not match
	notFound := state.GetProcessByLabel("backend")
	if notFound != nil {
		t.Error("Expected case-sensitive matching - 'backend' should not match 'Backend'")
	}
}

func TestAppState_CurrentProcID_Initial(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)

	if state.CurrentProcID != 0 {
		t.Errorf("Expected CurrentProcID to be 0, got %d", state.CurrentProcID)
	}
}

func TestMode_Constants(t *testing.T) {
	// Just verify the constants are defined and distinct
	if NormalMode == FilterMode {
		t.Error("NormalMode and FilterMode should be different")
	}
}

func TestStateUpdate_Struct(t *testing.T) {
	// Just verify the StateUpdate struct can be created
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{},
	}
	state := NewAppState(cfg)

	update := StateUpdate{
		State:        &state,
		ProcessViews: []ProcessView{},
	}

	if update.State == nil {
		t.Error("StateUpdate.State should not be nil")
	}
	if update.ProcessViews == nil {
		t.Error("StateUpdate.ProcessViews should not be nil")
	}
}
