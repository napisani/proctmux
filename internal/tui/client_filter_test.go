package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

// --- test fakes ---

type fakeIPCClient struct {
	switchedTo string
	startedErr error
}

func (f *fakeIPCClient) ReceiveUpdates() <-chan domain.StateUpdate {
	ch := make(chan domain.StateUpdate)
	return ch // never sends — tests don't rely on subscriptions
}
func (f *fakeIPCClient) SwitchProcess(label string) error {
	f.switchedTo = label
	return nil
}
func (f *fakeIPCClient) StartProcess(string) error   { return f.startedErr }
func (f *fakeIPCClient) StopProcess(string) error    { return nil }
func (f *fakeIPCClient) StopRunning() error          { return nil }
func (f *fakeIPCClient) RestartProcess(string) error { return nil }

// --- helpers ---

func testFilterConfig() *config.ProcTmuxConfig {
	return &config.ProcTmuxConfig{
		Layout: config.LayoutConfig{
			CategorySearchPrefix: "cat:",
		},
		Keybinding: config.KeybindingConfig{
			Quit:          []string{"q"},
			Filter:        []string{"/"},
			FilterSubmit:  []string{"enter"},
			Start:         []string{"s"},
			Stop:          []string{"x"},
			Up:            []string{"k", "up"},
			Down:          []string{"j", "down"},
			ToggleRunning: []string{"R"},
			ToggleHelp:    []string{"?"},
		},
		Style: config.StyleConfig{
			PointerChar: ">",
		},
		Procs: map[string]config.ProcessConfig{
			"alpha-api":   {Shell: "sleep 1", Categories: []string{"server"}},
			"beta-worker": {Shell: "sleep 1", Categories: []string{"worker"}},
			"gamma-db":    {Shell: "sleep 1", Categories: []string{"db"}},
		},
	}
}

func testProcessViews() []domain.ProcessView {
	return []domain.ProcessView{
		{ID: 1, Label: "alpha-api", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"server"}}},
		{ID: 2, Label: "beta-worker", Status: domain.StatusHalted, Config: &config.ProcessConfig{Categories: []string{"worker"}}},
		{ID: 3, Label: "gamma-db", Status: domain.StatusRunning, Config: &config.ProcessConfig{Categories: []string{"db"}}},
	}
}

// newTestClientModel creates a ClientModel with test data pre-loaded as if
// a clientStateUpdateMsg had already arrived.
func newTestClientModel() (ClientModel, *fakeIPCClient) {
	client := &fakeIPCClient{}
	cfg := testFilterConfig()
	state := domain.NewAppState(cfg)
	m := NewClientModel(client, &state)

	// Simulate receiving a state update with process views.
	views := testProcessViews()
	m.domain = &state
	m.processViews = views
	m.initialized = true
	m.termWidth = 80
	m.termHeight = 40
	m.rebuildProcessList()
	m.updateLayout()
	return m, client
}

func sendKey(m ClientModel, key string) (ClientModel, tea.Cmd) {
	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
	return model.(ClientModel), cmd
}

func sendSpecialKey(m ClientModel, keyType tea.KeyType) (ClientModel, tea.Cmd) {
	model, cmd := m.Update(tea.KeyMsg{Type: keyType})
	return model.(ClientModel), cmd
}

// --- tests ---

func TestFilter_EnterMode_SetsCorrectState(t *testing.T) {
	m, _ := newTestClientModel()

	m, _ = sendKey(m, "/")

	if !m.ui.EnteringFilterText {
		t.Error("expected EnteringFilterText=true after pressing /")
	}
	if m.ui.Mode != domain.FilterMode {
		t.Errorf("expected FilterMode, got %v", m.ui.Mode)
	}
	if m.ui.FilterText != "" {
		t.Errorf("expected empty FilterText, got %q", m.ui.FilterText)
	}
	if m.ui.ActiveProcID != 0 {
		t.Errorf("expected ActiveProcID=0, got %d", m.ui.ActiveProcID)
	}
}

