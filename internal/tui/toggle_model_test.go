package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

func testToggleConfig() *config.ProcTmuxConfig {
	cfg := &config.ProcTmuxConfig{
		FilePath: "test.yaml",
		Keybinding: config.KeybindingConfig{
			Quit:          []string{"q", "ctrl+c"},
			Up:            []string{"k", "up"},
			Down:          []string{"j", "down"},
			Start:         []string{"s", "enter"},
			Stop:          []string{"x"},
			Restart:       []string{"r"},
			Filter:        []string{"/"},
			FilterSubmit:  []string{"enter"},
			ToggleRunning: []string{"R"},
			ToggleHelp:    []string{"?"},
			ToggleFocus:   []string{"ctrl+w"},
			FocusClient:   []string{"ctrl+left"},
			FocusServer:   []string{"ctrl+right"},
			Docs:          []string{"d"},
		},
		Procs: map[string]config.ProcessConfig{
			"test-proc": {Shell: "echo hello", Autostart: true},
		},
	}
	return cfg
}

func makeToggleModel() ToggleViewModel {
	cfg := testToggleConfig()
	return ToggleViewModel{
		clientModel:        nil, // nil is fine for tests that don't forward
		processController:  nil, // nil is fine for toggle state tests
		cfg:                cfg,
		showingProcessList: true,
		keys: focusKeys{
			toggle: key.NewBinding(key.WithKeys("ctrl+w")),
			client: key.NewBinding(key.WithKeys("ctrl+left")),
			server: key.NewBinding(key.WithKeys("ctrl+right")),
		},
	}
}

func TestToggleViewModel_InitialState(t *testing.T) {
	m := makeToggleModel()

	if !m.showingProcessList {
		t.Error("expected showingProcessList to be true initially")
	}
	if m.currentViewedProcID != 0 {
		t.Errorf("expected currentViewedProcID to be 0, got %d", m.currentViewedProcID)
	}
	if m.scrollbackContent != "" {
		t.Errorf("expected empty scrollbackContent, got %q", m.scrollbackContent)
	}
}

func TestToggleViewModel_ToggleFocusSwitchesToScrollback(t *testing.T) {
	// Without a real process controller, switching to scrollback will fail
	// to find a process and stay on process list. This tests that the toggle
	// key is recognized and the intent is correct.
	m := makeToggleModel()

	// Send toggle focus key — since no process is active (procID=0), it
	// should stay on process list.
	msg := tea.KeyMsg{Type: tea.KeyCtrlW}
	result, _ := m.Update(msg)
	model := result.(ToggleViewModel)

	// Should remain on process list because getActiveProcessID returns 0
	if !model.showingProcessList {
		t.Error("expected to stay on process list when no process is active")
	}
}

func TestToggleViewModel_FocusClientWhenAlreadyOnProcessList(t *testing.T) {
	m := makeToggleModel()

	msg := tea.KeyMsg{Type: tea.KeyCtrlLeft}
	result, _ := m.Update(msg)
	model := result.(ToggleViewModel)

	if !model.showingProcessList {
		t.Error("expected to remain on process list")
	}
}

func TestToggleViewModel_FocusServerWithoutActiveProcess(t *testing.T) {
	m := makeToggleModel()

	msg := tea.KeyMsg{Type: tea.KeyCtrlRight}
	result, _ := m.Update(msg)
	model := result.(ToggleViewModel)

	// Should stay on process list because no process is selected
	if !model.showingProcessList {
		t.Error("expected to stay on process list when no process is active")
	}
}

func TestToggleViewModel_Resize(t *testing.T) {
	m := makeToggleModel()
	m.termWidth = 0
	m.termHeight = 0

	msg := tea.WindowSizeMsg{Width: 120, Height: 40}
	result, _ := m.Update(msg)
	model := result.(ToggleViewModel)

	if model.termWidth != 120 {
		t.Errorf("expected termWidth 120, got %d", model.termWidth)
	}
	if model.termHeight != 40 {
		t.Errorf("expected termHeight 40, got %d", model.termHeight)
	}
}

func TestToggleViewModel_ViewProcessList(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = true
	m.termWidth = 80
	m.termHeight = 24

	view := m.View()
	// Should contain the status bar with "process list"
	if !strings.Contains(view, "process list") {
		t.Errorf("expected view to contain 'process list', got:\n%s", view)
	}
}

func TestToggleViewModel_ViewScrollback(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = false
	m.termWidth = 80
	m.termHeight = 24
	m.scrollbackContent = "line1\nline2\nline3"

	view := m.View()
	if !strings.Contains(view, "scrollback") {
		t.Errorf("expected view to contain 'scrollback', got:\n%s", view)
	}
	if !strings.Contains(view, "line1") {
		t.Errorf("expected view to contain scrollback content, got:\n%s", view)
	}
}

func TestToggleViewModel_StatusBarHidden_SmallTerminal(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = true
	m.termWidth = 80
	m.termHeight = 2 // Too small for status bar

	bar := m.statusBar("process list")
	if bar != "" {
		t.Errorf("expected empty status bar for small terminal, got %q", bar)
	}
}

