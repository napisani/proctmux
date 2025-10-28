package proctmux

import "fmt"

// StateMutation represents a series of mutations to apply to an AppState
type StateMutation struct {
	initState *AppState
}

// NewStateMutation creates a new mutation from the current state
func NewStateMutation(state *AppState) *StateMutation {
	// Mutate the provided state in-place so model and controller stay in sync
	return &StateMutation{initState: state}
}

// Commit returns the modified state
func (m *StateMutation) Commit() *AppState { return m.initState }

// SelectFirstProcess selects the first non-dummy process
func (m *StateMutation) SelectFirstProcess() *StateMutation {
	for i := range m.initState.Processes {
		if m.initState.Processes[i].ID != DummyProcessID {
			m.initState.CurrentProcID = m.initState.Processes[i].ID
			break
		}
	}
	return m
}

func (m *StateMutation) ClearProcessSelection() *StateMutation {
	m.initState.CurrentProcID = 0
	return m
}

// MoveProcessSelection moves the process selection by the given direction across all non-dummy processes.
func (m *StateMutation) MoveProcessSelection(direction int) *StateMutation {
	var procs []*Process
	for i := range m.initState.Processes {
		if m.initState.Processes[i].ID != DummyProcessID {
			procs = append(procs, &m.initState.Processes[i])
		}
	}
	if len(procs) == 0 {
		return m
	}
	if len(procs) < 2 {
		return m.SelectFirstProcess()
	}
	ids := make([]int, len(procs))
	curIdx := -1
	for i, p := range procs {
		ids[i] = p.ID
		if p.ID == m.initState.CurrentProcID {
			curIdx = i
		}
	}
	if curIdx == -1 {
		return m.SelectFirstProcess()
	}
	newIdx := curIdx + direction
	if newIdx < 0 {
		newIdx = len(procs) - 1
	} else {
		newIdx = newIdx % len(procs)
	}
	m.initState.CurrentProcID = ids[newIdx]
	return m
}

// SelectProcessByID attempts to select a process by its ID among all processes
func (m *StateMutation) SelectProcessByID(processID int) (*StateMutation, error) {
	for i := range m.initState.Processes {
		if m.initState.Processes[i].ID == processID {
			m.initState.CurrentProcID = processID
			return m, nil
		}
	}
	return m, fmt.Errorf("process ID %d not found", processID)
}

// NextProcess moves to the next process in the list
func (m *StateMutation) NextProcess() *StateMutation { return m.MoveProcessSelection(1) }

// PreviousProcess moves to the previous process in the list
func (m *StateMutation) PreviousProcess() *StateMutation { return m.MoveProcessSelection(-1) }

// SetProcessStatus sets the status for a specific process
func (m *StateMutation) SetProcessStatus(status ProcessStatus, processID int) *StateMutation {
	if proc := m.initState.GetProcessByID(processID); proc != nil {
		proc.Status = status
	}
	return m
}

// SetProcessPID sets the PID for a specific process
func (m *StateMutation) SetProcessPID(pid int, processID int) *StateMutation {
	if proc := m.initState.GetProcessByID(processID); proc != nil {
		proc.PID = pid
	}
	return m
}

// SetExiting marks the state as exiting
func (m *StateMutation) SetExiting() *StateMutation {
	m.initState.Exiting = true
	return m
}
