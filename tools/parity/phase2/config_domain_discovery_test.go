package phase2

import (
	"path/filepath"
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/procdiscover"

	_ "github.com/nick/proctmux/internal/procdiscover/makefile"
	_ "github.com/nick/proctmux/internal/procdiscover/packagejson"
)

func fixturePath(t *testing.T, parts ...string) string {
	t.Helper()
	all := append([]string{"..", "..", "..", "testdata", "phase2"}, parts...)
	path, err := filepath.Abs(filepath.Join(all...))
	if err != nil {
		t.Fatalf("abs fixture path: %v", err)
	}
	return path
}

func TestGoReferenceLoadsActiveFixture(t *testing.T) {
	cfg, err := config.LoadConfig(fixturePath(t, "config", "full-active.yaml"))
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Layout.ProcessesListWidth != 45 {
		t.Fatalf("expected width 45, got %d", cfg.Layout.ProcessesListWidth)
	}
	if !cfg.Layout.HideProcessListWhenUnfocused {
		t.Fatalf("expected hide_process_list_when_unfocused true")
	}
	if !cfg.General.ProcsFromMakeTargets || !cfg.General.ProcsFromPackageJSON {
		t.Fatalf("expected discovery toggles true")
	}
	if got := cfg.Procs["backend"].Categories[1]; got != "api" {
		t.Fatalf("expected backend api category, got %q", got)
	}
}

func TestGoReferenceDiscoveryFixture(t *testing.T) {
	cfg := &config.ProcTmuxConfig{}
	cfg.General.ProcsFromMakeTargets = true
	cfg.General.ProcsFromPackageJSON = true
	cfg.Procs = map[string]config.ProcessConfig{
		"make:build": {Shell: "make build", Description: "custom"},
	}

	procdiscover.Apply(cfg, fixturePath(t, "discovery"))

	if cfg.Procs["make:build"].Description != "custom" {
		t.Fatalf("manual make:build should win")
	}
	if _, ok := cfg.Procs["make:test"]; !ok {
		t.Fatalf("expected make:test")
	}
	if _, ok := cfg.Procs["pnpm:dev"]; !ok {
		t.Fatalf("expected pnpm:dev")
	}
	if _, ok := cfg.Procs["pnpm:bad script"]; ok {
		t.Fatalf("invalid script name should be skipped")
	}
}

func TestGoReferenceFilterFixture(t *testing.T) {
	cfg := &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			CategorySearchPrefix:        "cat:",
			SortProcessListAlpha:        true,
			SortProcessListRunningFirst: true,
		},
	}
	views := []domain.ProcessView{
		{ID: 1, Label: "halted-zebra", Status: domain.StatusHalted, Config: &config.ProcessConfig{Categories: []string{"server"}}},
		{ID: 2, Label: "running-mango", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"server", "api"}}},
		{ID: 3, Label: "halted-apple", Status: domain.StatusHalted, Config: &config.ProcessConfig{Categories: []string{"client"}}},
		{ID: 4, Label: "running-banana", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"server"}}},
	}

	filtered := domain.FilterProcesses(cfg, views, "", false)
	want := []string{"running-banana", "running-mango", "halted-apple", "halted-zebra"}
	for i, label := range want {
		if filtered[i].Label != label {
			t.Fatalf("position %d: expected %q, got %q", i, label, filtered[i].Label)
		}
	}

	cat := domain.FilterProcesses(cfg, views, "cat:server,api", false)
	if len(cat) != 1 || cat[0].Label != "running-mango" {
		t.Fatalf("expected running-mango category result, got %#v", cat)
	}
}
