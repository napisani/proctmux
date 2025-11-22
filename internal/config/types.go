package config

type KeybindingConfig struct {
	Quit          []string `yaml:"quit"`
	Up            []string `yaml:"up"`
	Down          []string `yaml:"down"`
	Start         []string `yaml:"start"`
	Stop          []string `yaml:"stop"`
	Restart       []string `yaml:"restart"`
	Filter        []string `yaml:"filter"`
	FilterSubmit  []string `yaml:"submit_filter"`
	ToggleRunning []string `yaml:"toggle_running"`
	ToggleHelp    []string `yaml:"toggle_help"`
	Docs          []string `yaml:"docs"`

	// TODO not used in the tmux implementation
	Zoom        []string `yaml:"zoom"`
	SwitchFocus []string `yaml:"switch_focus"`
	Focus       []string `yaml:"focus"`
}

type LayoutConfig struct {
	CategorySearchPrefix string `yaml:"category_search_prefix"`
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
	StatusHaltingColor         string            `yaml:"status_halting_color"`
	StatusStoppedColor         string            `yaml:"status_stopped_color"`
	PlaceholderTerminalBgColor string            `yaml:"placeholder_terminal_bg_color"`
	PointerChar                string            `yaml:"pointer_char"`
	StyleClasses               map[string]string `yaml:"style_classes"`
	ColorLevel                 string            `yaml:"color_level"`
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
	ShellCmd           []string `yaml:"shell_cmd"`
	LogFile            string   `yaml:"log_file"`
	StdOutDebugLogFile string   `yaml:"stdout_debug_log_file"`
	EnableMouse        bool     `yaml:"enable_mouse"`
}

type ProcessConfig struct {
	Shell        string            `yaml:"shell"`
	Cmd          []string          `yaml:"cmd"`
	Cwd          string            `yaml:"cwd"`
	Env          map[string]string `yaml:"env"`
	Stop         int               `yaml:"stop"`
	Autostart    bool              `yaml:"autostart"`
	Autofocus    bool              `yaml:"autofocus"`
	Description  string            `yaml:"description"`
	Docs         string            `yaml:"docs"`
	MetaTags     []string          `yaml:"meta_tags"`
	Categories   []string          `yaml:"categories"`
	AddPath      []string          `yaml:"add_path"`
	TerminalRows int               `yaml:"terminal_rows"`
	TerminalCols int               `yaml:"terminal_cols"`
	OnKill       []string          `yaml:"on_kill"`
}
