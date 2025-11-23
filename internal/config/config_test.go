package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfig_ValidYAML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "proctmux.yaml")

	yaml := `
general:
  detached_session_name: my_session
  kill_existing_session: true

keybinding:
  quit: ["q"]
  up: ["k"]

procs:
  backend:
    shell: "npm run dev"
    autostart: true
`

	if err := os.WriteFile(path, []byte(yaml), 0600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig error: %v", err)
	}

	// Check loaded values
	if cfg.General.DetachedSessionName != "my_session" {
		t.Errorf("Expected detached_session_name 'my_session', got %q", cfg.General.DetachedSessionName)
	}
	if !cfg.General.KillExistingSession {
		t.Error("Expected KillExistingSession to be true")
	}
	if len(cfg.Keybinding.Quit) != 1 || cfg.Keybinding.Quit[0] != "q" {
		t.Errorf("Expected quit keybinding ['q'], got %v", cfg.Keybinding.Quit)
	}

	// Check that other defaults were still applied
	if len(cfg.Keybinding.Down) == 0 {
		t.Error("Expected default down keybinding to be set")
	}
}

func TestLoadConfig_EmptyYAML_AppliesDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "proctmux.yaml")
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig error: %v", err)
	}

	// Verify all defaults are applied
	if len(cfg.Keybinding.Quit) == 0 {
		t.Error("Expected default keybinding.quit to be set")
	}
	if cfg.Layout.CategorySearchPrefix == "" {
		t.Error("Expected default category prefix")
	}
	if cfg.General.DetachedSessionName == "" {
		t.Error("Expected default detached session name")
	}
	if cfg.Style.PointerChar == "" {
		t.Error("Expected default pointer char")
	}
}

func TestLoadConfig_DefaultPaths(t *testing.T) {
	dir := t.TempDir()
	oldWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Failed to get working directory: %v", err)
	}
	defer os.Chdir(oldWd)

	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Failed to change directory: %v", err)
	}

	// Test each default path
	defaultPaths := []string{"proctmux.yaml", "proctmux.yml", "procmux.yaml", "procmux.yml"}

	for _, defaultPath := range defaultPaths {
		t.Run(defaultPath, func(t *testing.T) {
			// Clean up any existing files
			for _, p := range defaultPaths {
				os.Remove(p)
			}

			// Create config at this path
			if err := os.WriteFile(defaultPath, []byte("{}"), 0600); err != nil {
				t.Fatalf("write config: %v", err)
			}

			// Load without specifying path
			cfg, err := LoadConfig("")
			if err != nil {
				t.Fatalf("LoadConfig error: %v", err)
			}

			if cfg == nil {
				t.Fatal("Expected config to be loaded")
			}

			// Clean up
			os.Remove(defaultPath)
		})
	}
}

func TestLoadConfig_NoDefaultsFound(t *testing.T) {
	dir := t.TempDir()
	oldWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Failed to get working directory: %v", err)
	}
	defer os.Chdir(oldWd)

	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Failed to change directory: %v", err)
	}

	// Try to load config without specifying path and without any default files
	_, err = LoadConfig("")
	if err == nil {
		t.Fatal("Expected error when no default config files exist")
	}

	expectedError := "config file not found in default locations"
	if err.Error() != expectedError {
		t.Errorf("Expected error %q, got %q", expectedError, err.Error())
	}
}

func TestLoadConfig_FileDoesNotExist(t *testing.T) {
	_, err := LoadConfig("/nonexistent/path/config.yaml")
	if err == nil {
		t.Fatal("Expected error when file doesn't exist")
	}
}

func TestLoadConfig_MalformedYAML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.yaml")

	badYAML := `
general:
  detached_session_name: "unclosed string
invalid yaml content
`

	if err := os.WriteFile(path, []byte(badYAML), 0600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	_, err := LoadConfig(path)
	if err == nil {
		t.Fatal("Expected error when YAML is malformed")
	}
}

func TestLoadConfig_InvalidPermissions(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("Skipping permission test when running as root")
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "noperm.yaml")

	if err := os.WriteFile(path, []byte("{}"), 0000); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	defer os.Chmod(path, 0600) // Cleanup

	_, err := LoadConfig(path)
	if err == nil {
		t.Fatal("Expected error when file can't be opened due to permissions")
	}
}

