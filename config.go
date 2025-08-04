package main

import (
	"gopkg.in/yaml.v3"
	"os"
	"path/filepath"
)

// ProcTmuxConfig is the top-level configuration structure
// It mirrors the Rust configuration defined in old-rust-src/config.rs
// and holds fields for general configuration, processes, keybindings, log file, layout, and style.

type ProcTmuxConfig struct {
	General    GeneralConfig            `yaml:"general"`
	Procs      map[string]ProcessConfig `yaml:"procs"`
	Keybinding KeybindingConfig         `yaml:"keybinding"`
	LogFile    string                   `yaml:"log_file"`
	Layout     LayoutConfig             `yaml:"layout"`
	Style      StyleConfig              `yaml:"style"`
}

// GeneralConfig holds general configuration options.
// Defaults in Rust: detached_session_name defaults to "proctmux", kill_existing_session defaults to false.

type GeneralConfig struct {
	DetachedSessionName string `yaml:"detached_session_name"`
	KillExistingSession bool   `yaml:"kill_existing_session"`
}

// ProcessConfig holds configuration for each individual process.
// Defaults in Rust: autostart false, autofocus false, cwd defaults to current working directory, stop defaults to SIGKILL (9)

type ProcessConfig struct {
	Autostart   bool               `yaml:"autostart"`
	Autofocus   bool               `yaml:"autofocus"`
	Shell       string             `yaml:"shell"`
	Cmd         []string           `yaml:"cmd"`
	Cwd         string             `yaml:"cwd"`
	Stop        int                `yaml:"stop"`
	Env         map[string]*string `yaml:"env"`
	AddPath     []string           `yaml:"add_path"`
	Description string             `yaml:"description"`
	Docs        string             `yaml:"docs"`
	Categories  []string           `yaml:"categories"`
	MetaTags    []string           `yaml:"meta_tags"`
}

// KeybindingConfig holds keybinding configurations.
// The keys are represented as string slices. The conversion to proper key codes can be done later if needed.

type KeybindingConfig struct {
	Quit         []string `yaml:"quit"`
	Start        []string `yaml:"start"`
	Stop         []string `yaml:"stop"`
	Up           []string `yaml:"up"`
	Down         []string `yaml:"down"`
	Filter       []string `yaml:"filter"`
	FilterSubmit []string `yaml:"filter_submit"`
	SwitchFocus  []string `yaml:"switch_focus"`
}

// LayoutConfig holds layout-related configurations.
// Defaults from Rust: process_list_width defaults to 31, sort_process_list_alpha defaults to true,
// category_search_prefix defaults to "cat:"; hide_help and hide_process_description_panel default false.

type LayoutConfig struct {
	HideHelp                    bool   `yaml:"hide_help"`
	HideProcessDescriptionPanel bool   `yaml:"hide_process_description_panel"`
	ProcessListWidth            int    `yaml:"process_list_width"`
	SortProcessListAlpha        bool   `yaml:"sort_process_list_alpha"`
	CategorySearchPrefix        string `yaml:"category_search_prefix"`
}

// StyleConfig holds style-related configurations.
// Defaults from Rust: selected_process_color defaults to "ansiblack", selected_process_bg_color defaults to "ansimagenta",
// unselected_process_color defaults to "ansiblue", status_running_color defaults to "ansigreen",
// status_stopped_color defaults to "ansired", status_halting_color defaults to "ansiyellow",
// pointer_char defaults to "▶".

type StyleConfig struct {
	SelectedProcessColor   string `yaml:"selected_process_color"`
	SelectedProcessBgColor string `yaml:"selected_process_bg_color"`
	UnselectedProcessColor string `yaml:"unselected_process_color"`
	StatusRunningColor     string `yaml:"status_running_color"`
	StatusStoppedColor     string `yaml:"status_stopped_color"`
	StatusHaltingColor     string `yaml:"status_halting_color"`
	PointerChar            string `yaml:"pointer_char"`
}

// SetDefaults sets default values for any missing fields, mimicking the Rust configuration defaults.
func (c *ProcTmuxConfig) SetDefaults() error {
	// General defaults
	if c.General.DetachedSessionName == "" {
		c.General.DetachedSessionName = "proctmux"
	}
	// KillExistingSession defaults to false (zero value) so nothing to do.

	// Get current working directory
	wd, err := os.Getwd()
	if err != nil {
		return err
	}

	// ProcessConfig defaults
	for name, proc := range c.Procs {
		if proc.Cwd == "" {
			proc.Cwd = wd
		}
		// Set kill signal default if not provided; using 9 (SIGKILL) as default
		if proc.Stop == 0 {
			proc.Stop = 9
		}
		c.Procs[name] = proc
	}

	// Keybinding defaults
	if len(c.Keybinding.Quit) == 0 {
		c.Keybinding.Quit = []string{"q"}
	}
	if len(c.Keybinding.Start) == 0 {
		c.Keybinding.Start = []string{"s"}
	}
	if len(c.Keybinding.Stop) == 0 {
		c.Keybinding.Stop = []string{"x"}
	}
	if len(c.Keybinding.Up) == 0 {
		c.Keybinding.Up = []string{"k", "Up"}
	}
	if len(c.Keybinding.Down) == 0 {
		c.Keybinding.Down = []string{"j", "Down"}
	}
	if len(c.Keybinding.Filter) == 0 {
		c.Keybinding.Filter = []string{"/"}
	}
	if len(c.Keybinding.FilterSubmit) == 0 {
		c.Keybinding.FilterSubmit = []string{"Enter"}
	}
	if len(c.Keybinding.SwitchFocus) == 0 {
		c.Keybinding.SwitchFocus = []string{"Ctrl+w"}
	}

	// Layout defaults
	if c.Layout.ProcessListWidth == 0 {
		c.Layout.ProcessListWidth = 31
	}
	// HideHelp and HideProcessDescriptionPanel default to false by zero value
	if c.Layout.CategorySearchPrefix == "" {
		c.Layout.CategorySearchPrefix = "cat:"
	}
	// SortProcessListAlpha default true; if false and not explicitly set, force it true
	if !c.Layout.SortProcessListAlpha {
		c.Layout.SortProcessListAlpha = true
	}

	// Style defaults
	if c.Style.SelectedProcessColor == "" {
		c.Style.SelectedProcessColor = "ansiblack"
	}
	if c.Style.SelectedProcessBgColor == "" {
		c.Style.SelectedProcessBgColor = "ansimagenta"
	}
	if c.Style.UnselectedProcessColor == "" {
		c.Style.UnselectedProcessColor = "ansiblue"
	}
	if c.Style.StatusRunningColor == "" {
		c.Style.StatusRunningColor = "ansigreen"
	}
	if c.Style.StatusStoppedColor == "" {
		c.Style.StatusStoppedColor = "ansired"
	}
	if c.Style.StatusHaltingColor == "" {
		c.Style.StatusHaltingColor = "ansiyellow"
	}
	if c.Style.PointerChar == "" {
		c.Style.PointerChar = "▶"
	}

	// LogFile: if empty, default to a file in the working directory
	if c.LogFile == "" {
		c.LogFile = filepath.Join(wd, "proctmux.log")
	}

	return nil
}

// LoadConfig loads the YAML configuration at the given path into a ProcTmuxConfig.
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

	// Set defaults for missing fields to mimic Rust behavior
	if err := cfg.SetDefaults(); err != nil {
		return nil, err
	}

	return &cfg, nil
}
