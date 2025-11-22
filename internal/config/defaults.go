package config

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
	if len(cfg.Keybinding.Restart) == 0 {
		cfg.Keybinding.Restart = []string{"r"}
	}
	if len(cfg.Keybinding.Filter) == 0 {
		cfg.Keybinding.Filter = []string{"/"}
	}
	if len(cfg.Keybinding.FilterSubmit) == 0 {
		cfg.Keybinding.FilterSubmit = []string{"enter"}
	}
	if len(cfg.Keybinding.ToggleRunning) == 0 {
		cfg.Keybinding.ToggleRunning = []string{"R"}
	}
	if len(cfg.Keybinding.ToggleHelp) == 0 {
		cfg.Keybinding.ToggleHelp = []string{"?"}
	}
	if len(cfg.Keybinding.Docs) == 0 {
		cfg.Keybinding.Docs = []string{"d"}
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

	if cfg.Style.SelectedProcessColor == "" {
		cfg.Style.SelectedProcessColor = "white"
	}
	if cfg.Style.SelectedProcessBgColor == "" {
		cfg.Style.SelectedProcessBgColor = "magenta"
	}
	if cfg.Style.StatusRunningColor == "" {
		cfg.Style.StatusRunningColor = "green"
	}
	if cfg.Style.StatusHaltingColor == "" {
		cfg.Style.StatusHaltingColor = "yellow"
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

	return cfg
}
