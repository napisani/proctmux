package process

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

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

	// Handle AddPath - need to remove existing PATH and add modified one
	if len(cfg.AddPath) > 0 {
		currentPath := os.Getenv("PATH")
		for _, p := range cfg.AddPath {
			currentPath = fmt.Sprintf("%s:%s", currentPath, p)
		}

		// Filter out existing PATH entry
		filteredEnv := make([]string, 0, len(env))
		for _, e := range env {
			if !strings.HasPrefix(e, "PATH=") {
				filteredEnv = append(filteredEnv, e)
			}
		}
		env = filteredEnv
		env = append(env, fmt.Sprintf("PATH=%s", currentPath))
	}

	// Add/override custom environment variables
	if cfg.Env != nil {
		for k, v := range cfg.Env {
			env = append(env, fmt.Sprintf("%s=%s", k, v))
		}
	}

	return env
}