func TestToHash_SameConfig_SameHash(t *testing.T) {
	cfg1 := &ProcTmuxConfig{
		General: struct {
			DetachedSessionName string `yaml:"detached_session_name"`
			KillExistingSession bool   `yaml:"kill_existing_session"`
		}{
			DetachedSessionName: "test",
			KillExistingSession: true,
		},
	}

	cfg2 := &ProcTmuxConfig{
		General: struct {
			DetachedSessionName string `yaml:"detached_session_name"`
			KillExistingSession bool   `yaml:"kill_existing_session"`
		}{
			DetachedSessionName: "test",
			KillExistingSession: true,
		},
	}

	hash1, err := cfg1.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	hash2, err := cfg2.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	if hash1 != hash2 {
		t.Errorf("Expected same hash for identical configs, got %q and %q", hash1, hash2)
	}
}

func TestToHash_DifferentConfig_DifferentHash(t *testing.T) {
	cfg1 := &ProcTmuxConfig{
		General: struct {
			DetachedSessionName string `yaml:"detached_session_name"`
			KillExistingSession bool   `yaml:"kill_existing_session"`
		}{
			DetachedSessionName: "session1",
		},
	}

	cfg2 := &ProcTmuxConfig{
		General: struct {
			DetachedSessionName string `yaml:"detached_session_name"`
			KillExistingSession bool   `yaml:"kill_existing_session"`
		}{
			DetachedSessionName: "session2",
		},
	}

	hash1, err := cfg1.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	hash2, err := cfg2.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	if hash1 == hash2 {
		t.Error("Expected different hashes for different configs")
	}
}

func TestToHash_ChangingKeybinding_ChangesHash(t *testing.T) {
	cfg1 := &ProcTmuxConfig{
		Keybinding: KeybindingConfig{
			Quit: []string{"q"},
		},
	}

	cfg2 := &ProcTmuxConfig{
		Keybinding: KeybindingConfig{
			Quit: []string{"x"},
		},
	}

	hash1, err := cfg1.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	hash2, err := cfg2.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	if hash1 == hash2 {
		t.Error("Expected different hashes when keybinding changes")
	}
}

func TestToHash_ChangingProcess_ChangesHash(t *testing.T) {
	cfg1 := &ProcTmuxConfig{
		Procs: map[string]ProcessConfig{
			"backend": {Shell: "npm run dev"},
		},
	}

	cfg2 := &ProcTmuxConfig{
		Procs: map[string]ProcessConfig{
			"backend": {Shell: "yarn dev"},
		},
	}

	hash1, err := cfg1.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	hash2, err := cfg2.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	if hash1 == hash2 {
		t.Error("Expected different hashes when process config changes")
	}
}

func TestToHash_ReturnsHexString(t *testing.T) {
	cfg := &ProcTmuxConfig{}

	hash, err := cfg.ToHash()
	if err != nil {
		t.Fatalf("ToHash error: %v", err)
	}

	// MD5 hash should be 32 hex characters
	if len(hash) != 32 {
		t.Errorf("Expected hash length 32, got %d", len(hash))
	}

	// Should be all hex characters
	for _, c := range hash {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Errorf("Hash should contain only hex characters, found %c", c)
		}
	}
}

func TestApplyDefaults_AllKeybindings(t *testing.T) {
	cfg := ProcTmuxConfig{}
	cfg = applyDefaults(cfg)

	tests := []struct {
		name     string
		bindings []string
	}{
		{"Quit", cfg.Keybinding.Quit},
		{"Up", cfg.Keybinding.Up},
		{"Down", cfg.Keybinding.Down},
		{"Start", cfg.Keybinding.Start},
		{"Stop", cfg.Keybinding.Stop},
		{"Restart", cfg.Keybinding.Restart},
		{"Filter", cfg.Keybinding.Filter},
		{"FilterSubmit", cfg.Keybinding.FilterSubmit},
		{"ToggleRunning", cfg.Keybinding.ToggleRunning},
		{"ToggleHelp", cfg.Keybinding.ToggleHelp},
		{"Docs", cfg.Keybinding.Docs},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.bindings) == 0 {
				t.Errorf("Expected default keybinding for %s to be set", tt.name)
			}
		})
	}
}

func TestApplyDefaults_SpecificKeybindingValues(t *testing.T) {
	cfg := ProcTmuxConfig{}
	cfg = applyDefaults(cfg)

	if cfg.Keybinding.Quit[0] != "q" {
		t.Errorf("Expected first quit binding to be 'q', got %q", cfg.Keybinding.Quit[0])
	}
	if cfg.Keybinding.Filter[0] != "/" {
		t.Errorf("Expected filter binding to be '/', got %q", cfg.Keybinding.Filter[0])
	}
	if cfg.Keybinding.ToggleRunning[0] != "R" {
		t.Errorf("Expected toggle running binding to be 'R', got %q", cfg.Keybinding.ToggleRunning[0])
	}
	if cfg.Keybinding.ToggleHelp[0] != "?" {
		t.Errorf("Expected toggle help binding to be '?', got %q", cfg.Keybinding.ToggleHelp[0])
	}
	if cfg.Keybinding.Docs[0] != "d" {
		t.Errorf("Expected docs binding to be 'd', got %q", cfg.Keybinding.Docs[0])
	}
}

