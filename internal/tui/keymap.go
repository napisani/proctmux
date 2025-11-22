package tui

import (
	"github.com/charmbracelet/bubbles/key"
	"github.com/nick/proctmux/internal/config"
)

// KeyMap defines all keybindings for the TUI using bubbles/key
type KeyMap struct {
	Quit          key.Binding
	Up            key.Binding
	Down          key.Binding
	Start         key.Binding
	Stop          key.Binding
	Restart       key.Binding
	Filter        key.Binding
	FilterSubmit  key.Binding
	FilterEscape  key.Binding
	ToggleRunning key.Binding
	ToggleHelp    key.Binding
	Docs          key.Binding
}

// ShortHelp returns keybindings for the short help view
// Not currently used - help is toggled on/off with '?' and always shows full view
func (k KeyMap) ShortHelp() []key.Binding {
	return []key.Binding{}
}

// FullHelp returns all keybindings organized in groups for the full help view
func (k KeyMap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{k.Up, k.Down},                              // Navigation
		{k.Start, k.Stop, k.Restart},                // Process control
		{k.Filter, k.FilterSubmit, k.ToggleRunning}, // Filtering
		{k.Docs, k.ToggleHelp, k.Quit},              // Misc
	}
}

// NewKeyMap creates a KeyMap from the YAML configuration
func NewKeyMap(cfg config.KeybindingConfig) KeyMap {
	return KeyMap{
		Quit: key.NewBinding(
			key.WithKeys(cfg.Quit...),
			key.WithHelp(joinKeys(cfg.Quit), "quit"),
		),
		Up: key.NewBinding(
			key.WithKeys(cfg.Up...),
			key.WithHelp(joinKeys(cfg.Up), "move up"),
		),
		Down: key.NewBinding(
			key.WithKeys(cfg.Down...),
			key.WithHelp(joinKeys(cfg.Down), "move down"),
		),
		Start: key.NewBinding(
			key.WithKeys(cfg.Start...),
			key.WithHelp(joinKeys(cfg.Start), "start process"),
		),
		Stop: key.NewBinding(
			key.WithKeys(cfg.Stop...),
			key.WithHelp(joinKeys(cfg.Stop), "stop process"),
		),
		Restart: key.NewBinding(
			key.WithKeys(cfg.Restart...),
			key.WithHelp(joinKeys(cfg.Restart), "restart process"),
		),
		Filter: key.NewBinding(
			key.WithKeys(cfg.Filter...),
			key.WithHelp(joinKeys(cfg.Filter), "filter processes"),
		),
		FilterSubmit: key.NewBinding(
			key.WithKeys(cfg.FilterSubmit...),
			key.WithHelp(joinKeys(cfg.FilterSubmit), "apply filter"),
		),
		FilterEscape: key.NewBinding(
			key.WithKeys("esc"),
			key.WithHelp("esc", "cancel filter"),
		),
		ToggleRunning: key.NewBinding(
			key.WithKeys(cfg.ToggleRunning...),
			key.WithHelp(joinKeys(cfg.ToggleRunning), "toggle running only"),
		),
		ToggleHelp: key.NewBinding(
			key.WithKeys(cfg.ToggleHelp...),
			key.WithHelp(joinKeys(cfg.ToggleHelp), "toggle help"),
		),
		Docs: key.NewBinding(
			key.WithKeys(cfg.Docs...),
			key.WithHelp(joinKeys(cfg.Docs), "show docs"),
		),
	}
}

// joinKeys takes a slice of key strings and formats them for help display
// e.g., ["k", "up"] -> "↑/k"
func joinKeys(keys []string) string {
	if len(keys) == 0 {
		return ""
	}
	if len(keys) == 1 {
		return formatKey(keys[0])
	}
	// Show first two keys in help
	return formatKey(keys[0]) + "/" + formatKey(keys[1])
}

// formatKey formats special keys for better display
func formatKey(k string) string {
	switch k {
	case "up":
		return "↑"
	case "down":
		return "↓"
	case "left":
		return "←"
	case "right":
		return "→"
	case "enter":
		return "⏎"
	case "ctrl+c":
		return "^C"
	default:
		return k
	}
}