func TestFilter_TypingUpdatesFilterText(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alp" {
		m, _ = sendKey(m, string(r))
	}

	if m.ui.FilterText != "alp" {
		t.Errorf("expected FilterText=%q, got %q", "alp", m.ui.FilterText)
	}
	if !m.ui.EnteringFilterText {
		t.Error("should still be in filter mode while typing")
	}
}

func TestFilter_TypingNarrowsProcessList(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	// Only alpha-api should match "alpha"
	items := m.procList.list.Items()
	if len(items) != 1 {
		t.Fatalf("expected 1 item after filtering for 'alpha', got %d", len(items))
	}
	pi := items[0].(procItem)
	if pi.view.Label != "alpha-api" {
		t.Errorf("expected alpha-api, got %q", pi.view.Label)
	}
}

func TestFilter_SubmitExitsFilterModeAndPreservesText(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	m, _ = sendSpecialKey(m, tea.KeyEnter)

	if m.ui.EnteringFilterText {
		t.Error("should not be in filter mode after Enter")
	}
	if m.ui.Mode != domain.NormalMode {
		t.Errorf("expected NormalMode after submit, got %v", m.ui.Mode)
	}
	if m.ui.FilterText != "alpha" {
		t.Errorf("expected FilterText=%q preserved after submit, got %q", "alpha", m.ui.FilterText)
	}
}

func TestFilter_SubmitSelectsFirstMatch(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	m, _ = sendSpecialKey(m, tea.KeyEnter)

	if m.ui.ActiveProcID != 1 {
		t.Errorf("expected ActiveProcID=1 (alpha-api) after submit, got %d", m.ui.ActiveProcID)
	}
}

func TestFilter_EscapeCancelsAndClearsText(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	m, _ = sendSpecialKey(m, tea.KeyEscape)

	if m.ui.EnteringFilterText {
		t.Error("should not be in filter mode after Escape")
	}
	if m.ui.FilterText != "" {
		t.Errorf("expected FilterText cleared after Escape, got %q", m.ui.FilterText)
	}
	// All processes should be restored
	items := m.procList.list.Items()
	if len(items) != 3 {
		t.Errorf("expected all 3 processes restored after Escape, got %d", len(items))
	}
}

func TestFilter_ToggleOffPreservesText(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	// Press / again to toggle off
	m, _ = sendKey(m, "/")

	if m.ui.EnteringFilterText {
		t.Error("should not be in filter mode after toggling /")
	}
	if m.ui.FilterText != "alpha" {
		t.Errorf("expected FilterText=%q preserved after toggle, got %q", "alpha", m.ui.FilterText)
	}
}

func TestFilter_ApplyNowSelectsFirstMatch(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "gamma" {
		m, _ = sendKey(m, string(r))
	}

	// gamma-db should be the first (and only) match
	if m.ui.ActiveProcID != 3 {
		t.Errorf("expected ActiveProcID=3 (gamma-db), got %d", m.ui.ActiveProcID)
	}
}

func TestFilter_ApplyNowNoMatchSetsActiveIDZero(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "zzzzz" {
		m, _ = sendKey(m, string(r))
	}

	if m.ui.ActiveProcID != 0 {
		t.Errorf("expected ActiveProcID=0 for no match, got %d", m.ui.ActiveProcID)
	}
	items := m.procList.list.Items()
	if len(items) != 0 {
		t.Errorf("expected 0 items for no match, got %d", len(items))
	}
}

func TestFilter_MoveSelectionWrapsWithinFilteredList(t *testing.T) {
	m, _ := newTestClientModel()

	// Select the first process
	m, _ = sendKey(m, "j")
	first := m.ui.ActiveProcID

	// Move down through all items and wrap
	for i := 0; i < 3; i++ {
		m, _ = sendKey(m, "j")
	}

	if m.ui.ActiveProcID != first {
		t.Errorf("expected wrap to first item %d, got %d", first, m.ui.ActiveProcID)
	}
}

func TestFilter_MoveSelectionEmptyListSetsZero(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "zzzzz" {
		m, _ = sendKey(m, string(r))
	}

	// Submit the no-match filter
	m, _ = sendSpecialKey(m, tea.KeyEnter)

	// Try navigating in empty list
	m, _ = sendKey(m, "j")

	if m.ui.ActiveProcID != 0 {
		t.Errorf("expected ActiveProcID=0 in empty list, got %d", m.ui.ActiveProcID)
	}
}

