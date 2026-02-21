package domain

import (
	"strings"
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

	// Should have 3 processes: dummy + 2 from config
	if len(state.Processes) != 3 {
		t.Errorf("Expected 3 processes (1 dummy + 2 config), got %d", len(state.Processes))
	}

	// First process should be dummy
	if state.Processes[0].ID != DummyProcessID {
		t.Errorf("Expected first process to be dummy (ID %d), got %d", DummyProcessID, state.Processes[0].ID)
	}
	if state.Processes[0].Label != "Dummy" {
		t.Errorf("Expected dummy label 'Dummy', got %q", state.Processes[0].Label)
	}

	// Dummy should autostart
	if !state.Processes[0].Config.Autostart {
		t.Error("Dummy process should have autostart enabled")
	}

	// Check that IDs start from 2 for non-dummy processes
	foundBackend := false
	foundFrontend := false
	for _, p := range state.Processes {
		if p.ID == DummyProcessID {
			continue
		}
		if p.ID < 2 {
			t.Errorf("Non-dummy process ID should be >= 2, got %d", p.ID)
		}
		if p.Label == "backend" {
			foundBackend = true
		}
		if p.Label == "frontend" {
			foundFrontend = true
		}
	}

	if !foundBackend {
		t.Error("Backend process not found")
	}
	if !foundFrontend {
		t.Error("Frontend process not found")
	}

	// Check not exiting
	if state.Exiting {
		t.Error("State should not be exiting on initialization")
	}
}

func TestNewAppState_DummyBannerGeneration(t *testing.T) {
	banner := "LINE1\nLINE2\n  \nLINE3"
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			PlaceholderBanner: banner,
		},
		Procs: map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)

	// Dummy should be first
	dummy := state.Processes[0]
	if dummy.ID != DummyProcessID {
		t.Fatal("First process should be dummy")
	}

	if dummy.Config.Shell != "" {
		t.Fatal("Dummy process should not rely on shell execution")
	}

	if len(dummy.Config.Cmd) < 2 {
		t.Fatalf("Expected printf format and arguments, got %#v", dummy.Config.Cmd)
	}

	if dummy.Config.Cmd[0] != "printf" {
		t.Fatalf("Expected printf command, got %q", dummy.Config.Cmd[0])
	}

	format := dummy.Config.Cmd[1]
	if strings.Count(format, "%s\n") != len(dummy.Config.Cmd)-2 {
		t.Fatalf("Format specifiers should match arguments, got %q (args=%d)", format, len(dummy.Config.Cmd)-2)
	}

	args := dummy.Config.Cmd[2:]
	expectedArgs := []string{"", "LINE1", "LINE2", "LINE3"}
	if len(args) != len(expectedArgs) {
		t.Fatalf("Expected %d printf arguments, got %d", len(expectedArgs), len(args))
	}
	for i, expected := range expectedArgs {
		if args[i] != expected {
			t.Fatalf("Argument %d: expected %q, got %q", i, expected, args[i])
		}
	}
}

func TestNewAppState_DummyBannerUsesPrintfWithoutShell(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{PlaceholderBanner: "LINE1\nLINE2"},
		Procs:  map[string]config.ProcessConfig{},
	}

	state := NewAppState(cfg)

	dummy := state.Processes[0]
	if dummy.ID != DummyProcessID {
		t.Fatalf("Expected dummy process first, got ID %d", dummy.ID)
	}

	if dummy.Config.Shell != "" {
		t.Fatalf("Dummy process should not rely on shell, got %q", dummy.Config.Shell)
	}

	if len(dummy.Config.Cmd) < 2 {
		t.Fatalf("Dummy command should invoke printf with format and args, got %#v", dummy.Config.Cmd)
	}

	if dummy.Config.Cmd[0] != "printf" {
		t.Fatalf("Expected dummy command to start with printf, got %q", dummy.Config.Cmd[0])
	}

	format := dummy.Config.Cmd[1]
	if strings.Count(format, "%s\n") != len(dummy.Config.Cmd)-2 {
		// There should be one %s per banner line argument (including initial blank)
		t.Fatalf("Format specifiers should match argument count, got format %q args %d", format, len(dummy.Config.Cmd)-2)
	}

	if dummy.Config.Cmd[2] != "" {
		t.Fatalf("First printf argument should be blank spacer, got %q", dummy.Config.Cmd[2])
	}

	if dummy.Config.Cmd[len(dummy.Config.Cmd)-1] != "LINE2" {
		t.Fatalf("Expected final banner argument to equal last line, got %q", dummy.Config.Cmd[len(dummy.Config.Cmd)-1])
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

	// Skip dummy (first process)
	nonDummy := state.Processes[1:]

	// Should be sorted alphabetically
	if len(nonDummy) != 3 {
		t.Fatalf("Expected 3 non-dummy processes, got %d", len(nonDummy))
	}

	expected := []string{"apple", "mango", "zebra"}
	for i, expectedLabel := range expected {
		if nonDummy[i].Label != expectedLabel {
			t.Errorf("Position %d: expected %q, got %q", i, expectedLabel, nonDummy[i].Label)
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

	// Map order is not guaranteed in Go, but we should have both processes
	nonDummy := state.Processes[1:]
	if len(nonDummy) != 2 {
		t.Fatalf("Expected 2 non-dummy processes, got %d", len(nonDummy))
	}

	// Just verify both are present (order doesn't matter)
	labels := make(map[string]bool)
	for _, p := range nonDummy {
		labels[p.Label] = true
	}

	if !labels["zebra"] {
		t.Error("zebra process not found")
	}
	if !labels["apple"] {
		t.Error("apple process not found")
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

	// Should only have dummy process
	if len(state.Processes) != 1 {
		t.Errorf("Expected 1 process (dummy only), got %d", len(state.Processes))
	}

	if state.Processes[0].ID != DummyProcessID {
		t.Error("Only process should be dummy")
	}
}

func TestAppState_GetProcessByID_Found(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Procs: map[string]config.ProcessConfig{
			"test": {Shell: "echo test"},
		},
	}

	state := NewAppState(cfg)

	// Get dummy by ID
	dummy := state.GetProcessByID(DummyProcessID)
	if dummy == nil {
		t.Fatal("Expected to find dummy process")
	}
	if dummy.ID != DummyProcessID {
		t.Errorf("Expected ID %d, got %d", DummyProcessID, dummy.ID)
	}

	// Get test process by ID (should be ID 2)
	test := state.GetProcessByID(2)
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

	dummy := state.GetProcessByLabel("Dummy")
	if dummy == nil {
		t.Fatal("Expected to find Dummy process")
	}
	if dummy.ID != DummyProcessID {
		t.Error("Expected to find dummy by label")
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

func TestDummyProcessID_Constant(t *testing.T) {
	// Verify the constant is defined
	if DummyProcessID != 1 {
		t.Errorf("Expected DummyProcessID to be 1, got %d", DummyProcessID)
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
