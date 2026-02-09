package procdiscover

import (
	"errors"
	"fmt"
	"log"
	"sync"

	"github.com/nick/proctmux/internal/config"
)

// ErrSourceNotFound is returned when a discoverer cannot find its source input.
var ErrSourceNotFound = errors.New("procdiscover: source not found")

// ProcDiscoverer defines the behavior of automatic process discovery integrations.
// Implementations should be stateless and safe for concurrent use.
type ProcDiscoverer interface {
	// Name returns a human-readable identifier for this discoverer. It must be unique.
	Name() string

	// Discover returns a map of process configurations keyed by their desired name.
	// Implementations should return ErrSourceNotFound (wrapped) when the source file
	// or context required for discovery is not present so callers can ignore it.
	Discover(cwd string) (map[string]config.ProcessConfig, error)
}

type registration struct {
	discoverer ProcDiscoverer
	enabled    func(*config.ProcTmuxConfig) bool
}

var (
	registryMu sync.RWMutex
	registry   = make(map[string]registration)
)

// Register adds a ProcDiscoverer to the global registry.
// The enabled function determines whether the discoverer should run for a given config.
func Register(d ProcDiscoverer, enabled func(*config.ProcTmuxConfig) bool) {
	if d == nil {
		panic("procdiscover: attempted to register nil discoverer")
	}
	name := d.Name()
	if name == "" {
		panic("procdiscover: discoverer name must not be empty")
	}

	registryMu.Lock()
	defer registryMu.Unlock()

	if _, exists := registry[name]; exists {
		panic(fmt.Sprintf("procdiscover: discoverer %q already registered", name))
	}

	registry[name] = registration{
		discoverer: d,
		enabled:    enabled,
	}
}

// Apply executes all discoverers that are enabled for the provided configuration.
// Explicitly defined processes in cfg.Procs always take precedence over discovered ones.
func Apply(cfg *config.ProcTmuxConfig, cwd string) {
	if cfg == nil {
		return
	}

	registryMu.RLock()
	regs := make([]registration, 0, len(registry))
	for _, reg := range registry {
		regs = append(regs, reg)
	}
	registryMu.RUnlock()

	if len(regs) == 0 {
		return
	}

	if cfg.Procs == nil {
		cfg.Procs = make(map[string]config.ProcessConfig)
	}

	for _, reg := range regs {
		if reg.enabled != nil && !reg.enabled(cfg) {
			continue
		}

		procs, err := reg.discoverer.Discover(cwd)
		if err != nil {
			if errors.Is(err, ErrSourceNotFound) {
				log.Printf("Proc discovery %s skipped: %v", reg.discoverer.Name(), err)
				continue
			}
			log.Printf("Proc discovery %s failed: %v", reg.discoverer.Name(), err)
			continue
		}

		for name, proc := range procs {
			if _, exists := cfg.Procs[name]; exists {
				log.Printf("Proc discovery %s skipping existing process %s", reg.discoverer.Name(), name)
				continue
			}
			cfg.Procs[name] = proc
			log.Printf("Proc discovery %s added process %s", reg.discoverer.Name(), name)
		}
	}
}
