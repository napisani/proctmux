package makefile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/procdiscover"
)

const name = "makefile"

type discoverer struct{}

func init() {
	procdiscover.Register(&discoverer{}, func(cfg *config.ProcTmuxConfig) bool {
		return cfg.General.ProcsFromMakeTargets
	})
}

func (d *discoverer) Name() string {
	return name
}

func (d *discoverer) Discover(cwd string) (map[string]config.ProcessConfig, error) {
	makefilePath := filepath.Join(cwd, "Makefile")
	data, err := os.ReadFile(makefilePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: Makefile not found at %s", procdiscover.ErrSourceNotFound, makefilePath)
		}
		return nil, fmt.Errorf("reading Makefile %s: %w", makefilePath, err)
	}

	targetPattern := regexp.MustCompile(`(?m)^([A-Za-z0-9_.-]+):`) // simplified target detection
	matches := targetPattern.FindAllSubmatch(data, -1)
	if len(matches) == 0 {
		return map[string]config.ProcessConfig{}, nil
	}

	procs := make(map[string]config.ProcessConfig, len(matches))
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}
		target := string(m[1])
		procName := "make:" + target
		if _, exists := procs[procName]; exists {
			continue
		}

		procs[procName] = config.ProcessConfig{
			Shell:       "make " + target,
			Cwd:         cwd,
			Description: "Auto-discovered Makefile target",
			Categories:  []string{"makefile"},
		}
	}

	return procs, nil
}
