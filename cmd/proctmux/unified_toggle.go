package main

import (
	"fmt"
	"log"
	"sync"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/proctmux"
	"github.com/nick/proctmux/internal/protocol"
	"github.com/nick/proctmux/internal/tui"
)

// RunUnifiedToggle launches proctmux in unified-toggle mode: an in-process
// primary server combined with a Bubble Tea TUI that toggles between the
// process list and the selected process's scrollback output.
func RunUnifiedToggle(cfg *config.ProcTmuxConfig) error {
	log.SetPrefix("[UNIFIED-TOGGLE] ")

	// Create local IPC adapter (no real socket needed)
	localIPC := newLocalIPCServer()

	// Create primary server with stdin/viewer disabled (TUI manages both)
	primaryServer := proctmux.NewPrimaryServerWithOptions(cfg, localIPC, proctmux.PrimaryServerOptions{
		SkipStdinForwarder: true,
		SkipViewer:         true,
	})

	// Start the primary server with an empty socket path (localIPC ignores it)
	if err := primaryServer.Start(""); err != nil {
		return fmt.Errorf("start primary server: %w", err)
	}
	defer primaryServer.Stop()

	// Create local IPC client that talks directly to the primary server
	localClient := newLocalIPCClient(primaryServer, localIPC)

	// Build the TUI
	state := domain.NewAppState(cfg)
	clientModel := tui.NewClientModel(localClient, &state)

	pc := primaryServer.GetRawProcessController()
	model := tui.NewToggleViewModel(clientModel, pc, cfg)

	program := tea.NewProgram(model, bubbleTeaProgramOptions()...)
	if _, err := program.Run(); err != nil {
		return fmt.Errorf("unified-toggle program exited with error: %w", err)
	}

	return nil
}

// localIPCServer satisfies proctmux.IPCServerInterface but routes state
// broadcasts to an in-process channel instead of a Unix socket.
type localIPCServer struct {
	mu        sync.Mutex
	updatesCh chan domain.StateUpdate
	primary   interface {
		HandleCommand(action protocol.Command, label string) error
		GetState() *domain.AppState
		GetProcessController() domain.ProcessController
	}
}

func newLocalIPCServer() *localIPCServer {
	return &localIPCServer{
		updatesCh: make(chan domain.StateUpdate, 10),
	}
}

func (s *localIPCServer) Start(_ string) error { return nil }

func (s *localIPCServer) SetPrimaryServer(primary interface {
	HandleCommand(action protocol.Command, label string) error
	GetState() *domain.AppState
	GetProcessController() domain.ProcessController
}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.primary = primary
}

func (s *localIPCServer) BroadcastState(state *domain.AppState, pc domain.ProcessController) {
	// Build process views the same way the real IPC server does
	views := make([]domain.ProcessView, len(state.Processes))
	for i := range state.Processes {
		views[i] = state.Processes[i].ToView(pc)
	}
	upd := domain.StateUpdate{State: state, ProcessViews: views}
	select {
	case s.updatesCh <- upd:
	default:
		// Channel full, drop oldest and push new
		select {
		case <-s.updatesCh:
		default:
		}
		select {
		case s.updatesCh <- upd:
		default:
		}
	}
}

func (s *localIPCServer) Stop() {}

// localIPCClient satisfies tui.IPCClient by calling the PrimaryServer directly.
type localIPCClient struct {
	server    *proctmux.PrimaryServer
	updatesCh <-chan domain.StateUpdate
}

func newLocalIPCClient(server *proctmux.PrimaryServer, ipcServer *localIPCServer) *localIPCClient {
	return &localIPCClient{
		server:    server,
		updatesCh: ipcServer.updatesCh,
	}
}

func (c *localIPCClient) ReceiveUpdates() <-chan domain.StateUpdate {
	return c.updatesCh
}

func (c *localIPCClient) SwitchProcess(label string) error {
	return c.server.HandleCommand(protocol.CommandSwitch, label)
}

func (c *localIPCClient) StartProcess(label string) error {
	return c.server.HandleCommand(protocol.CommandStart, label)
}

func (c *localIPCClient) StopProcess(label string) error {
	return c.server.HandleCommand(protocol.CommandStop, label)
}

func (c *localIPCClient) StopRunning() error {
	// Stop all running processes
	state := c.server.GetState()
	pc := c.server.GetProcessController()
	for i := range state.Processes {
		p := &state.Processes[i]
		view := p.ToView(pc)
		if view.Status == domain.StatusRunning {
			if err := c.server.HandleCommand(protocol.CommandStop, view.Label); err != nil {
				log.Printf("failed to stop process %s: %v", view.Label, err)
			}
		}
	}
	return nil
}

func (c *localIPCClient) RestartProcess(label string) error {
	return c.server.HandleCommand(protocol.CommandRestart, label)
}
