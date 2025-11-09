package proctmux

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
)

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
// Example usage:
//
//	server := NewProcessServer()
//	viewer := NewViewer(server)
//
//	// Start a process
//	instance, _ := server.StartProcess(1, &config)
//
//	// Switch viewer to display the process
//	viewer.SwitchToProcess(1)
//
//	// Output will now stream to stdout until another process is switched
type Viewer struct {
	processServer        *ProcessServer
	interruptOutputRelay chan struct{}
	currentProcessID     int
	copyDone             chan struct{} // Signals when copyProcessOutput has fully exited
	mu                   sync.Mutex
}

func NewViewer(server *ProcessServer) *Viewer {
	return &Viewer{
		processServer: server,
	}
}

// SwitchToProcess switches the viewer to display a different process.
// This is called by the process server or controller when the user switches processes.
// It will:
// 1. Stop copying output from the previous process
// 2. Clear stdout
// 3. Write the new process's scrollback buffer to stdout
// 4. Start copying the new process's output to stdout
func (v *Viewer) SwitchToProcess(processID int) error {
	v.mu.Lock()
	defer v.mu.Unlock()

	// If already viewing this process, do nothing
	if v.currentProcessID == processID {
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

	v.currentProcessID = processID

	// Clear stdout before showing new process output
	v.clearScreen()

	// If switching to no process (ID 0), just clear and stop
	if processID == 0 {
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
	scrollback := instance.Scrollback.Bytes()
	fmt.Printf("----- Showing scrollback for process %d (PID: %d) -----\n", processID, instance.GetPID())
	if len(scrollback) > 0 {
		if _, err := os.Stdout.Write(scrollback); err != nil {
			log.Printf("Warning: failed to write scrollback for process %d: %v", processID, err)
		}
	}

	// Start relaying output from the new process
	v.interruptOutputRelay = make(chan struct{})
	v.copyDone = make(chan struct{})
	go v.copyProcessOutput(instance, v.interruptOutputRelay, v.copyDone)

	log.Printf("Switched viewer to process %d (PID: %d)", processID, instance.GetPID())
	return nil
}

// copyProcessOutput copies output from a process PTY to stdout until cancelled
func (v *Viewer) copyProcessOutput(instance *ProcessInstance, cancel chan struct{}, done chan struct{}) {
	defer close(done) // Signal that we've fully exited

	// Create a cancelable reader that wraps the PTY file
	reader := &cancelableReader{
		reader: instance.File,
		cancel: cancel,
	}

	// Copy from PTY to stdout until cancelled or process exits
	_, err := io.Copy(os.Stdout, reader)

	// Check if we were cancelled or if there was an error
	select {
	case <-cancel:
		log.Printf("Stopped output relay for process %d (switched away)", instance.ID)
	default:
		if err != nil && err != io.EOF {
			log.Printf("Error copying output from process %d: %v", instance.ID, err)
		} else {
			log.Printf("Process %d output stream ended", instance.ID)
		}
	}
}

// clearScreen clears the terminal screen and moves cursor to top-left
func (v *Viewer) clearScreen() {
	// ANSI escape sequence: ESC[2J clears screen, ESC[H moves cursor to home
	fmt.Print("\033[2J\033[H")
}

// cancelableReader wraps an io.Reader and allows cancellation via a channel
type cancelableReader struct {
	reader io.Reader
	cancel chan struct{}
}

func (r *cancelableReader) Read(p []byte) (n int, err error) {
	// Check if cancelled before reading
	select {
	case <-r.cancel:
		return 0, io.EOF
	default:
	}

	// Read from underlying reader
	n, err = r.reader.Read(p)

	// Check if cancelled after reading
	// If cancelled, discard the data we just read by returning 0 bytes
	// This prevents io.Copy from writing stray data to stdout after cancellation
	select {
	case <-r.cancel:
		return 0, io.EOF
	default:
		return n, err
	}
}

// GetCurrentProcessID returns the ID of the process currently being viewed
func (v *Viewer) GetCurrentProcessID() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.currentProcessID
}
