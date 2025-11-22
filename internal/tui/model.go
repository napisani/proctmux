package tui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nick/proctmux/internal/domain"
)

// UIState holds the UI-specific state for the client TUI
type UIState struct {
	Messages           []string
	FilterText         string
	EnteringFilterText bool
	Info               string
	Mode               domain.Mode
	ActiveProcID       int
}

// IPCClient abstracts IPC client operations needed by the TUI
type IPCClient interface {
	ReceiveUpdates() <-chan domain.StateUpdate
	SwitchProcess(label string) error
	StartProcess(label string) error
	StopProcess(label string) error
	StopRunning() error
	RestartProcess(label string) error
}

// ClientModel is a UI-only model that connects to a primary server
type ClientModel struct {
	client       IPCClient
	domain       *domain.AppState
	processViews []domain.ProcessView
	ui           UIState
	termWidth    int
	termHeight   int

	procList processListComponent
	filterUI filterComponent
}

type clientStateUpdateMsg struct {
	state        *domain.AppState
	processViews []domain.ProcessView
}

func NewClientModel(client IPCClient, state *domain.AppState) ClientModel {
	m := ClientModel{
		client:       client,
		domain:       state,
		processViews: []domain.ProcessView{},
		ui:           UIState{Messages: []string{}, ActiveProcID: state.CurrentProcID},
	}
	m.procList.SetConfig(state.Config)
	m.procList.SetItems(domain.FilterProcesses(state.Config, m.processViews, m.ui.FilterText))
	m.procList.SetActiveID(m.ui.ActiveProcID)
	m.filterUI = newFilterComponent()
	return m
}

func (m ClientModel) subscribeToStateUpdates() tea.Cmd {
	return func() tea.Msg {
		upd := <-m.client.ReceiveUpdates()
		return clientStateUpdateMsg{state: upd.State, processViews: upd.ProcessViews}
	}
}

func (m *ClientModel) rebuildProcessList() {
	m.procList.SetConfig(m.domain.Config)
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText)
	m.procList.SetItems(procs)
	m.procList.SetActiveID(m.ui.ActiveProcID)
}

func (m *ClientModel) headerHeight() int {
	h := 0
	h += lipgloss.Height(helpPanel(m.domain.Config))
	h += lipgloss.Height(processDescriptionPanel(m.domain.Config, m.domain.GetProcessByID(m.ui.ActiveProcID)))
	h += lipgloss.Height(messagesPanel(m.ui.Info, m.ui.Messages))
	h += lipgloss.Height(m.filterUI.View())
	return h
}

func (m *ClientModel) updateLayout() {
	if m.termWidth == 0 || m.termHeight == 0 {
		return
	}
	headerH := m.headerHeight()
	listH := m.termHeight - headerH
	if listH < 0 {
		listH = 0
	}
	m.procList.SetSize(m.termWidth, listH)
}

func (m ClientModel) Init() tea.Cmd { return m.subscribeToStateUpdates() }

func (m ClientModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case clientStateUpdateMsg:
		m.domain = msg.state
		m.processViews = msg.processViews
		m.rebuildProcessList()
		m.updateLayout()
		return m, m.subscribeToStateUpdates()
	case tea.WindowSizeMsg:
		m.termWidth, m.termHeight = msg.Width, msg.Height
		m.updateLayout()
		return m, nil
	case errMsg:
		m.ui.Messages = append(m.ui.Messages, msg.Error())
		m.updateLayout()
		return m, nil
	case tea.KeyMsg:
		cmd := m.handleKey(msg)
		return m, cmd
	}
	return m, nil
}
