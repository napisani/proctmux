package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/creack/pty"

	"github.com/nick/proctmux/internal/buffer"
	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
	"github.com/nick/proctmux/internal/ipc"
	"github.com/nick/proctmux/internal/process"
	"github.com/nick/proctmux/internal/proctmux"
	"github.com/nick/proctmux/internal/viewer"
)

const (
	// ctrlW is the toggle key intercepted exclusively by the coordinator.
	ctrlW = 0x17
)

// RunUnifiedToggle launches proctmux in unified-toggle mode:
//
//   - The coordinator runs the PrimaryServer in-process (real IPC socket, viewer
//     active, stdin forwarder disabled).
//   - A child `proctmux --client` process is spawned in a real PTY so it can
//     render its full Bubble Tea TUI.
//   - The coordinator owns the user's terminal in raw mode and routes stdin to
//     either the client PTY or the active process PTY depending on which pane
//     is showing.
//   - ctrl+w is intercepted by the coordinator to toggle between the two panes;
//     it is never forwarded to any child.
func RunUnifiedToggle(cfg *config.ProcTmuxConfig) error {
	log.SetPrefix("[TOGGLE] ")

	// 1. Create and start the PrimaryServer (viewer active, stdin managed here).
	ipcServer := ipc.NewServer()
	primaryServer := proctmux.NewPrimaryServerWithOptions(cfg, ipcServer, proctmux.PrimaryServerOptions{
		SkipStdinForwarder: true,
		SkipViewer:         true,
	})

	socketPath, err := ipc.CreateSocket(cfg)
	if err != nil {
		return fmt.Errorf("create socket: %w", err)
	}

	if err := primaryServer.Start(socketPath); err != nil {
		return fmt.Errorf("start primary server: %w", err)
	}
	defer primaryServer.Stop()

	// 2. Spawn `proctmux --client -f <cfg>` in a PTY.
	// Pass socketPath so the child skips probeSocket and connects directly.
	clientPTY, clientCmd, err := spawnClientPTY(cfg, socketPath)
	if err != nil {
		return fmt.Errorf("spawn client: %w", err)
	}
	defer func() {
		clientPTY.Close()
		if clientCmd.Process != nil {
			clientCmd.Process.Kill() //nolint:errcheck
		}
		clientCmd.Wait() //nolint:errcheck
	}()

	// 3. Capture client PTY output into a ring buffer (for scrollback on re-entry).
	clientRing := buffer.NewRingBuffer(1 * 1024 * 1024) // 1 MB
	go func() {
		if _, err := io.Copy(clientRing, clientPTY); err != nil {
			log.Printf("client PTY copy ended: %v", err)
		}
	}()

	// 4. Connect the coordinator's own IPC client directly.
	// The primary server was started in-process above, so the socket is
	// already listening. We connect directly without WaitForSocket/probeSocket:
	// probeSocket opens a real connection that the server immediately tries to
	// send initial state to — that state message would be wasted on the probe
	// and never reach the child --client TUI, leaving it showing "No processes".
	ipcClient, err := ipc.NewClient(socketPath)
	if err != nil {
		return fmt.Errorf("connect to primary: %w", err)
	}
	defer ipcClient.Close()

	// 5. Put the user's terminal into raw mode.
	origTermState, err := process.MakeRawInput(int(os.Stdin.Fd()))
	if err != nil {
		return fmt.Errorf("set terminal raw mode: %w", err)
	}
	defer func() {
		if restoreErr := process.RestoreTerminal(int(os.Stdin.Fd()), origTermState); restoreErr != nil {
			log.Printf("restore terminal: %v", restoreErr)
		}
	}()

	// Forward SIGWINCH (terminal resize) to the client PTY.
	sigwinchCh := make(chan os.Signal, 1)
	signal.Notify(sigwinchCh, syscall.SIGWINCH)
	go func() {
		for range sigwinchCh {
			if sz, err := pty.GetsizeFull(os.Stdin); err == nil {
				pty.Setsize(clientPTY, sz) //nolint:errcheck
			}
		}
	}()
	defer signal.Stop(sigwinchCh)

	// 6. Run the toggle relay loop.
	relay := newToggleRelay(primaryServer, clientPTY, clientRing, ipcClient.ReceiveUpdates())
	return relay.run()
}

