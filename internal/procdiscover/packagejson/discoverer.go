package packagejson

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/procdiscover"
)

const name = "packagejson"

type discoverer struct{}

func init() {
	procdiscover.Register(&discoverer{}, func(cfg *config.ProcTmuxConfig) bool {
		return cfg.General.ProcsFromPackageJSON
	})
}

func (d *discoverer) Name() string {
	return name
}

func (d *discoverer) Discover(cwd string) (map[string]config.ProcessConfig, error) {
	packageJSONPath := filepath.Join(cwd, "package.json")
	data, err := os.ReadFile(packageJSONPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: package.json not found at %s", procdiscover.ErrSourceNotFound, packageJSONPath)
		}
		return nil, fmt.Errorf("reading package.json %s: %w", packageJSONPath, err)
	}

	var pkg struct {
		Scripts map[string]string `json:"scripts"`
	}
	if err := json.Unmarshal(data, &pkg); err != nil {
		return nil, fmt.Errorf("parsing package.json %s: %w", packageJSONPath, err)
	}

	if len(pkg.Scripts) == 0 {
		return map[string]config.ProcessConfig{}, nil
	}

	manager := detectManager(cwd)

	procs := make(map[string]config.ProcessConfig, len(pkg.Scripts))
	for script, command := range pkg.Scripts {
		procName := fmt.Sprintf("%s:%s", manager.prefix, script)
		if _, exists := procs[procName]; exists {
			continue
		}

		shell := manager.BuildCommand(script, command)
		procs[procName] = config.ProcessConfig{
			Shell:       shell,
			Cwd:         cwd,
			Description: manager.Description(script, command),
			Categories:  []string{manager.category},
		}
	}

	return procs, nil
}

type managerInfo struct {
	prefix   string
	category string
}

func (m managerInfo) BuildCommand(script, scriptBody string) string {
	switch m.prefix {
	case "pnpm":
		return fmt.Sprintf("pnpm run %s", script)
	case "yarn":
		return fmt.Sprintf("yarn %s", script)
	case "bun":
		return fmt.Sprintf("bun run %s", script)
	case "deno":
		return fmt.Sprintf("deno task %s", script)
	default:
		return fmt.Sprintf("npm run %s", script)
	}
}

func (m managerInfo) Description(script, scriptBody string) string {
	if strings.TrimSpace(scriptBody) == "" {
		return fmt.Sprintf("Auto-discovered %s script", m.prefix)
	}
	return fmt.Sprintf("Auto-discovered %s script: %s", m.prefix, scriptBody)
}

func detectManager(cwd string) managerInfo {
	checks := []struct {
		files    []string
		prefix   string
		category string
	}{
		{[]string{"pnpm-lock.yaml", ".pnpmfile.cjs", "pnpm-workspace.yaml"}, "pnpm", "pnpm"},
		{[]string{"bun.lockb", "bunfig.toml"}, "bun", "bun"},
		{[]string{"yarn.lock", ".yarnrc", ".yarnrc.yml", ".yarnrc.yaml"}, "yarn", "yarn"},
		{[]string{"package-lock.json", "npm-shrinkwrap.json"}, "npm", "npm"},
		{[]string{"deno.json", "deno.jsonc"}, "deno", "deno"},
	}

	for _, check := range checks {
		for _, file := range check.files {
			if _, err := os.Stat(filepath.Join(cwd, file)); err == nil {
				return managerInfo{prefix: check.prefix, category: check.category}
			}
		}
	}

	return managerInfo{prefix: "npm", category: "npm"}
}
