package main

// StateMutation represents a series of mutations to apply to an AppState
type StateMutation struct {
	initState *AppState
}

// NewStateMutation creates a new mutation from the current state
func NewStateMutation(state *AppState) *StateMutation {
	// In Go we don't need to clone the entire state, but we need to
	// be careful about references vs values
	stateCopy := *state // This creates a shallow copy
	return &StateMutation{
		initState: &stateCopy,
	}
}

// Commit returns the modified state
func (m *StateMutation) Commit() *AppState {
	return m.initState
}

// SelectFirstProcess selects the first process in the filtered list
func (m *StateMutation) SelectFirstProcess() *StateMutation {
	filteredProcs := m.initState.GetFilteredProcesses()
	if len(filteredProcs) > 0 {
		m.initState.CurrentProcID = filteredProcs[0].ID
	}
	return m
}

// MoveProcessSelection moves the process selection by the given direction
func (m *StateMutation) MoveProcessSelection(direction int) *StateMutation {
	filteredProcs := m.initState.GetFilteredProcesses()
	if len(filteredProcs) == 0 {
		return m
	}
	if len(filteredProcs) < 2 {
		return m.SelectFirstProcess()
	}

	// Build a slice of available process IDs
	availableProcIDs := make([]int, len(filteredProcs))
	for i, p := range filteredProcs {
		availableProcIDs[i] = p.ID
	}

	// Find the current index
	currentIdx := -1
	for i, id := range availableProcIDs {
		if id == m.initState.CurrentProcID {
			currentIdx = i
			break
		}
	}

	if currentIdx == -1 {
		return m.SelectFirstProcess()
	}

	// Calculate the new index with wrapping
	newIdx := currentIdx + direction
	if newIdx < 0 {
		newIdx = len(filteredProcs) - 1
	} else {
		newIdx = newIdx % len(filteredProcs)
	}

	m.initState.CurrentProcID = availableProcIDs[newIdx]

	return m
}

// NextProcess moves to the next process in the list
func (m *StateMutation) NextProcess() *StateMutation {
	return m.MoveProcessSelection(1)
}

// PreviousProcess moves to the previous process in the list
func (m *StateMutation) PreviousProcess() *StateMutation {
	return m.MoveProcessSelection(-1)
}

// SetProcessStatus sets the status for a specific process
func (m *StateMutation) SetProcessStatus(status ProcessStatus, processID int) *StateMutation {
	proc := m.initState.GetProcessByID(processID)
	proc.Status = status
	return m
}

// SetProcessPaneID sets the pane ID for a specific process
func (m *StateMutation) SetProcessPaneID(paneID string, processID int) *StateMutation {
	proc := m.initState.GetProcessByID(processID)
	proc.PaneID = paneID
	return m
}

// SetProcessPID sets the PID for a specific process
func (m *StateMutation) SetProcessPID(pid int, processID int) *StateMutation {
	proc := m.initState.GetProcessByID(processID)
	proc.PID = pid
	return m
}

// SetGUIState sets the GUI state
func (m *StateMutation) SetGUIState(guiState *GUIState) *StateMutation {
	m.initState.GUIState = *guiState
	return m
}

// SetExiting marks the state as exiting
func (m *StateMutation) SetExiting() *StateMutation {
	m.initState.Exiting = true
	return m
}

// GUIStateMutation represents a series of mutations to apply to a GUIState
type GUIStateMutation struct {
	initState *GUIState
}

// NewGUIStateMutation creates a new mutation from the current GUI state
func NewGUIStateMutation(state *GUIState) *GUIStateMutation {
	// Create a shallow copy of the GUIState
	stateCopy := *state

	// Create a deep copy of the messages slice
	messagesCopy := make([]string, len(state.Messages))
	copy(messagesCopy, state.Messages)
	stateCopy.Messages = messagesCopy

	return &GUIStateMutation{
		initState: &stateCopy,
	}
}

// Commit returns the modified GUI state
func (m *GUIStateMutation) Commit() *GUIState {
	return m.initState
}

// SetFilterText updates the filter text
func (m *GUIStateMutation) SetFilterText(text string) *GUIStateMutation {
	m.initState.FilterText = text
	return m
}

// StartEnteringFilter sets the entering filter text state to true
func (m *GUIStateMutation) StartEnteringFilter() *GUIStateMutation {
	m.initState.EnteringFilterText = true
	return m
}

// StopEnteringFilter sets the entering filter text state to false
func (m *GUIStateMutation) StopEnteringFilter() *GUIStateMutation {
	m.initState.EnteringFilterText = false
	return m
}

// AddMessage appends a message to the messages list
func (m *GUIStateMutation) AddMessage(message string) *GUIStateMutation {
	m.initState.Messages = append(m.initState.Messages, message)
	return m
}

// ClearMessages empties the messages list
func (m *GUIStateMutation) ClearMessages() *GUIStateMutation {
	m.initState.Messages = []string{}
	return m
}
