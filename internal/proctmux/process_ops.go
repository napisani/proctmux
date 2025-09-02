package proctmux

import (
	"log"
	"os"
	"syscall"
)

func killPane(state *AppState, process *Process) (*AppState, error) {
	if process == nil || process.PaneID == "" {
		return state, nil
	}

	newState := NewStateMutation(state).
		SetProcessPaneID("", process.ID).
		Commit()
	if err := KillPane(process.PaneID); err != nil {
		// if there is an error, log it but continue because its likely because the pane is already dead
		log.Printf("Error killing pane %s for process %s: %v", process.PaneID, process.Label, err)
	}
	return newState, nil
}

func startProcess(state *AppState, tmuxContext *TmuxContext, process *Process) (*AppState, error) {
	isSameProc := process.ID == state.CurrentProcID
	if process.Status != StatusHalted {
		return state, nil
	}

	log.Printf("current process log before start: %+v", process)

	var newPane string
	var errPane error
	if isSameProc {
		log.Printf("Starting process %s in new attached pane, current process id %d", process.Label, process.ID)
		newPane, errPane = tmuxContext.CreatePane(process)
	} else {
		log.Printf("Starting process %s in new detached pane, current process id %d", process.Label, process.ID)
		newPane, errPane = tmuxContext.CreateDetachedPane(process)
	}

	if errPane != nil {
		log.Printf("Error creating pane for process %s: %v", process.Label, errPane)
		return nil, errPane
	}

	pid, pidErr := tmuxContext.GetPanePID(newPane)
	if pidErr != nil {
		log.Printf("Error getting PID for process %s: %v", process.Label, pidErr)
		return nil, pidErr
	}
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
	if signal == 0 {
		signal = 15 // Default to SIGTERM if not specified
	}

	osProcess, err := os.FindProcess(process.PID)
	if err != nil {
		log.Printf("Failed to find process: %v\n", err)
		return nil, err
	}

	err = osProcess.Signal(syscall.Signal(signal))
	if err != nil {
		if err.Error() == "os: process already finished" {
			log.Printf("Process %s with PID %d has already exited", process.Label, process.PID)
			newState := NewStateMutation(state).
				SetProcessStatus(StatusHalted, process.ID).
				Commit()

			return newState, nil
		}

		log.Printf("Failed to send signal: %v\n", err)
		return nil, err
	}
	log.Printf("Sent signal %d to process %s with PID %d", signal, process.Label, process.PID)
	newState := NewStateMutation(state).
		SetProcessStatus(StatusHalting, process.ID).
		Commit()

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
