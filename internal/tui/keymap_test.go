package tui

import (
	"testing"

	"github.com/nick/proctmux/internal/config"
)

func TestNewKeyMap_AllBindingsCreated(t *testing.T) {
	cfg := config.KeybindingConfig{
		Quit:          []string{"q", "ctrl+c"},
		Up:            []string{"k", "up"},
		Down:          []string{"j", "down"},
		Start:         []string{"s", "enter"},
		Stop:          []string{"x"},
		Restart:       []string{"r"},
		Filter:        []string{"/"},
		FilterSubmit:  []string{"enter"},
		ToggleRunning: []string{"R"},
		ToggleHelp:    []string{"?"},
		ToggleFocus:   []string{"ctrl+w"},
		FocusClient:   []string{"ctrl+left"},
		FocusServer:   []string{"ctrl+right"},
		Docs:          []string{"d"},
	}

	km := NewKeyMap(cfg)

	// Verify all bindings are created (check they're not nil/empty)
	// We can't directly test key.Binding internal state, but we can verify
	// that the KeyMap struct fields are populated

	// Test by checking the help descriptions work
	fullHelp := km.FullHelp()
	if len(fullHelp) == 0 {
		t.Error("Expected FullHelp to return keybinding groups")
	}
}

func TestNewKeyMap_SingleKey(t *testing.T) {
	cfg := config.KeybindingConfig{
		Quit: []string{"q"},
		Up:   []string{"k"},
	}

	km := NewKeyMap(cfg)

	// Basic sanity check - keymap should be created
	if km.FullHelp() == nil {
		t.Error("Expected FullHelp to be available")
	}
}

func TestNewKeyMap_MultipleKeys(t *testing.T) {
	cfg := config.KeybindingConfig{
		Quit: []string{"q", "ctrl+c", "ctrl+d"},
	}

	km := NewKeyMap(cfg)

	// Keymap should handle multiple keys per binding
	if km.FullHelp() == nil {
		t.Error("Expected FullHelp to be available")
	}
}

func TestJoinKeys_Empty(t *testing.T) {
	result := joinKeys([]string{})
	if result != "" {
		t.Errorf("Expected empty string for empty keys, got %q", result)
	}
}

func TestJoinKeys_Single(t *testing.T) {
	result := joinKeys([]string{"q"})
	if result != "q" {
		t.Errorf("Expected 'q', got %q", result)
	}
}

func TestJoinKeys_SingleSpecial(t *testing.T) {
	result := joinKeys([]string{"up"})
	if result != "↑" {
		t.Errorf("Expected '↑', got %q", result)
	}
}

func TestJoinKeys_Multiple(t *testing.T) {
	result := joinKeys([]string{"k", "up"})
	if result != "k/↑" {
		t.Errorf("Expected 'k/↑', got %q", result)
	}
}

func TestJoinKeys_MultipleMoreThanTwo(t *testing.T) {
	// Should only show first two
	result := joinKeys([]string{"q", "ctrl+c", "x"})
	if result != "q/^C" {
		t.Errorf("Expected 'q/^C' (first two keys), got %q", result)
	}
}

func TestFormatKey_Up(t *testing.T) {
	result := formatKey("up")
	if result != "↑" {
		t.Errorf("Expected '↑', got %q", result)
	}
}

func TestFormatKey_Down(t *testing.T) {
	result := formatKey("down")
	if result != "↓" {
		t.Errorf("Expected '↓', got %q", result)
	}
}

func TestFormatKey_Left(t *testing.T) {
	result := formatKey("left")
	if result != "←" {
		t.Errorf("Expected '←', got %q", result)
	}
}

func TestFormatKey_Right(t *testing.T) {
	result := formatKey("right")
	if result != "→" {
		t.Errorf("Expected '→', got %q", result)
	}
}

func TestFormatKey_Enter(t *testing.T) {
	result := formatKey("enter")
	if result != "⏎" {
		t.Errorf("Expected '⏎', got %q", result)
	}
}

func TestFormatKey_CtrlC(t *testing.T) {
	result := formatKey("ctrl+c")
	if result != "^C" {
		t.Errorf("Expected '^C', got %q", result)
	}
}

