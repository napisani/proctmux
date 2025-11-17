package process

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/nick/proctmux/internal/config"
)

// buildCommand creates an exec.Cmd from a ProcessConfig
// It supports either shell commands (using sh -c) or direct command execution
func buildCommand(cfg *config.ProcessConfig) *exec.Cmd {
	if cfg.Shell != "" {
		return exec.Command("sh", "-c", cfg.Shell)
	}

	if len(cfg.Cmd) > 0 {
		return exec.Command(cfg.Cmd[0], cfg.Cmd[1:]...)
	}

	return nil
}

// buildEnvironment creates an environment variable slice from a ProcessConfig
// It starts with the current process environment and adds/overrides with config values
func buildEnvironment(cfg *config.ProcessConfig) []string {
	env := os.Environ()

	if cfg.Env != nil {
		for k, v := range cfg.Env {
			env = append(env, fmt.Sprintf("%s=%s", k, v))
		}
	}

	if len(cfg.AddPath) > 0 {
		currentPath := os.Getenv("PATH")
		for _, p := range cfg.AddPath {
			currentPath = fmt.Sprintf("%s:%s", currentPath, p)
		}
		env = append(env, fmt.Sprintf("PATH=%s", currentPath))
	}

	return env
}