// spawnClientPTY starts `proctmux --client -f <cfg>` inside a PTY and returns
// the master PTY file and the running Cmd.
//
// socketPath is passed via the PROCTMUX_SOCKET environment variable so the
// child can connect directly without probing the socket. Probing creates a
// spurious short-lived connection that causes the IPC server to waste the
// initial-state write on the probe rather than the real client connection.
func spawnClientPTY(cfg *config.ProcTmuxConfig, socketPath string) (*os.File, *exec.Cmd, error) {
	executable := os.Args[0]
	args := []string{"--client"}
	if cfg.FilePath != "" {
		args = append(args, "-f", cfg.FilePath)
	}

	cmd := exec.Command(executable, args...)
	env := os.Environ()
	// Inject socket path so the child skips probeSocket and connects directly.
	env = append(env, proctmuxSocketEnv+"="+socketPath)
	cmd.Env = env
	if cwd, err := os.Getwd(); err == nil {
		cmd.Dir = cwd
	}

	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, nil, fmt.Errorf("pty.Start: %w", err)
	}

	// Match initial PTY size to the current terminal.
	if sz, err := pty.GetsizeFull(os.Stdin); err == nil {
		pty.Setsize(ptmx, sz) //nolint:errcheck
	}

	return ptmx, cmd, nil
}

// toggleRelay is the coordinator's main event loop. It owns the user's stdin
// in raw mode and routes bytes to either the client PTY or the active process PTY.
type toggleRelay struct {
	pc           *process.Controller // for writing stdin to the active process
	v            *viewer.Viewer      // process output viewer
	clientPTY    *os.File
	clientRing   *buffer.RingBuffer
	ipcUpdates   <-chan domain.StateUpdate
	activeProcID int  // last known selected process ID from IPC state updates
	inClientPane bool // true = showing client TUI, false = showing process pane

	// clientRelayStop is closed to signal the relay goroutine to stop.
	// clientRelayDone is closed by the relay goroutine once it has fully exited.
	// Both are nil when no relay is running. stopClientRelay() waits on Done
	// before returning, guaranteeing no further writes to stdout after the call.
	clientRelayStop chan struct{}
	clientRelayDone chan struct{}
}

func newToggleRelay(
	ps *proctmux.PrimaryServer,
	clientPTY *os.File,
	clientRing *buffer.RingBuffer,
	ipcUpdates <-chan domain.StateUpdate,
) *toggleRelay {
	return &toggleRelay{
		pc:         ps.GetRawProcessController(),
		v:          ps.GetViewer(),
		clientPTY:  clientPTY,
		clientRing: clientRing,
		ipcUpdates: ipcUpdates,
	}
}

// run is the blocking event loop. It returns when stdin closes or errors.
func (r *toggleRelay) run() error {
	// Start in the client pane.
	r.switchToClientPane()

	// Read raw stdin in a goroutine; send bytes over a channel.
	type stdinChunk struct {
		data []byte
		err  error
	}
	stdinCh := make(chan stdinChunk, 32)
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buf)
			chunk := stdinChunk{err: err}
			if n > 0 {
				chunk.data = make([]byte, n)
				copy(chunk.data, buf[:n])
			}
			stdinCh <- chunk
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case upd := <-r.ipcUpdates:
			r.handleStateUpdate(upd)

		case chunk := <-stdinCh:
			if chunk.err != nil {
				log.Printf("stdin read error: %v", chunk.err)
				return chunk.err
			}
			if err := r.handleStdin(chunk.data); err != nil {
				return err
			}
		}
	}
}

// handleStateUpdate tracks the currently selected process ID. When in process
// pane it immediately switches the viewer if the selected process changed.
//
// If the primary server has not yet received a switch command (CurrentProcID ==
// 0), we fall back to the first process in the view list so that ctrl+w always
// has a process to show — mirroring the behaviour of the original in-process
// toggle model which auto-selected the first process.
func (r *toggleRelay) handleStateUpdate(upd domain.StateUpdate) {
	if upd.State == nil {
		return
	}
	newID := upd.State.CurrentProcID
	// If the server hasn't selected a process yet, default to the first one.
	if newID == 0 && len(upd.ProcessViews) > 0 {
		newID = upd.ProcessViews[0].ID
	}
	if newID == r.activeProcID {
		return
	}
	r.activeProcID = newID
	if !r.inClientPane && r.v != nil && newID > 0 {
		log.Printf("active proc changed to %d, refreshing viewer", newID)
		if err := r.v.SwitchToProcess(newID); err != nil {
			log.Printf("viewer.SwitchToProcess(%d): %v", newID, err)
		}
	}
}

// handleStdin processes a raw stdin chunk, intercepting ctrl+w and routing
// the rest to the appropriate destination.
func (r *toggleRelay) handleStdin(data []byte) error {
	for i, b := range data {
		if b == ctrlW {
			// Forward everything before ctrl+w, then toggle.
			if i > 0 {
				if err := r.forwardStdin(data[:i]); err != nil {
					return err
				}
			}
			r.toggle()
			// Continue with any bytes after ctrl+w.
			if i+1 < len(data) {
				return r.handleStdin(data[i+1:])
			}
			return nil
		}
	}
	return r.forwardStdin(data)
}

// forwardStdin sends bytes to the appropriate PTY.
func (r *toggleRelay) forwardStdin(data []byte) error {
	if r.inClientPane {
		_, err := r.clientPTY.Write(data)
		return err
	}
	return r.writeToActiveProcess(data)
}

