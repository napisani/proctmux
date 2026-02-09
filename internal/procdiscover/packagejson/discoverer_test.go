package packagejson

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nick/proctmux/internal/procdiscover"
)

func TestDiscovererScriptsDetectsManagers(t *testing.T) {
	cases := []struct {
		name             string
		lockFiles        map[string]string
		expectedPrefix   string
		expectedShell    string
		expectedCategory string
	}{
		{
			name: "pnpm",
			lockFiles: map[string]string{
				"pnpm-lock.yaml": "",
			},
			expectedPrefix:   "pnpm",
			expectedShell:    "pnpm run dev",
			expectedCategory: "pnpm",
		},
		{
			name: "bun",
			lockFiles: map[string]string{
				"bun.lockb": "",
			},
			expectedPrefix:   "bun",
			expectedShell:    "bun run dev",
			expectedCategory: "bun",
		},
		{
			name: "yarn",
			lockFiles: map[string]string{
				"yarn.lock": "",
			},
			expectedPrefix:   "yarn",
			expectedShell:    "yarn dev",
			expectedCategory: "yarn",
		},
		{
			name: "npm",
			lockFiles: map[string]string{
				"package-lock.json": "{}",
			},
			expectedPrefix:   "npm",
			expectedShell:    "npm run dev",
			expectedCategory: "npm",
		},
		{
			name: "deno",
			lockFiles: map[string]string{
				"deno.json": `{"tasks":{"dev":"deno task"}}`,
			},
			expectedPrefix:   "deno",
			expectedShell:    "deno task dev",
			expectedCategory: "deno",
		},
		{
			name:             "default-npm",
			lockFiles:        map[string]string{},
			expectedPrefix:   "npm",
			expectedShell:    "npm run dev",
			expectedCategory: "npm",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := &discoverer{}
			dir := t.TempDir()
			content := `{
		  "scripts": {
		    "dev": "node server.js"
		  }
		}`
			if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(content), 0o644); err != nil {
				t.Fatalf("failed to write package.json: %v", err)
			}
			for name, data := range tc.lockFiles {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644); err != nil {
					t.Fatalf("failed to write %s: %v", name, err)
				}
			}

			procs, err := d.Discover(dir)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if len(procs) != 1 {
				t.Fatalf("expected single discovered script, got %d", len(procs))
			}

			procName := tc.expectedPrefix + ":dev"
			proc, ok := procs[procName]
			if !ok {
				t.Fatalf("expected %s to be discovered", procName)
			}
			if proc.Shell != tc.expectedShell {
				t.Fatalf("unexpected shell for %s: %q", procName, proc.Shell)
			}
			if proc.Categories == nil || len(proc.Categories) == 0 || proc.Categories[0] != tc.expectedCategory {
				t.Fatalf("unexpected category for %s: %#v", procName, proc.Categories)
			}
			if !strings.Contains(proc.Description, tc.expectedCategory) {
				t.Fatalf("expected description to reference manager %s, got %q", tc.expectedCategory, proc.Description)
			}
		})
	}
}

func TestDiscovererMissingPackageJSON(t *testing.T) {
	d := &discoverer{}
	_, err := d.Discover(t.TempDir())
	if err == nil {
		t.Fatalf("expected error when package.json missing")
	}
	if !errors.Is(err, procdiscover.ErrSourceNotFound) {
		t.Fatalf("expected ErrSourceNotFound, got %v", err)
	}
}
