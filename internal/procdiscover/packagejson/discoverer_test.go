package packagejson

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func writePackageJSON(t *testing.T, dir string, scripts map[string]string) {
	t.Helper()
	packageJSONPath := filepath.Join(dir, "package.json")
	payload := struct {
		Scripts map[string]string `json:"scripts"`
	}{Scripts: scripts}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("failed to marshal package.json: %v", err)
	}
	if err := os.WriteFile(packageJSONPath, data, 0o600); err != nil {
		t.Fatalf("failed to write package.json: %v", err)
	}
}

func TestDiscoverSkipsInvalidScriptNamesAndUsesCmd(t *testing.T) {
	dir := t.TempDir()
	writePackageJSON(t, dir, map[string]string{
		"build":      "echo build",
		"bad script": "rm -rf /",
	})

	disc := &discoverer{}
	procs, err := disc.Discover(dir)
	if err != nil {
		t.Fatalf("Discover returned error: %v", err)
	}

	proc, ok := procs["npm:build"]
	if !ok {
		t.Fatalf("expected npm:build process, got %v", procs)
	}
	if proc.Shell != "" {
		t.Fatalf("expected Shell to be empty, got %q", proc.Shell)
	}
	expectedCmd := []string{"npm", "run", "build"}
	if !reflect.DeepEqual(proc.Cmd, expectedCmd) {
		t.Fatalf("expected Cmd %v, got %v", expectedCmd, proc.Cmd)
	}

	if _, exists := procs["npm:bad script"]; exists {
		t.Fatalf("invalid script name should be skipped")
	}
}

func TestManagerBuildCommand(t *testing.T) {
	cases := []struct {
		prefix   string
		expected []string
	}{
		{"pnpm", []string{"pnpm", "run", "dev"}},
		{"yarn", []string{"yarn", "dev"}},
		{"bun", []string{"bun", "run", "dev"}},
		{"deno", []string{"deno", "task", "dev"}},
		{"npm", []string{"npm", "run", "dev"}},
	}

	for _, tc := range cases {
		mgr := managerInfo{prefix: tc.prefix}
		cmd := mgr.BuildCommand("dev")
		if !reflect.DeepEqual(cmd, tc.expected) {
			t.Fatalf("%s: expected %v, got %v", tc.prefix, tc.expected, cmd)
		}
	}
}
