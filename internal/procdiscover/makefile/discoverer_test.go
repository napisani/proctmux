package makefile

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nick/proctmux/internal/procdiscover"
)

func TestDiscovererDiscoverTargets(t *testing.T) {
	d := &discoverer{}
	dir := t.TempDir()
	makefile := `build:
	@echo "building"

test:
	@echo "testing"

.PHONY: build test
`
	if err := os.WriteFile(filepath.Join(dir, "Makefile"), []byte(makefile), 0o644); err != nil {
		t.Fatalf("failed to write Makefile: %v", err)
	}

	procs, err := d.Discover(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(procs) == 0 {
		t.Fatalf("expected discovered processes, got none")
	}

	build, ok := procs["make:build"]
	if !ok {
		t.Fatalf("expected make:build to be discovered")
	}
	if build.Shell != "make build" {
		t.Fatalf("unexpected shell for make:build: %q", build.Shell)
	}

	testProc, ok := procs["make:test"]
	if !ok {
		t.Fatalf("expected make:test to be discovered")
	}
	if testProc.Categories == nil || len(testProc.Categories) == 0 || testProc.Categories[0] != "makefile" {
		t.Fatalf("expected make:test category to include makefile, got %#v", testProc.Categories)
	}
}

func TestDiscovererMissingMakefile(t *testing.T) {
	d := &discoverer{}
	_, err := d.Discover(t.TempDir())
	if err == nil {
		t.Fatalf("expected error when Makefile missing")
	}
	if !errors.Is(err, procdiscover.ErrSourceNotFound) {
		t.Fatalf("expected ErrSourceNotFound, got %v", err)
	}
}
