package viewer

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
)

// ProcessServer interface defines what the viewer needs from a process server
type ProcessServer interface {
	GetProcess(id int) (ProcessInstance, error)
}

// ProcessInstance interface defines what the viewer needs from a process instance
type ProcessInstance interface {
	GetPID() int
	Scrollback() ScrollbackBuffer
}

// ScrollbackBuffer interface defines what the viewer needs from a scrollback buffer
type ScrollbackBuffer interface {
	Bytes() []byte
	NewReader() (int, <-chan []byte)
	RemoveReader(id int)
}

// ServerAdapter adapts a concrete process server to the ProcessServer interface
type ServerAdapter struct {
	getProcess func(id int) (ProcessInstance, error)
}

func (a *ServerAdapter) GetProcess(id int) (ProcessInstance, error) {
	return a.getProcess(id)
}

// NewServerAdapter creates an adapter for any type that can get process instances
func NewServerAdapter(getProcess func(id int) (ProcessInstance, error)) *ServerAdapter {
	return &ServerAdapter{getProcess: getProcess}
}

// Viewer is a simple output relay for viewing process output.
// Unlike the old TTYViewer/ViewerModel bubbletea implementation, this viewer
// has a single job: relay process output to stdout.
//
// When a process is switched (via SwitchToProcess):
// 1. Stop copying output from the previous process
// 2. Clear stdout (ESC[2J ESC[H)
// 3. Write the new process's scrollback buffer to stdout
// 4. Start copying the new process's live output to stdout
//
// The viewer is integrated with MasterServer and automatically switches
// when HandleSelection or HandleCommand("switch") is called.
//
// Architecture:
// The viewer uses the ring buffer as the single source of truth.
// - On switch: displays historical data via Bytes()
// - For live updates: subscribes to NewReader() to get new writes
// This avoids competing with ProcessServer's io.Copy for PTY reads.
//
// Example usage:
//
//	viewer := viewer.New(server)
//
//	// Switch viewer to display the process
//	viewer.SwitchToProcess(1)
//
//	// Output will now stream to stdout until another process is switched
type Viewer struct {
	processServer        ProcessServer
	interruptOutputRelay chan struct{}
	currentProcessID     int
	currentReaderID      int           // ID for removing reader from ring buffer
	copyDone             chan struct{} // Signals when copyProcessOutput has fully exited
	mu                   sync.Mutex
	placeholder          string
}

func New(server ProcessServer) *Viewer {
	return &Viewer{
		processServer: server,
	}
}

// SetPlaceholder configures the placeholder text to display when no process is selected.
func (v *Viewer) SetPlaceholder(text string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.placeholder = text
}

// ShowPlaceholder clears the screen and renders the placeholder banner immediately.
func (v *Viewer) ShowPlaceholder() {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.clearScreen()
	v.printPlaceholderLocked()
}

// SwitchToProcess switches the viewer to display a different process.
// This is called by the process server or controller when the user switches processes.
// It will:
// 1. Stop copying output from the previous process
// 2. Clear stdout
// 3. Write the new process's scrollback buffer to stdout
// 4. Start copying the new process's output to stdout
func (v *Viewer) SwitchToProcess(processID int) error {
	return v.switchToProcess(processID, false)
}

// RefreshCurrentProcess forces a refresh of the currently viewed process.
// This is useful when a process is restarted and we want to show its output from the beginning.
func (v *Viewer) RefreshCurrentProcess() error {
	v.mu.Lock()
	currentID := v.currentProcessID
	v.mu.Unlock()

	if currentID == 0 {
		return nil
	}

	return v.switchToProcess(currentID, true)
}

// switchToProcess is the internal implementation that handles both switching and refreshing.
// If force is true, it will refresh even if already viewing the same process.
func (v *Viewer) switchToProcess(processID int, force bool) error {
	v.mu.Lock()
	defer v.mu.Unlock()

	// If already viewing this process and not forcing refresh, do nothing
	if v.currentProcessID == processID && !force {
		return nil
	}

	// Stop copying from the previous process and wait for it to fully exit
	if v.interruptOutputRelay != nil {
		close(v.interruptOutputRelay)
		// Wait for the copyProcessOutput goroutine to fully exit
		// This ensures no stray output is written to stdout after we clear the screen
		if v.copyDone != nil {
			<-v.copyDone
		}
		v.interruptOutputRelay = nil
		v.copyDone = nil
	}

	// Remove reader from the previous process's ring buffer
	if v.currentProcessID != 0 && v.currentReaderID != 0 {
		if prevInstance, err := v.processServer.GetProcess(v.currentProcessID); err == nil && prevInstance != nil {
			prevInstance.Scrollback().RemoveReader(v.currentReaderID)
		}
		v.currentReaderID = 0
	}

	v.currentProcessID = processID

	// Clear stdout before showing new process output
	v.clearScreen()

	// If switching to no process (ID 0), just clear and stop
	if processID == 0 {
		v.printPlaceholderLocked()
		return nil
	}

	// Get the process instance
	instance, err := v.processServer.GetProcess(processID)
	if err != nil {
		log.Printf("Failed to get process %d: %v", processID, err)
		return nil
	}
	if instance == nil {
		log.Printf("Process instance %d is nil", processID)
		return nil
	}

	// Write the current scrollback buffer to stdout
	scrollback := instance.Scrollback().Bytes()
	fmt.Printf("----- Showing scrollback for process %d (PID: %d) -----\n", processID, instance.GetPID())
	if len(scrollback) > 0 {
		if _, err := os.Stdout.Write(scrollback); err != nil {
			log.Printf("Warning: failed to write scrollback for process %d: %v", processID, err)
		}
	}

	// Subscribe to the ring buffer to receive live output
	readerID, outputChan := instance.Scrollback().NewReader()
	v.currentReaderID = readerID

	// Start relaying output from the new process
	v.interruptOutputRelay = make(chan struct{})
	v.copyDone = make(chan struct{})
	go v.copyProcessOutput(outputChan, v.interruptOutputRelay, v.copyDone)

	log.Printf("Switched viewer to process %d (PID: %d), reader ID: %d", processID, instance.GetPID(), readerID)
	return nil
}

// copyProcessOutput copies output from a ring buffer reader channel to stdout until cancelled
func (v *Viewer) copyProcessOutput(outputChan <-chan []byte, cancel chan struct{}, done chan struct{}) {
	defer close(done) // Signal that we've fully exited

	processID := v.currentProcessID // Capture for logging

	for {
		select {
		case <-cancel:
			log.Printf("Stopped output relay for process %d (switched away)", processID)
			return
		case data, ok := <-outputChan:
			if !ok {
				// Channel closed, process exited
				log.Printf("Process %d output stream ended (channel closed)", processID)
				return
			}
			// Write to stdout
			if _, err := os.Stdout.Write(data); err != nil {
				log.Printf("Error writing output from process %d: %v", processID, err)
				return
			}
		}
	}
}

// clearScreen clears the terminal screen and moves cursor to top-left
func (v *Viewer) clearScreen() {
	// ANSI escape sequence: ESC[2J clears screen, ESC[H moves cursor to home
	fmt.Print("\033[2J\033[H")
}

func (v *Viewer) printPlaceholderLocked() {
	text := strings.TrimSpace(v.placeholder)
	if text == "" {
		fmt.Println("Select a process to stream output.")
		return
	}
	fmt.Println(text)
}

// GetCurrentProcessID returns the ID of the process currently being viewed
func (v *Viewer) GetCurrentProcessID() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.currentProcessID
}
