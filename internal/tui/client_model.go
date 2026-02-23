package tui

import (
	"time"

	"github.com/charmbracelet/bubbles/help"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nick/proctmux/internal/domain"
)

const messageTimeout = 5 * time.Second

// timedMessage tracks temporary UI messages with an expiry.
type timedMessage struct {
	Text      string
	ExpiresAt time.Time
}

// UIState holds the UI-specific state for the client TUI
type UIState struct {
	Messages           []timedMessage
	FilterText         string
	EnteringFilterText bool
	ShowOnlyRunning    bool // Toggle between showing all processes vs only running ones
	ShowHelp           bool // Toggle help panel visibility with '?'
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
	initialized  bool // Track if we've received the first state update

	procList processListComponent
	filterUI filterComponent
	keys     KeyMap
	help     help.Model
}

type clientStateUpdateMsg struct {
	state        *domain.AppState
	processViews []domain.ProcessView
}

type pruneMessagesMsg struct{}

func (m *ClientModel) addErrorMessage(text string) tea.Cmd {
	now := time.Now()
	m.pruneExpiredMessages(now)

	entry := timedMessage{Text: text, ExpiresAt: now.Add(messageTimeout)}
	m.ui.Messages = append(m.ui.Messages, entry)

	return tea.Tick(messageTimeout, func(time.Time) tea.Msg {
		return pruneMessagesMsg{}
	})
}

func (m *ClientModel) pruneExpiredMessages(now time.Time) {
	if len(m.ui.Messages) == 0 {
		return
	}

	filtered := m.ui.Messages[:0]
	for _, msg := range m.ui.Messages {
		if now.Before(msg.ExpiresAt) {
			filtered = append(filtered, msg)
		}
	}
	m.ui.Messages = filtered
}

func (m *ClientModel) visibleMessages(now time.Time) []string {
	if len(m.ui.Messages) == 0 {
		return nil
	}

	texts := make([]string, 0, len(m.ui.Messages))
	for _, msg := range m.ui.Messages {
		if now.Before(msg.ExpiresAt) {
			texts = append(texts, msg.Text)
		}
	}

	return texts
}

func NewClientModel(client IPCClient, state *domain.AppState) ClientModel {
	m := ClientModel{
		client:       client,
		domain:       state,
		processViews: []domain.ProcessView{},
		ui:           UIState{Messages: []timedMessage{}, ActiveProcID: state.CurrentProcID},
		keys:         NewKeyMap(state.Config.Keybinding),
		help:         help.New(),
	}
	m.procList.SetConfig(state.Config)
	m.procList.SetItems(domain.FilterProcesses(state.Config, m.processViews, m.ui.FilterText, m.ui.ShowOnlyRunning))
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
	procs := domain.FilterProcesses(m.domain.Config, m.processViews, m.ui.FilterText, m.ui.ShowOnlyRunning)
	m.procList.SetItems(procs)
	m.procList.SetActiveID(m.ui.ActiveProcID)
}

func (m *ClientModel) headerHeight() int {
	height := 0

	panelWidth := m.termWidth
	if panelWidth <= 0 {
		panelWidth = 80
	}

	helpView := m.helpPanelBubbleTea()
	if helpView != "" {
		height += lipgloss.Height(helpView)
	}

	descView := processDescriptionPanel(m.domain.Config, m.domain.GetProcessByID(m.ui.ActiveProcID), panelWidth)
	if descView != "" {
		height += lipgloss.Height(descView)
	}

	visibleMsgs := m.visibleMessages(time.Now())
	messagesView := messagesPanel(panelWidth, m.ui.Info, visibleMsgs)
	if messagesView != "" {
		height += lipgloss.Height(messagesView)
	}

	filterView := m.filterUI.View()
	// always include the spot for the filter to prevent shifting
	height += lipgloss.Height(filterView)

	return height
}

func (m *ClientModel) updateLayout() {
	if m.termWidth == 0 || m.termHeight == 0 {
		return
	}
	headerH := m.headerHeight()
	listH := max(m.termHeight-headerH, 0)
	m.procList.SetSize(m.termWidth, listH)
}

func (m ClientModel) Init() tea.Cmd { return m.subscribeToStateUpdates() }

func (m ClientModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case clientStateUpdateMsg:
		m.domain = msg.state
		m.processViews = msg.processViews
		m.initialized = true // Mark as initialized on first update
		m.rebuildProcessList()
		m.updateLayout()
		return m, m.subscribeToStateUpdates()
	case tea.WindowSizeMsg:
		m.termWidth, m.termHeight = msg.Width, msg.Height
		m.updateLayout()
		return m, nil
	case errMsg:
		cmd := m.addErrorMessage(msg.Error())
		m.updateLayout()
		return m, cmd
	case pruneMessagesMsg:
		m.pruneExpiredMessages(time.Now())
		m.updateLayout()
		return m, nil
	case tea.KeyMsg:
		cmd := m.handleKey(msg)
		return m, cmd
	}
	return m, nil
}
