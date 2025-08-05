package main

import (
	"os"

	"gopkg.in/yaml.v3"
)

type KeybindingConfig struct {
	Quit         []string
	Up           []string
	Down         []string
	Start        []string
	Stop         []string
	Filter       []string
	FilterSubmit []string
	SwitchFocus  []string
	Zoom         []string
	Focus        []string
}

type LayoutConfig struct {
	CategorySearchPrefix string
}

type ProcTmuxConfig struct {
	Keybinding KeybindingConfig
	Layout     LayoutConfig
	Style      struct {
		PointerChar string
	}
	Procs   map[string]ProcessConfig
	General struct {
		DetachedSessionName string
		KillExistingSession bool
	}
}

type ProcessConfig struct {
	Shell      string
	Cmd        []string
	Cwd        string
	Env        map[string]*string
	Autostart  bool
	Categories []string
}

func LoadConfig(path string) (*ProcTmuxConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var cfg ProcTmuxConfig
	if err := yaml.NewDecoder(f).Decode(&cfg); err != nil {
		return nil, err
	}

	cfg = applyDefaults(cfg)
	return &cfg, nil
}

func applyDefaults(cfg ProcTmuxConfig) ProcTmuxConfig {
	if len(cfg.Keybinding.Quit) == 0 {
		cfg.Keybinding.Quit = []string{"q", "ctrl+c"}
	}
	if len(cfg.Keybinding.Up) == 0 {
		cfg.Keybinding.Up = []string{"k", "up"}
	}
	if len(cfg.Keybinding.Down) == 0 {
		cfg.Keybinding.Down = []string{"j", "down"}
	}
	if len(cfg.Keybinding.Start) == 0 {
		cfg.Keybinding.Start = []string{"s", "enter"}
	}
	if len(cfg.Keybinding.Stop) == 0 {
		cfg.Keybinding.Stop = []string{"x"}
	}
	if len(cfg.Keybinding.Filter) == 0 {
		cfg.Keybinding.Filter = []string{"/"}
	}
	if len(cfg.Keybinding.FilterSubmit) == 0 {
		cfg.Keybinding.FilterSubmit = []string{"enter"}
	}
	if len(cfg.Keybinding.SwitchFocus) == 0 {
		cfg.Keybinding.SwitchFocus = []string{"tab"}
	}
	if len(cfg.Keybinding.Zoom) == 0 {
		cfg.Keybinding.Zoom = []string{"z"}
	}

	if cfg.Layout.CategorySearchPrefix == "" {
		cfg.Layout.CategorySearchPrefix = ":"
	}
	if cfg.Style.PointerChar == "" {
		cfg.Style.PointerChar = ">"
	}
	if cfg.General.DetachedSessionName == "" {
		cfg.General.DetachedSessionName = "_proctmux"
	}

	return cfg
}
