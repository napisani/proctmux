package proctmux

import (
	"fmt"
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
// Architecture:
// The viewer subscribes to the process's BroadcastWriter to receive live output.
// This avoids competing with the ProcessServer's io.Copy for PTY reads.
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
	currentSubscriberID  int           // ID for unsubscribing from broadcast
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

	// Unsubscribe from the previous process's broadcast
	if v.currentProcessID != 0 && v.currentSubscriberID != 0 {
		if prevInstance, err := v.processServer.GetProcess(v.currentProcessID); err == nil && prevInstance != nil {
			prevInstance.Broadcast.Unsubscribe(v.currentSubscriberID)
		}
		v.currentSubscriberID = 0
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

	// Subscribe to the process's broadcast to receive live output
	subscriberID, outputChan := instance.Broadcast.Subscribe()
	v.currentSubscriberID = subscriberID

	// Start relaying output from the new process
	v.interruptOutputRelay = make(chan struct{})
	v.copyDone = make(chan struct{})
	go v.copyProcessOutput(outputChan, v.interruptOutputRelay, v.copyDone)

	log.Printf("Switched viewer to process %d (PID: %d), subscriber ID: %d", processID, instance.GetPID(), subscriberID)
	return nil
}

// copyProcessOutput copies output from a process broadcast channel to stdout until cancelled
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

// GetCurrentProcessID returns the ID of the process currently being viewed
func (v *Viewer) GetCurrentProcessID() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.currentProcessID
}