// writeToActiveProcess sends bytes to the currently active process PTY.
func (r *toggleRelay) writeToActiveProcess(data []byte) error {
	if r.pc == nil || r.activeProcID <= 0 {
		return nil
	}
	w, err := r.pc.GetWriter(r.activeProcID)
	if err != nil {
		return nil // process may have exited; swallow
	}
	_, err = w.Write(data)
	return err
}

// toggle switches between client pane and process pane.
func (r *toggleRelay) toggle() {
	if r.inClientPane {
		r.switchToProcessPane()
	} else {
		r.switchToClientPane()
	}
}

// stopClientRelay signals the client relay goroutine to stop and blocks until
// it has fully exited. Safe to call when no relay is running (no-op).
// After this returns, no further client TUI bytes will be written to stdout.
func (r *toggleRelay) stopClientRelay() {
	if r.clientRelayStop == nil {
		return
	}
	close(r.clientRelayStop)
	<-r.clientRelayDone // wait for the goroutine to fully exit
	r.clientRelayStop = nil
	r.clientRelayDone = nil
}

// switchToClientPane stops the process viewer relay and starts showing the
// client TUI: dump the ring buffer to stdout then relay live output.
func (r *toggleRelay) switchToClientPane() {
	// Stop any previous client relay goroutine and wait for it to fully exit
	// before touching stdout. This prevents a race where the old goroutine
	// writes a final client TUI frame after we've already started showing
	// process output (or after we've cleared the screen).
	r.stopClientRelay()

	r.inClientPane = true
	log.Printf("switching to client pane")

	// Stop the viewer relay for process output (SwitchToProcess(0) = suspend/clear).
	// SwitchToProcess already waits internally for its relay goroutine to exit
	// before writing to stdout, so no process bytes can follow after this returns.
	if r.v != nil {
		if err := r.v.SwitchToProcess(0); err != nil {
			log.Printf("viewer.SwitchToProcess(0): %v", err)
		}
	}

	// Clear the screen so the terminal is in a known state before the client
	// TUI re-renders. Cursor-relative move sequences in the client renders
	// land at wrong positions when returning from the process pane (which
	// left the cursor elsewhere). The clear gives us a clean slate.
	os.Stdout.Write([]byte("\033[2J\033[H")) //nolint:errcheck

	// Atomically snapshot the ring buffer and subscribe so we don't miss bytes.
	_, readerID, liveCh := r.clientRing.SnapshotAndSubscribe()

	stop := make(chan struct{})
	done := make(chan struct{})
	r.clientRelayStop = stop
	r.clientRelayDone = done
	go func() {
		defer close(done) // signal exit before RemoveReader so stopClientRelay unblocks first
		defer r.clientRing.RemoveReader(readerID)
		for {
			// Check stop first with a non-blocking select so a pending stop
			// signal always takes priority over buffered data in liveCh.
			select {
			case <-stop:
				return
			default:
			}
			select {
			case <-stop:
				return
			case data, ok := <-liveCh:
				if !ok {
					return
				}
				os.Stdout.Write(data) //nolint:errcheck
			}
		}
	}()

	// Force the child to re-render by sending a fake resize sequence.
	// We momentarily bump the column count by one then restore it to guarantee
	// SIGWINCH is delivered even if the size hasn't changed since last time.
	// This is done AFTER starting the relay goroutine so the re-render output
	// arrives on liveCh while the goroutine is already listening.
	if sz, err := pty.GetsizeFull(os.Stdin); err == nil {
		bump := *sz
		bump.Cols++
		pty.Setsize(r.clientPTY, &bump) //nolint:errcheck
		pty.Setsize(r.clientPTY, sz)    //nolint:errcheck
	}
}

// switchToProcessPane suspends the client relay and switches the viewer to the
// active process.
func (r *toggleRelay) switchToProcessPane() {
	procID := r.activeProcID
	if procID <= 0 {
		// No process selected; stay on client pane.
		log.Printf("no active process, staying on client pane")
		return
	}

	// Stop the client relay goroutine and wait for it to fully exit before
	// touching stdout. Without the wait, the goroutine's in-flight select
	// could pick a buffered liveCh send over the stop signal and write
	// client TUI bytes after we've cleared the screen.
	r.stopClientRelay()

	r.inClientPane = false
	log.Printf("switching to process pane (active proc %d)", procID)

	// Clear the screen immediately so the user never sees the old client TUI
	// frame while the viewer is setting up. The viewer will clear again as
	// part of its atomic scrollback write, but this ensures a clean slate
	// even if the viewer is slow or the process lookup fails.
	os.Stdout.Write([]byte("\033[2J\033[H")) //nolint:errcheck

	if r.v != nil {
		if err := r.v.SwitchToProcess(procID); err != nil {
			log.Printf("viewer.SwitchToProcess(%d): %v", procID, err)
			// Fall back to client pane on error.
			r.inClientPane = true
			r.switchToClientPane()
		}
	}
}
