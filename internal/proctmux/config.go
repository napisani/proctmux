package proctmux

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type KeybindingConfig struct {
	Quit         []string `yaml:"quit"`
	Up           []string `yaml:"up"`
	Down         []string `yaml:"down"`
	Start        []string `yaml:"start"`
	Stop         []string `yaml:"stop"`
	Filter       []string `yaml:"filter"`
	FilterSubmit []string `yaml:"submit_filter"`
	Docs         []string `yaml:"docs"`

	// TODO not used in the tmux implementation
	Zoom        []string `yaml:"zoom"`
	SwitchFocus []string `yaml:"switch_focus"`
	Focus       []string `yaml:"focus"`
}

type LayoutConfig struct {
	CategorySearchPrefix string `yaml:"category_search_prefix"`
	HideHelp             bool   `yaml:"hide_help"`
	ProcessesListWidth   int    `yaml:"processes_list_width"`

	// TODO implement this
	HideProcessDescriptionPanel bool `yaml:"hide_process_description_panel"`

	SortProcessListAlpha        bool   `yaml:"sort_process_list_alpha"`
	SortProcessListRunningFirst bool   `yaml:"sort_process_list_running_first"`
	PlaceholderBanner           string `yaml:"placeholder_banner"`
	EnableDebugProcessInfo      bool   `yaml:"enable_debug_process_info"`
}

type StyleConfig struct {
	SelectedProcessColor       string            `yaml:"selected_process_color"`
	SelectedProcessBgColor     string            `yaml:"selected_process_bg_color"`
	UnselectedProcessColor     string            `yaml:"unselected_process_color"`
	StatusRunningColor         string            `yaml:"status_running_color"`
	StatusStoppedColor         string            `yaml:"status_stopped_color"`
	PlaceholderTerminalBgColor string            `yaml:"placeholder_terminal_bg_color"`
	PointerChar                string            `yaml:"pointer_char"`
	StyleClasses               map[string]string `yaml:"style_classes"`
	ColorLevel                 string            `yaml:"color_level"`
}

type SignalServerConfig struct {
	Port   int    `yaml:"port"`
	Host   string `yaml:"host"`
	Enable bool   `yaml:"enable"`
}

type ProcTmuxConfig struct {
	Keybinding KeybindingConfig         `yaml:"keybinding"`
	Layout     LayoutConfig             `yaml:"layout"`
	Style      StyleConfig              `yaml:"style"`
	Procs      map[string]ProcessConfig `yaml:"procs"`
	General    struct {
		DetachedSessionName string `yaml:"detached_session_name"`
		KillExistingSession bool   `yaml:"kill_existing_session"`
	} `yaml:"general"`
	SignalServer SignalServerConfig `yaml:"signal_server"`
	ShellCmd     []string           `yaml:"shell_cmd"`
	LogFile      string             `yaml:"log_file"`
	EnableMouse  bool               `yaml:"enable_mouse"`
}

type ProcessConfig struct {
	Shell       string            `yaml:"shell"`
	Cmd         []string          `yaml:"cmd"`
	Cwd         string            `yaml:"cwd"`
	Env         map[string]string `yaml:"env"`
	Stop        int               `yaml:"stop"`
	Autostart   bool              `yaml:"autostart"`
	Autofocus   bool              `yaml:"autofocus"`
	Description string            `yaml:"description"`
	Docs        string            `yaml:"docs"`
	MetaTags    []string          `yaml:"meta_tags"`
	Categories  []string          `yaml:"categories"`
	AddPath     []string          `yaml:"add_path"`
}

// Ensure all config structs are properly tagged for YAML unmarshalling
func LoadConfig(path string) (*ProcTmuxConfig, error) {
	if path == "" {
		// Try to load from default file paths in order
		defaultPaths := []string{"proctmux.yaml", "proctmux.yml", "procmux.yaml", "procmux.yml"}
		for _, defaultPath := range defaultPaths {
			if _, err := os.Stat(defaultPath); err == nil {
				path = defaultPath
				break
			}
		}

		// If path is still empty, all defaults failed
		if path == "" {
			return nil, fmt.Errorf("config file not found in default locations")
		}
	}

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

const banner = `
███    ██  ██████      ██████  ██████   ██████   ██████ ███████ ███████ ███████ 
████   ██ ██    ██     ██   ██ ██   ██ ██    ██ ██      ██      ██      ██      
██ ██  ██ ██    ██     ██████  ██████  ██    ██ ██      █████   ███████ ███████ 
██  ██ ██ ██    ██     ██      ██   ██ ██    ██ ██      ██           ██      ██ 
██   ████  ██████      ██      ██   ██  ██████   ██████ ███████ ███████ ███████`

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
	if len(cfg.Keybinding.Docs) == 0 {
		cfg.Keybinding.Docs = []string{"?"}
	}

	if cfg.Layout.CategorySearchPrefix == "" {
		cfg.Layout.CategorySearchPrefix = "cat:"
	}
	if cfg.Layout.PlaceholderBanner == "" {
		cfg.Layout.PlaceholderBanner = banner
	}

	if cfg.Layout.ProcessesListWidth <= 0 || cfg.Layout.ProcessesListWidth > 100 {
		cfg.Layout.ProcessesListWidth = 30
	}

	if cfg.Style.PointerChar == "" {
		cfg.Style.PointerChar = "▶"
	}
	if cfg.General.DetachedSessionName == "" {
		cfg.General.DetachedSessionName = "_proctmux"
	}
	if cfg.SignalServer.Enable {
		if cfg.SignalServer.Port == 0 {
			cfg.SignalServer.Port = 9792
		}
		if cfg.SignalServer.Host == "" {
			cfg.SignalServer.Host = "localhost"
		}

		if cfg.Style.SelectedProcessColor == "" {
			cfg.Style.SelectedProcessColor = "white"
		}
		if cfg.Style.SelectedProcessBgColor == "" {
			cfg.Style.SelectedProcessBgColor = "magenta"
		}
		if cfg.Style.StatusRunningColor == "" {
			cfg.Style.StatusRunningColor = "green"
		}
		if cfg.Style.StatusStoppedColor == "" {
			cfg.Style.StatusStoppedColor = "red"
		}
		if cfg.Style.PlaceholderTerminalBgColor == "" {
			cfg.Style.PlaceholderTerminalBgColor = "black"
		}
		if cfg.Style.ColorLevel == "" {
			cfg.Style.ColorLevel = "256"
		}

	}

	return cfg
}
