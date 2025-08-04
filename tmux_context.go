package main

import (
	"fmt"
)

type TmuxContext struct {
	PaneID            string
	SessionID         string
	DetachedSessionID string
}

func NewTmuxContext(detachedSession string, killExistingSession bool) (*TmuxContext, error) {
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
	exists := false
	for _, s := range sessions {
		if s == detachedSession {
			exists = true
			break
		}
	}
	if exists {
		if killExistingSession {
			if err := KillSession(detachedSession); err != nil {
				return nil, fmt.Errorf("could not kill existing session: %w", err)
			}
			id, err := StartDetachedSession(detachedSession)
			if err != nil {
				return nil, fmt.Errorf("could not start detached session: %w", err)
			}
			detachedSessionID = id
		} else {
			return nil, fmt.Errorf("session '%s' already exists", detachedSession)
		}
	} else {
		id, err := StartDetachedSession(detachedSession)
		if err != nil {
			return nil, fmt.Errorf("could not start detached session: %w", err)
		}
		detachedSessionID = id
	}
	return &TmuxContext{
		PaneID:            paneID,
		SessionID:         sessionID,
		DetachedSessionID: detachedSessionID,
	}, nil
}

func (t *TmuxContext) CreatePane(cmd, cwd string, env map[string]string) (string, error) {
	return CreatePane(t.PaneID, cmd, cwd, env)
}

func (t *TmuxContext) Prepare() error {
	return SetRemainOnExit(t.PaneID, true)
}

func (t *TmuxContext) Cleanup() error {
	if err := KillSession(t.DetachedSessionID); err != nil {
		return err
	}
	return SetRemainOnExit(t.PaneID, false)
}

func (t *TmuxContext) FocusPane(paneID string) error {
	return SelectPane(paneID)
}

func (t *TmuxContext) ToggleZoom(paneID string) error {
	return ToggleZoom(paneID)
}