func TestFormatKey_Regular(t *testing.T) {
	tests := []string{"q", "r", "s", "x", "/", "?", "d", "R"}

	for _, key := range tests {
		result := formatKey(key)
		if result != key {
			t.Errorf("Expected regular key %q to be unchanged, got %q", key, result)
		}
	}
}

func TestKeyMap_FullHelp_Structure(t *testing.T) {
	cfg := config.KeybindingConfig{
		Quit:          []string{"q"},
		Up:            []string{"k"},
		Down:          []string{"j"},
		Start:         []string{"s"},
		Stop:          []string{"x"},
		Restart:       []string{"r"},
		Filter:        []string{"/"},
		FilterSubmit:  []string{"enter"},
		ToggleRunning: []string{"R"},
		ToggleHelp:    []string{"?"},
		ToggleFocus:   []string{"ctrl+w"},
		FocusClient:   []string{"ctrl+left"},
		FocusServer:   []string{"ctrl+right"},
		Docs:          []string{"d"},
	}

	km := NewKeyMap(cfg)
	fullHelp := km.FullHelp()

	// Should return groups of keybindings
	if len(fullHelp) == 0 {
		t.Fatal("Expected at least one group of keybindings")
	}

	// Per the implementation, should have 4 groups:
	// 1. Navigation (Up, Down)
	// 2. Process control (Start, Stop, Restart)
	// 3. Filtering (Filter, FilterSubmit, ToggleRunning)
	// 4. Misc (Docs, ToggleHelp, ToggleFocus, FocusClient, FocusServer, Quit)
	expectedGroups := 4
	if len(fullHelp) != expectedGroups {
		t.Errorf("Expected %d groups, got %d", expectedGroups, len(fullHelp))
	}

	// First group should be navigation (2 bindings)
	if len(fullHelp[0]) != 2 {
		t.Errorf("Expected first group to have 2 bindings (Up, Down), got %d", len(fullHelp[0]))
	}

	// Second group should be process control (3 bindings)
	if len(fullHelp[1]) != 3 {
		t.Errorf("Expected second group to have 3 bindings (Start, Stop, Restart), got %d", len(fullHelp[1]))
	}

	// Third group should be filtering (3 bindings)
	if len(fullHelp[2]) != 3 {
		t.Errorf("Expected third group to have 3 bindings (Filter, FilterSubmit, ToggleRunning), got %d", len(fullHelp[2]))
	}

	// Fourth group should be misc (3 bindings)
	if len(fullHelp[3]) != 6 {
		t.Errorf("Expected fourth group to have 6 bindings (Docs, ToggleHelp, ToggleFocus, FocusClient, FocusServer, Quit), got %d", len(fullHelp[3]))
	}
}

func TestKeyMap_ShortHelp(t *testing.T) {
	cfg := config.KeybindingConfig{
		Quit: []string{"q"},
	}

	km := NewKeyMap(cfg)
	shortHelp := km.ShortHelp()

	// Per implementation, ShortHelp returns empty slice
	if len(shortHelp) != 0 {
		t.Errorf("Expected ShortHelp to return empty slice, got %d items", len(shortHelp))
	}
}

func TestKeyMap_FilterEscape(t *testing.T) {
	cfg := config.KeybindingConfig{}
	km := NewKeyMap(cfg)

	// FilterEscape is hardcoded to "esc", not from config
	// We can't easily test the internal Binding, but verify it exists
	fullHelp := km.FullHelp()
	if fullHelp == nil {
		t.Error("Expected FullHelp to be available")
	}
}

func TestJoinKeys_FormatsSpecialKeys(t *testing.T) {
	// Test that joinKeys properly formats special keys
	tests := []struct {
		input    []string
		expected string
	}{
		{[]string{"up", "down"}, "↑/↓"},
		{[]string{"enter", "ctrl+c"}, "⏎/^C"},
		{[]string{"left", "right"}, "←/→"},
		{[]string{"q", "enter"}, "q/⏎"},
	}

	for _, tt := range tests {
		result := joinKeys(tt.input)
		if result != tt.expected {
			t.Errorf("joinKeys(%v) = %q, expected %q", tt.input, result, tt.expected)
		}
	}
}
