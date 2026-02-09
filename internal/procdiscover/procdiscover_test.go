package procdiscover_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/procdiscover"

	_ "github.com/nick/proctmux/internal/procdiscover/makefile"
	_ "github.com/nick/proctmux/internal/procdiscover/packagejson"
)

func TestApplyMergesDiscoveredProcesses(t *testing.T) {
	dir := t.TempDir()

	makefile := "build:\n\t@echo build\ntest:\n\t@echo test\n"
	if err := os.WriteFile(filepath.Join(dir, "Makefile"), []byte(makefile), 0o644); err != nil {
		t.Fatalf("failed to write Makefile: %v", err)
	}

	packageJSON := `{"scripts":{"dev":"node server.js","build":"pnpm run compile"}}`
	if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(packageJSON), 0o644); err != nil {
		t.Fatalf("failed to write package.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "pnpm-lock.yaml"), []byte(""), 0o644); err != nil {
		t.Fatalf("failed to write pnpm-lock.yaml: %v", err)
	}

	cfg := &config.ProcTmuxConfig{}
	cfg.General.ProcsFromMakeTargets = true
	cfg.General.ProcsFromPackageJSON = true
	cfg.Procs = map[string]config.ProcessConfig{
		"make:build": {Shell: "make build", Description: "custom"},
	}

	procdiscover.Apply(cfg, dir)

	if _, exists := cfg.Procs["make:build"]; !exists {
		t.Fatalf("existing make:build process should remain defined")
	}

	if _, exists := cfg.Procs["make:test"]; !exists {
		t.Fatalf("expected make:test to be discovered")
	}

	if _, exists := cfg.Procs["pnpm:dev"]; !exists {
		t.Fatalf("expected pnpm:dev to be discovered")
	}

	if _, exists := cfg.Procs["pnpm:build"]; !exists {
		t.Fatalf("expected pnpm:build to be discovered")
	}

	if cfg.Procs["make:build"].Description != "custom" {
		t.Fatalf("manual process should take precedence over discovered one")
	}
}
