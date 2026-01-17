package e2e

import (
	"os"
	"path/filepath"
	"testing"
)

// WriteConfig writes the provided YAML contents to proctmux.yaml inside a temporary directory.
// It returns the directory and absolute path to the written file.
func WriteConfig(t testing.TB, contents string) (dir string, configPath string) {
	t.Helper()
	dir = t.TempDir()
	configPath = filepath.Join(dir, "proctmux.yaml")
	if err := os.WriteFile(configPath, []byte(contents), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return dir, configPath
}
