package tui

import (
	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
)

// forwardMsgToChild sends a message to a child tea.Model and returns the
// updated model and command. Both wrapper models (SplitPaneModel and
// ToggleViewModel) use this to delegate messages to their embedded ClientModel.
func forwardMsgToChild(child tea.Model, msg tea.Msg) (tea.Model, tea.Cmd) {
	if child == nil {
		return child, nil
	}
	return child.Update(msg)
}

// asClientModel extracts a *ClientModel from a tea.Model interface.
// Returns nil if the underlying type is not ClientModel or *ClientModel.
// Both wrapper models store clientModel as tea.Model and need to access
// ClientModel internals for things like active process ID and process names.
func asClientModel(m tea.Model) *ClientModel {
	switch cm := m.(type) {
	case ClientModel:
		return &cm
	case *ClientModel:
		return cm
	default:
		return nil
	}
}

// focusKeys holds the keybindings used by wrapper models (SplitPaneModel and
// ToggleViewModel) to switch focus between panes/views.
type focusKeys struct {
	toggle key.Binding
	client key.Binding
	server key.Binding
}

// newFocusKeys extracts focus keybindings from a ClientModel's KeyMap.
func newFocusKeys(km KeyMap) focusKeys {
	return focusKeys{
		toggle: km.ToggleFocus,
		client: km.FocusClient,
		server: km.FocusServer,
	}
}
