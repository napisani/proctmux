package domain

import (
	"sort"
	"strings"

	"github.com/nick/proctmux/internal/config"
	"github.com/sahilm/fuzzy"
)

// processViewSource implements fuzzy.Source for ProcessView slices
type processViewSource struct {
	processes []ProcessView
}

func (p processViewSource) String(i int) string {
	return p.processes[i].Label
}

func (p processViewSource) Len() int {
	return len(p.processes)
}

func fuzzyMatch(a, b string) bool {
	a = strings.ToLower(a)
	b = strings.ToLower(b)
	return strings.Contains(a, b) || strings.Contains(b, a)
}

// FilterProcesses is a pure helper to compute a filtered/sorted view from ProcessViews and UI filter text.
// If showOnlyRunning is true, only running processes are included.
func FilterProcesses(cfg *config.ProcTmuxConfig, processes []ProcessView, filterText string, showOnlyRunning bool) []*ProcessView {
	var out []*ProcessView
	prefix := cfg.Layout.CategorySearchPrefix
	ft := strings.TrimSpace(filterText)

	if ft == "" {
		// No filter - return all non-dummy processes (optionally filtered by running status)
		for i := range processes {
			if processes[i].ID != DummyProcessID {
				if showOnlyRunning && processes[i].Status != StatusRunning {
					continue
				}
				out = append(out, &processes[i])
			}
		}
	} else if after, ok := strings.CutPrefix(ft, prefix); ok {
		// Category-based search
		cats := strings.Split(after, ",")
		for i := range processes {
			if processes[i].ID == DummyProcessID {
				continue
			}
			if showOnlyRunning && processes[i].Status != StatusRunning {
				continue
			}
			match := true
			for _, cat := range cats {
				cat = strings.TrimSpace(cat)
				found := false
				for _, c := range processes[i].Config.Categories {
					if fuzzyMatch(c, cat) {
						found = true
						break
					}
				}
				if !found {
					match = false
					break
				}
			}
			if match {
				out = append(out, &processes[i])
			}
		}
	} else {
		// Fuzzy search by label
		// Filter out dummy processes first
		var validProcesses []ProcessView
		for i := range processes {
			if processes[i].ID != DummyProcessID {
				if showOnlyRunning && processes[i].Status != StatusRunning {
					continue
				}
				validProcesses = append(validProcesses, processes[i])
			}
		}

		// Use fuzzy library for matching
		source := processViewSource{processes: validProcesses}
		matches := fuzzy.FindFrom(ft, source)

		// Convert fuzzy matches to output, preserving fuzzy ranking
		for _, match := range matches {
			out = append(out, &validProcesses[match.Index])
		}

		// Return early - fuzzy already sorts by match quality
		return out
	}

	// Sort results if no fuzzy search was used
	if cfg.Layout.SortProcessListRunningFirst {
		sort.SliceStable(out, func(i, j int) bool {
			ai := out[i].Status == StatusRunning
			aj := out[j].Status == StatusRunning
			if ai != aj {
				return ai
			}
			if cfg.Layout.SortProcessListAlpha {
				return out[i].Label < out[j].Label
			}
			return false
		})
	} else if cfg.Layout.SortProcessListAlpha {
		sort.SliceStable(out, func(i, j int) bool { return out[i].Label < out[j].Label })
	}
	return out
}
