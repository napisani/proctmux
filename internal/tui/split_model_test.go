package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

// --- test fakes ---

// fakeEmulator implements terminal.Emulator for testing.
type fakeEmulator struct {
	rendered string
	cols     int
	rows     int
	closed   bool
}

func (f *fakeEmulator) Write(p []byte) (int, error) { return len(p), nil }
func (f *fakeEmulator) Render() string              { return f.rendered }
func (f *fakeEmulator) Resize(cols, rows int)       { f.cols = cols; f.rows = rows }
func (f *fakeEmulator) Close()                      { f.closed = true }

// testKeybindingConfig returns a KeybindingConfig with focus keys configured.
func testKeybindingConfig() config.KeybindingConfig {
	return config.KeybindingConfig{
		Quit:        []string{"q"},
		Up:          []string{"k"},
		Down:        []string{"j"},
		ToggleFocus: []string{"tab"},
		FocusClient: []string{"1"},
		FocusServer: []string{"2"},
	}
}

// testClientModel constructs a minimal ClientModel suitable for testing
// SplitPaneModel focus behavior.
func testClientModel() ClientModel {
	cfg := &config.ProcTmuxConfig{
		Keybinding: testKeybindingConfig(),
	}
	state := domain.NewAppState(cfg)
	return NewClientModel(nil, &state)
}

// --- Task 2: Focus and Visibility tests ---

func TestSplitPaneModel_StartupVisibility_HideDisabled(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, false)

	// When hide-on-unfocus is disabled, clientVisible is always true
	// regardless of which pane is focused.
	if !m.clientVisible() {
		t.Error("clientVisible() should be true when hide-on-unfocus is disabled and focus is on client")
	}

	// Switch focus to server; clientVisible should still be true.
	m.focus = paneServer
	if !m.clientVisible() {
		t.Error("clientVisible() should be true when hide-on-unfocus is disabled even when focused on server")
	}
}

func TestSplitPaneModel_StartupVisibility_HideEnabled(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Startup should focus client pane
	if m.focus != paneClient {
		t.Errorf("expected startup focus on paneClient, got %d", m.focus)
	}

	// Even with hide-on-unfocus enabled, the client pane is visible at startup
	// because we start focused on the client.
	if !m.clientVisible() {
		t.Error("clientVisible() should be true at startup (focused on client) even with hide-on-unfocus enabled")
	}
}

func TestSplitPaneModel_FocusServer_HidesClient(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Simulate pressing the focus_server key
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}}
	updated, _ := m.Update(msg)
	m = updated.(SplitPaneModel)

	if m.focus != paneServer {
		t.Errorf("expected focus on paneServer after focus_server key, got %d", m.focus)
	}
	if m.clientVisible() {
		t.Error("clientVisible() should be false when hide-on-unfocus is enabled and server is focused")
	}
}

func TestSplitPaneModel_FocusClient_RestoresClient(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Focus server first
	m.focus = paneServer
	if m.clientVisible() {
		t.Error("precondition: clientVisible() should be false when server is focused with hide enabled")
	}

	// Simulate pressing the focus_client key
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}}
	updated, _ := m.Update(msg)
	m = updated.(SplitPaneModel)

	if m.focus != paneClient {
		t.Errorf("expected focus on paneClient after focus_client key, got %d", m.focus)
	}
	if !m.clientVisible() {
		t.Error("clientVisible() should be true after focusing client")
	}
}

func TestSplitPaneModel_ToggleFocus_SwitchesVisibility(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Start on client; toggle should move to server and hide client
	msg := tea.KeyMsg{Type: tea.KeyTab}
	updated, _ := m.Update(msg)
	m = updated.(SplitPaneModel)

	if m.focus != paneServer {
		t.Errorf("expected focus on paneServer after toggle, got %d", m.focus)
	}
	if m.clientVisible() {
		t.Error("clientVisible() should be false after toggling to server with hide enabled")
	}

	// Toggle again: back to client, visible again
	updated, _ = m.Update(msg)
	m = updated.(SplitPaneModel)

	if m.focus != paneClient {
		t.Errorf("expected focus on paneClient after second toggle, got %d", m.focus)
	}
	if !m.clientVisible() {
		t.Error("clientVisible() should be true after toggling back to client")
	}
}

// --- Task 3: Layout Sizing and Status Text tests ---

// focusServerKey is the key message for the "2" key bound to FocusServer.
var focusServerKey = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}}

// focusClientKey is the key message for the "1" key bound to FocusClient.
var focusClientKey = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}}

