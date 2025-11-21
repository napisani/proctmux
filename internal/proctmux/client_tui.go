package proctmux

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/tui"
)

// Backwards compatibility shim: re-export TUI types from internal/tui.

type IPCClient = tui.IPCClient

type ClientModel = tui.ClientModel

func NewClientModel(client IPCClient, state *domain.AppState) ClientModel {
	return tui.NewClientModel(client, state)
}

// Ensure the type implements tea.Model
var _ tea.Model = (*tui.ClientModel)(nil)
