package proctmux

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

type TmuxContext struct {
	PaneID            string
	SessionID         string
	DetachedSessionID string
	SplitSize         string
}

func NewTmuxContext(detachedSession string, killExistingSession bool, processListWidthPercent int) (*TmuxContext, error) {
	paneID, err := CurrentPane()
	if err != nil {
		return nil, fmt.Errorf("could not retrieve tmux pane id: %w", err)
	}
	sessionID, err := CurrentSession()
	if err != nil {
		return nil, fmt.Errorf("could not retrieve tmux session id: %w", err)
	}
	sessions, err := ListSessions()
	if err != nil {
		return nil, fmt.Errorf("could not list tmux sessions: %w", err)
	}
	detachedSessionID := ""

	exists := slices.Contains(sessions, detachedSession)
	if exists {
		log.Printf("Session '%s' already exists", detachedSession)
		if killExistingSession {
			if err := KillSession(detachedSession); err != nil {
				return nil, fmt.Errorf("could not kill existing session: %w", err)
			}
			id, err := StartDetachedSession(detachedSession)
			if err != nil {
				return nil, fmt.Errorf("could not start detached session after kill: %w", err)
			}
			detachedSessionID = id
		} else {
			return nil, fmt.Errorf("session '%s' already exists (set killExistingSession to true to replace it)", detachedSession)
		}
	} else {
		id, err := StartDetachedSession(detachedSession)
		if err != nil {
			return nil, fmt.Errorf("could not start detached session: %w", err)
		}
		detachedSessionID = id
	}
	splitSize := 100 - processListWidthPercent

	return &TmuxContext{
		PaneID:            paneID,
		SessionID:         sessionID,
		DetachedSessionID: detachedSessionID,
		SplitSize:         strconv.Itoa(splitSize) + "%",
	}, nil
}

// buildEnvWithAddPath merges process Env and AddPath into a final env map.
// It appends AddPath entries to PATH (matching Python's sys.path.append semantics).
func buildEnvWithAddPath(p *Process) map[string]string {
	merged := map[string]string{}
	if p.Config != nil && p.Config.Env != nil {
		for k, v := range p.Config.Env {
			merged[k] = v
		}
	}
	// Base PATH from explicit env PATH or current process PATH
	path := merged["PATH"]
	if path == "" {
		path = os.Getenv("PATH")
	}
	if p.Config != nil && len(p.Config.AddPath) > 0 {
		sep := string(os.PathListSeparator)
		for _, ap := range p.Config.AddPath {
			if ap == "" {
				continue
			}
			if path == "" {
				path = ap
			} else {
				path = path + sep + ap // append
			}
		}
	}
	merged["PATH"] = path
	return merged
}

func (t *TmuxContext) CreatePane(process *Process) (string, int, error) {
	// Create a new pane split off the main proctmux pane, not the process's pane
	return CreatePane(
		t.PaneID,
		process.Command(),
		process.Config.Cwd,
		buildEnvWithAddPath(process),
		t.SplitSize,
	)
}

// Create a pane in the detached session
func (t *TmuxContext) CreateDetachedPane(process *Process) (string, int, error) {
	paneID, pid, err := CreateDetachedPane(
		t.DetachedSessionID,
		process.ID,
		process.Label,
		process.Command(),
		process.Config.Cwd,
		buildEnvWithAddPath(process),
	)
	if err != nil {
		return "", 0, err
	}
	return paneID, pid, nil
}

// Move a pane to the detached session
func (t *TmuxContext) BreakPane(paneID string, destWindow int, windowLabel string) error {
	return BreakPane(paneID, t.DetachedSessionID, destWindow, windowLabel)
}

// Move a pane from the detached session to the user session
func (t *TmuxContext) JoinPane(sourcePaneID string) error {
	return JoinPane(sourcePaneID, t.PaneID, t.SplitSize)
}

func (t *TmuxContext) Prepare() error {
	return SetGlobalRemainOnExit(true)
}

func (t *TmuxContext) Cleanup() error {
	if err := KillSession(t.DetachedSessionID); err != nil {
		return err
	}
	return SetGlobalRemainOnExit(false)
}

func (t *TmuxContext) FocusPane(paneID string) error {
	return SelectPane(paneID)
}

func (t *TmuxContext) ToggleZoom(paneID string) error {
	return ToggleZoom(paneID)
}

func (t *TmuxContext) PaneVariables(paneID, format string) (string, error) {
	args := []string{"list-panes", "-t", paneID, "-F", format}
	out, err := exec.Command("tmux", args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (t *TmuxContext) IsZoomedIn() bool {
	out, err := t.PaneVariables(t.PaneID, "#{window_zoomed_flag} #{pane_active}")
	if err != nil {
		return false
	}
	return out == "1 1"
}

func (t *TmuxContext) ZoomIn() error {
	if !t.IsZoomedIn() {
		return t.ToggleZoom(t.PaneID)
	}
	return nil
}

func (t *TmuxContext) ZoomOut() error {
	if t.IsZoomedIn() {
		return t.ToggleZoom(t.PaneID)
	}
	return nil
}

func (t *TmuxContext) GetPanePID(paneID string) (int, error) {
	out, err := exec.Command("tmux", "display-message", "-p", "-t", paneID, "#{pane_pid}").Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

// GetPaneSessionType wraps GetPaneSessionType using the context's session IDs.
func (t *TmuxContext) GetPaneSessionType(paneID string) (string, error) {
	return GetPaneSessionType(paneID, t.SessionID, t.DetachedSessionID)
}
