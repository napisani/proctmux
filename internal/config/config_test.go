package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigAndDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "proctmux.yaml")
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig error: %v", err)
	}
	if len(cfg.Keybinding.Quit) == 0 {
		t.Fatalf("expected default keybinding.quit to be set")
	}
	if cfg.Layout.CategorySearchPrefix == "" {
		t.Fatalf("expected default category prefix")
	}
	if cfg.General.DetachedSessionName == "" {
		t.Fatalf("expected default detached session name")
	}
}