func TestApplyDefaults_LayoutDefaults(t *testing.T) {
	cfg := ProcTmuxConfig{}
	cfg = applyDefaults(cfg)

	if cfg.Layout.CategorySearchPrefix == "" {
		t.Error("Expected CategorySearchPrefix to have default value")
	}
	if cfg.Layout.CategorySearchPrefix != "cat:" {
		t.Errorf("Expected CategorySearchPrefix 'cat:', got %q", cfg.Layout.CategorySearchPrefix)
	}

	if cfg.Layout.PlaceholderBanner == "" {
		t.Error("Expected PlaceholderBanner to have default value")
	}

	if cfg.Layout.ProcessesListWidth == 0 {
		t.Error("Expected ProcessesListWidth to have default value")
	}
	if cfg.Layout.ProcessesListWidth != 30 {
		t.Errorf("Expected ProcessesListWidth 30, got %d", cfg.Layout.ProcessesListWidth)
	}
}

func TestApplyDefaults_WidthClamping(t *testing.T) {
	tests := []struct {
		input    int
		expected int
	}{
		{0, 30},    // Invalid: 0
		{-10, 30},  // Invalid: negative
		{101, 30},  // Invalid: > 100
		{50, 50},   // Valid
		{1, 1},     // Valid: min
		{99, 99},   // Valid: max
		{100, 100}, // Valid: exactly 100
	}

	for _, tt := range tests {
		t.Run("", func(t *testing.T) {
			cfg := ProcTmuxConfig{
				Layout: LayoutConfig{
					ProcessesListWidth: tt.input,
				},
			}
			cfg = applyDefaults(cfg)

			if cfg.Layout.ProcessesListWidth != tt.expected {
				t.Errorf("Input %d: expected %d, got %d", tt.input, tt.expected, cfg.Layout.ProcessesListWidth)
			}
		})
	}
}

func TestApplyDefaults_StyleDefaults(t *testing.T) {
	cfg := ProcTmuxConfig{}
	cfg = applyDefaults(cfg)

	if cfg.Style.PointerChar != "▶" {
		t.Errorf("Expected PointerChar '▶', got %q", cfg.Style.PointerChar)
	}
	if cfg.Style.SelectedProcessColor == "" {
		t.Error("Expected SelectedProcessColor to have default")
	}
	if cfg.Style.SelectedProcessBgColor == "" {
		t.Error("Expected SelectedProcessBgColor to have default")
	}
	if cfg.Style.StatusRunningColor == "" {
		t.Error("Expected StatusRunningColor to have default")
	}
	if cfg.Style.StatusHaltingColor == "" {
		t.Error("Expected StatusHaltingColor to have default")
	}
	if cfg.Style.StatusStoppedColor == "" {
		t.Error("Expected StatusStoppedColor to have default")
	}
	if cfg.Style.ColorLevel == "" {
		t.Error("Expected ColorLevel to have default")
	}
}

func TestApplyDefaults_GeneralDefaults(t *testing.T) {
	cfg := ProcTmuxConfig{}
	cfg = applyDefaults(cfg)

	if cfg.General.DetachedSessionName != "_proctmux" {
		t.Errorf("Expected DetachedSessionName '_proctmux', got %q", cfg.General.DetachedSessionName)
	}
}

func TestApplyDefaults_PartialConfig(t *testing.T) {
	// Config with some values set, others empty
	cfg := ProcTmuxConfig{
		Keybinding: KeybindingConfig{
			Quit: []string{"x"}, // Custom value
			// Other keybindings empty
		},
		Layout: LayoutConfig{
			ProcessesListWidth: 40, // Custom value
		},
	}

	cfg = applyDefaults(cfg)

	// Custom values should be preserved
	if len(cfg.Keybinding.Quit) != 1 || cfg.Keybinding.Quit[0] != "x" {
		t.Error("Custom quit keybinding should be preserved")
	}
	if cfg.Layout.ProcessesListWidth != 40 {
		t.Error("Custom ProcessesListWidth should be preserved")
	}

	// Defaults should be applied to empty values
	if len(cfg.Keybinding.Up) == 0 {
		t.Error("Expected default Up keybinding")
	}
	if cfg.Layout.CategorySearchPrefix == "" {
		t.Error("Expected default CategorySearchPrefix")
	}
}
