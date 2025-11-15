package domain

import (
	"sort"
	"strings"

	"github.com/nick/proctmux/internal/config"
)

func fuzzyMatch(a, b string) bool {
	a = strings.ToLower(a)
	b = strings.ToLower(b)
	return strings.Contains(a, b) || strings.Contains(b, a)
}

// FilterProcesses is a pure helper to compute a filtered/sorted view from domain state and UI filter text.
func FilterProcesses(cfg *config.ProcTmuxConfig, processes []Process, filterText string) []*Process {
	var out []*Process
	prefix := cfg.Layout.CategorySearchPrefix
	ft := strings.TrimSpace(filterText)
	if ft == "" {
		for i := range processes {
			if processes[i].ID != DummyProcessID {
				out = append(out, &processes[i])
			}
		}
	} else if strings.HasPrefix(ft, prefix) {
		cats := strings.Split(strings.TrimPrefix(ft, prefix), ",")
		for i := range processes {
			if processes[i].ID == DummyProcessID {
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
		for i := range processes {
			if processes[i].ID == DummyProcessID {
				continue
			}
			if fuzzyMatch(processes[i].Label, ft) {
				out = append(out, &processes[i])
			}
		}
	}
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