// updateModel is a helper that sends a message through Update and returns
// the resulting SplitPaneModel.
func updateModel(t *testing.T, m SplitPaneModel, msg tea.Msg) SplitPaneModel {
	t.Helper()
	updated, _ := m.Update(msg)
	return updated.(SplitPaneModel)
}

func TestSplitPaneModel_LayoutSizing_LeftRight_HiddenClient(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Resize to known dimensions
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	// Initially focused on client; both panes should have width
	if m.clientWidth == 0 {
		t.Error("clientWidth should be > 0 when client is visible")
	}
	if m.serverWidth == 0 {
		t.Error("serverWidth should be > 0 when client is visible")
	}
	initialServerWidth := m.serverWidth

	// Focus server via key press to hide client — no manual handleResize
	m = updateModel(t, m, focusServerKey)

	if m.clientWidth != 0 {
		t.Errorf("expected clientWidth 0 when client is hidden, got %d", m.clientWidth)
	}
	if m.clientHeight != 0 {
		t.Errorf("expected clientHeight 0 when client is hidden, got %d", m.clientHeight)
	}
	if m.serverWidth != 120 {
		t.Errorf("expected serverWidth to fill full width (120), got %d", m.serverWidth)
	}
	if m.serverWidth <= initialServerWidth {
		t.Errorf("expected serverWidth to be larger when client is hidden; was %d, now %d", initialServerWidth, m.serverWidth)
	}
}

func TestSplitPaneModel_LayoutSizing_TopBottom_HiddenClient(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitTop, true)

	// Resize to known dimensions
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 80, Height: 40})

	// Initially focused on client; both should have height
	if m.clientHeight == 0 {
		t.Error("clientHeight should be > 0 when client is visible")
	}
	if m.serverHeight == 0 {
		t.Error("serverHeight should be > 0 when client is visible")
	}
	initialServerHeight := m.serverHeight

	// Focus server via key press to hide client — no manual handleResize
	m = updateModel(t, m, focusServerKey)

	contentHeight := m.contentHeight
	if m.clientHeight != 0 {
		t.Errorf("expected clientHeight 0 when client is hidden, got %d", m.clientHeight)
	}
	if m.clientWidth != 0 {
		t.Errorf("expected clientWidth 0 when client is hidden, got %d", m.clientWidth)
	}
	if m.serverHeight != contentHeight {
		t.Errorf("expected serverHeight to fill full content height (%d), got %d", contentHeight, m.serverHeight)
	}
	if m.serverHeight <= initialServerHeight {
		t.Errorf("expected serverHeight to be larger when client is hidden; was %d, now %d", initialServerHeight, m.serverHeight)
	}
}

func TestSplitPaneModel_LayoutSizing_RestoreClient(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitRight, true)

	// Initial layout with client visible
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})
	originalClientWidth := m.clientWidth
	originalServerWidth := m.serverWidth

	// Hide client via key press
	m = updateModel(t, m, focusServerKey)

	// Restore client via key press
	m = updateModel(t, m, focusClientKey)

	if m.clientWidth != originalClientWidth {
		t.Errorf("expected clientWidth to restore to %d, got %d", originalClientWidth, m.clientWidth)
	}
	if m.serverWidth != originalServerWidth {
		t.Errorf("expected serverWidth to restore to %d, got %d", originalServerWidth, m.serverWidth)
	}
}

func TestSplitPaneModel_StatusBar_ProcessListHidden(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Set dimensions so status bar renders
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	// Focus server via key press to hide client
	m = updateModel(t, m, focusServerKey)

	view := m.View()
	if !strings.Contains(view, "process list hidden") {
		t.Error("expected View() to contain 'process list hidden' when client is hidden")
	}
}

func TestSplitPaneModel_StatusBar_NoHiddenMessage_WhenVisible(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, true)

	// Set dimensions so status bar renders
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	// Client is focused and visible
	view := m.View()
	if strings.Contains(view, "process list hidden") {
		t.Error("expected View() NOT to contain 'process list hidden' when client is visible")
	}
}

func TestSplitPaneModel_StatusBar_NoHiddenMessage_WhenFeatureDisabled(t *testing.T) {
	client := testClientModel()
	emu := &fakeEmulator{}
	m := NewSplitPaneModel(client, emu, nil, nil, SplitLeft, false)

	// Set dimensions so status bar renders
	m = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	// Focus server; no hidden message when feature is disabled
	m = updateModel(t, m, focusServerKey)

	view := m.View()
	if strings.Contains(view, "process list hidden") {
		t.Error("expected View() NOT to contain 'process list hidden' when feature is disabled")
	}
}
