package proctmux

import (
	"log"
	"os"
	"syscall"
	"time"
)

func killPane(state *AppState, process *Process) (*AppState, error) {
	if process == nil || process.PaneID == "" {
		return state, nil
	}

	if err := KillPane(process.PaneID); err != nil {
		// if there is an error, log it but continue because it's likely because the pane is already dead
		log.Printf("Error killing pane %s for process %s: %v", process.PaneID, process.Label, err)
	}

	newState := NewStateMutation(state).
		SetProcessPaneID("", process.ID).
		Commit()
	return newState, nil
}

func startProcess(state *AppState, tmuxContext *TmuxContext, process *Process, inDetachedSession bool) (*AppState, error) {
	if process.Status != StatusHalted {
		return state, nil
	}

	log.Printf("current process log before start: %+v", process)

	log.Printf("Starting process %s in new detached pane, current process id %d", process.Label, process.ID)
	var newPane string
	var pid int
	var errPane error

	if inDetachedSession {
		newPane, pid, errPane = tmuxContext.CreateDetachedPane(process)
	} else {
		newPane, pid, errPane = tmuxContext.CreatePane(process)
	}

	if errPane != nil {
		log.Printf("Error creating pane for process %s: %v", process.Label, errPane)
		return state, errPane
	}

	log.Printf("Created new pane %s for process %s, process id %d", newPane, process.Label, process.ID)
	log.Printf("Started process %s with PID %d in pane %s", process.Label, pid, newPane)

	newState := NewStateMutation(state).
		SetProcessStatus(StatusRunning, process.ID).
		SetProcessPaneID(newPane, process.ID).
		SetProcessPID(pid, process.ID).
		Commit()
	return newState, nil

}

func focusActivePane(state *AppState, tmuxContext *TmuxContext) error {
	currentProcess := state.GetCurrentProcess()
	if currentProcess == nil {
		log.Println("No current process to focus")
		return nil
	}
	return tmuxContext.FocusPane(currentProcess.PaneID)
}

func haltAllProcesses(state *AppState) (*AppState, error) {
	accState := state
	for _, process := range state.Processes {
		if process.Status == StatusRunning {
			newState, err := haltProcess(accState, &process)
			if err != nil {
				log.Printf("Error halting process %s: %v", process.Label, err)
			}
			if newState != nil {
				accState = newState
			}
		}
	}
	return accState, nil
}

func haltProcess(state *AppState, process *Process) (*AppState, error) {
	if process.Status != StatusRunning {
		log.Printf("Process %s is not running, cannot halt", process.Label)
		return state, nil
	}

	if process.PID <= 0 {
		log.Printf("Process %s has no valid PID to halt", process.Label)
		return state, nil
	}

	signal := process.Config.Stop
	useDefaultKillRoutine := false
	if signal == 0 {
		signal = 15 // Default to SIGTERM if not specified
		useDefaultKillRoutine = true
	}

	osProcess, err := os.FindProcess(process.PID)
	if err != nil {
		log.Printf("Failed to find process: %v\n", err)
		return nil, err
	}

	// Send the specified signal to the process
	err = osProcess.Signal(syscall.Signal(signal))
	if err != nil {
		if err.Error() == "os: process already finished" {
			log.Printf("Process %s with PID %d has already exited", process.Label, process.PID)
			// no need to update state here, when the process exit the reaper will catch it and update the state
			return state, nil
		}

		log.Printf("Failed to send signal: %v\n", err)
		return nil, err
	}
	log.Printf("Sent signal %d to process %s with PID %d", signal, process.Label, process.PID)
	newState := NewStateMutation(state).
		SetProcessStatus(StatusHalting, process.ID).
		Commit()

	// If we sent SIGTERM (15), wait for process to die and send SIGKILL (9) if needed
	if useDefaultKillRoutine {
		go func() {
			killPid := osProcess.Pid
			// Wait for 3 seconds
			time.Sleep(3 * time.Second)

			// Check if process still exists
			osProcess, err := os.FindProcess(killPid)
			if err != nil {
				// Process probably doesn't exist anymore
				return
			}

			// Try to send signal 0 to see if process is still running
			err = osProcess.Signal(syscall.Signal(0))
			if err != nil {
				// Process is gone or we can't signal it
				return
			}

			// Process still running, send SIGKILL
			log.Printf("Process %s with PID %d did not terminate after 3 seconds, sending SIGKILL", process.Label, killPid)
			err = osProcess.Signal(syscall.SIGKILL)
			if err != nil {
				log.Printf("Failed to send SIGKILL to process %s: %v", process.Label, err)
			} else {
				log.Printf("Sent SIGKILL to process %s with PID %d", process.Label, process.PID)
			}
		}()
	}

	return newState, nil
}

func setProcessTerminated(state *AppState, process *Process) (*AppState, error) {
	if process == nil {
		log.Println("No process found for PID termination")
		return state, nil
	}

	if process.Status == StatusHalted {
		return state, nil
	}

	log.Printf("Process %s with PID %d has exited", process.Label, process.PID)
	newState := NewStateMutation(state).
		SetProcessStatus(StatusHalted, process.ID).
		SetProcessPID(-1, process.ID).
		Commit()

	return newState, nil
}
