package redact

import (
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

// StateForIPC produces a redacted copy of the application state and associated process views
// suitable for sharing with remote clients. Environment variables and other sensitive config
// fields are stripped before the data leaves the primary process.
func StateForIPC(state *domain.AppState, pc domain.ProcessController) (*domain.AppState, []domain.ProcessView) {
	if state == nil {
		return nil, nil
	}

	redacted := *state
	redacted.Config = redactGlobalConfig(state.Config)
	redacted.Processes = make([]domain.Process, len(state.Processes))
	for i, proc := range state.Processes {
		copyProc := proc
		copyProc.Config = redactProcessConfigPointer(proc.Config)
		redacted.Processes[i] = copyProc
	}

	processViews := make([]domain.ProcessView, len(state.Processes))
	for i := range state.Processes {
		view := state.Processes[i].ToView(pc)
		view.Config = redactProcessConfigPointer(view.Config)
		processViews[i] = view
	}

	return &redacted, processViews
}

func redactGlobalConfig(cfg *config.ProcTmuxConfig) *config.ProcTmuxConfig {
	if cfg == nil {
		return nil
	}

	copyCfg := *cfg
	if cfg.Procs != nil {
		copyCfg.Procs = make(map[string]config.ProcessConfig, len(cfg.Procs))
		for label, proc := range cfg.Procs {
			copyCfg.Procs[label] = redactProcessConfigValue(proc)
		}
	}
	if len(cfg.ShellCmd) > 0 {
		copyCfg.ShellCmd = cloneStringSlice(cfg.ShellCmd)
	}
	return &copyCfg
}

func redactProcessConfigPointer(cfg *config.ProcessConfig) *config.ProcessConfig {
	if cfg == nil {
		return nil
	}
	copyCfg := redactProcessConfigValue(*cfg)
	return &copyCfg
}

func redactProcessConfigValue(cfg config.ProcessConfig) config.ProcessConfig {
	cfg.Cmd = cloneStringSlice(cfg.Cmd)
	cfg.Env = nil
	cfg.MetaTags = cloneStringSlice(cfg.MetaTags)
	cfg.Categories = cloneStringSlice(cfg.Categories)
	cfg.AddPath = cloneStringSlice(cfg.AddPath)
	cfg.OnKill = cloneStringSlice(cfg.OnKill)
	return cfg
}

func cloneStringSlice(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	result := make([]string, len(values))
	copy(result, values)
	return result
}