func TestToggleViewModel_StatusBarHidden_ZeroWidth(t *testing.T) {
	m := makeToggleModel()
	m.termWidth = 0
	m.termHeight = 24

	bar := m.statusBar("process list")
	if bar != "" {
		t.Errorf("expected empty status bar for zero width, got %q", bar)
	}
}

func TestTailLines(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		n        int
		expected string
	}{
		{
			name:     "fewer lines than n",
			input:    "a\nb\nc",
			n:        5,
			expected: "a\nb\nc",
		},
		{
			name:     "exact lines",
			input:    "a\nb\nc",
			n:        3,
			expected: "a\nb\nc",
		},
		{
			name:     "more lines than n",
			input:    "a\nb\nc\nd\ne",
			n:        2,
			expected: "d\ne",
		},
		{
			name:     "zero n",
			input:    "a\nb",
			n:        0,
			expected: "",
		},
		{
			name:     "negative n",
			input:    "a\nb",
			n:        -1,
			expected: "",
		},
		{
			name:     "empty string",
			input:    "",
			n:        5,
			expected: "",
		},
		{
			name:     "single line",
			input:    "hello",
			n:        1,
			expected: "hello",
		},
		{
			name:     "strips carriage returns",
			input:    "hello\r\nworld\r\n",
			n:        5,
			expected: "hello\nworld\n",
		},
		{
			name:     "strips CR and tails",
			input:    "a\r\nb\r\nc\r\nd\r\n",
			n:        2,
			expected: "d\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tailLines(tt.input, tt.n)
			if result != tt.expected {
				t.Errorf("tailLines(%q, %d) = %q, want %q", tt.input, tt.n, result, tt.expected)
			}
		})
	}
}

func TestToggleViewModel_PollReaderStopsWhenShowingProcessList(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = true

	result, cmd := m.pollReader()
	model := result.(ToggleViewModel)

	if !model.showingProcessList {
		t.Error("expected to remain on process list")
	}
	if cmd != nil {
		t.Error("expected nil cmd when showing process list")
	}
}

func TestToggleViewModel_PollReaderStopsWhenNilChannel(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = false
	m.readerChan = nil

	result, cmd := m.pollReader()
	model := result.(ToggleViewModel)

	if model.showingProcessList {
		t.Error("did not expect showingProcessList to change")
	}
	if cmd != nil {
		t.Error("expected nil cmd when readerChan is nil")
	}
}

func TestToggleViewModel_PollReaderDrainsChannel(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = false

	ch := make(chan []byte, 3)
	ch <- []byte("hello ")
	ch <- []byte("world")
	m.readerChan = ch

	result, cmd := m.pollReader()
	model := result.(ToggleViewModel)

	if model.scrollbackContent != "hello world" {
		t.Errorf("expected scrollback 'hello world', got %q", model.scrollbackContent)
	}
	if cmd == nil {
		t.Error("expected non-nil cmd to continue polling")
	}
}

func TestToggleViewModel_PollReaderHandlesClosedChannel(t *testing.T) {
	m := makeToggleModel()
	m.showingProcessList = false

	ch := make(chan []byte, 1)
	ch <- []byte("data")
	close(ch)
	m.readerChan = ch

	result, _ := m.pollReader()
	model := result.(ToggleViewModel)

	// Should have read the data, then detected channel close
	if !strings.Contains(model.scrollbackContent, "data") {
		t.Errorf("expected scrollback to contain 'data', got %q", model.scrollbackContent)
	}
	if model.readerChan != nil {
		t.Error("expected readerChan to be nil after channel close")
	}
}

func TestNewToggleViewModel_UsesExistingKeybindings(t *testing.T) {
	cfg := testToggleConfig()
	state := config.ProcTmuxConfig{
		FilePath:   "test.yaml",
		Keybinding: cfg.Keybinding,
		Procs:      cfg.Procs,
	}
	appState := makeAppState(&state)
	client := NewClientModel(nil, &appState)

	m := NewToggleViewModel(client, nil, cfg)

	// Verify it reuses the existing keybindings
	toggleKeys := m.keys.toggle.Keys()
	if len(toggleKeys) == 0 || toggleKeys[0] != "ctrl+w" {
		t.Errorf("expected toggle key to use ctrl+w, got %v", toggleKeys)
	}

	clientKeys := m.keys.client.Keys()
	if len(clientKeys) == 0 || clientKeys[0] != "ctrl+left" {
		t.Errorf("expected client key to use ctrl+left, got %v", clientKeys)
	}

	serverKeys := m.keys.server.Keys()
	if len(serverKeys) == 0 || serverKeys[0] != "ctrl+right" {
		t.Errorf("expected server key to use ctrl+right, got %v", serverKeys)
	}
}

// makeAppState creates a minimal AppState for testing.
func makeAppState(cfg *config.ProcTmuxConfig) domain.AppState {
	return domain.NewAppState(cfg)
}