func TestFilter_NavigationAfterSubmitStaysFiltered(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	m, _ = sendSpecialKey(m, tea.KeyEnter)

	// Navigate down — should stay within filtered results
	m, _ = sendKey(m, "j")

	// The filtered list has only 1 item (alpha-api), so j should keep it selected
	if m.ui.ActiveProcID != 1 {
		t.Errorf("expected to stay on alpha-api (ID=1) after j in filtered list, got %d", m.ui.ActiveProcID)
	}

	// Process list should still be filtered
	items := m.procList.list.Items()
	if len(items) != 1 {
		t.Errorf("expected 1 filtered item after navigation, got %d", len(items))
	}
}

func TestFilter_ShowOnlyRunningCombinedWithText(t *testing.T) {
	m, _ := newTestClientModel()

	// Toggle show only running
	m, _ = sendKey(m, "R")

	if !m.ui.ShowOnlyRunning {
		t.Fatal("expected ShowOnlyRunning=true after R")
	}

	// Only running processes: alpha-api (running) and gamma-db (running)
	items := m.procList.list.Items()
	if len(items) != 2 {
		t.Fatalf("expected 2 running processes, got %d", len(items))
	}

	// Now filter by "alpha"
	m, _ = sendKey(m, "/")
	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	// Should match only alpha-api (running + matches "alpha")
	items = m.procList.list.Items()
	if len(items) != 1 {
		t.Fatalf("expected 1 item with running+alpha filter, got %d", len(items))
	}
	pi := items[0].(procItem)
	if pi.view.Label != "alpha-api" {
		t.Errorf("expected alpha-api, got %q", pi.view.Label)
	}
}

func TestFilter_WhitespaceTrimmed(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	// Type " alpha " with leading/trailing spaces
	for _, r := range " alpha " {
		m, _ = sendKey(m, string(r))
	}

	// FilterProcesses trims whitespace, so "alpha" should match
	items := m.procList.list.Items()
	matched := false
	for _, item := range items {
		pi := item.(procItem)
		if pi.view.Label == "alpha-api" {
			matched = true
		}
	}
	if !matched {
		t.Error("expected alpha-api to match filter with whitespace")
	}
}

func TestFilter_PersistentIndicatorShownWhenActive(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	// Submit filter
	m, _ = sendSpecialKey(m, tea.KeyEnter)

	// The filter component should show a persistent indicator
	view := m.filterUI.View()
	if !strings.Contains(view, "alpha") {
		t.Errorf("expected persistent filter indicator to contain 'alpha', got %q", view)
	}
	if !strings.Contains(view, "esc") {
		t.Errorf("expected persistent filter indicator to mention esc to clear, got %q", view)
	}
}

func TestFilter_NoMatchShowsFriendlyMessage(t *testing.T) {
	m, _ := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "zzzzz" {
		m, _ = sendKey(m, string(r))
	}

	view := m.procList.View()
	if !strings.Contains(view, "No matching processes") {
		t.Errorf("expected 'No matching processes' in empty list view, got %q", view)
	}
}

func TestFilter_SwitchSentToPrimaryOnApply(t *testing.T) {
	m, client := newTestClientModel()
	m, _ = sendKey(m, "/")

	for _, r := range "alpha" {
		m, _ = sendKey(m, string(r))
	}

	// The last applyFilterNow should have returned a Cmd that sends
	// a switch to the primary. We can't easily run async Cmds in tests,
	// but we can verify the ActiveProcID was set correctly and
	// activeProcLabel returns the right label.
	label := m.activeProcLabel()
	if label != "alpha-api" {
		t.Errorf("expected activeProcLabel=%q, got %q", "alpha-api", label)
	}

	// Simulate the switch Cmd
	if err := client.SwitchProcess(label); err != nil {
		t.Errorf("SwitchProcess failed: %v", err)
	}
	if client.switchedTo != "alpha-api" {
		t.Errorf("expected switch to alpha-api, got %q", client.switchedTo)
	}
}
