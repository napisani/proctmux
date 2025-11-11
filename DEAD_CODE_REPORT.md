# Dead Code Analysis Report

**Generated:** 2025-11-10  
**Codebase:** proctmux

## Executive Summary

This report identifies dead code in the proctmux codebase that can be safely removed. The analysis traced production code paths from entry points (`cmd/proctmux/`) and found that several complete files and individual functions are unused in production.

**Total impact:**
- 7 files can be completely removed (~900 lines)
- 6 functions in 1 additional file can be removed (~163 lines)
- 1 unreachable code path can be removed (~85 lines)

## Production Architecture

Proctmux has **three production modes**:

### 1. Primary Mode (default)
**Entry:** `cmd/proctmux/primary.go:RunPrimary()`
- Creates `PrimaryServer` (internal/proctmux/primary.go:22)
- Uses: `ProcessServer`, `IPCServer`, `Viewer`
- Auto-starts processes, broadcasts state via IPC
- Viewer displays active process output to stdout

### 2. Client Mode
**Entry:** `cmd/proctmux/client.go:RunClient()`
- Creates `ClientModel` - Bubble Tea TUI (internal/proctmux/client_tui.go:27)
- Connects to primary via `IPCClient`
- Receives state updates, sends commands

### 3. Signal Commands
**Entry:** `cmd/proctmux/signals.go:RunSignalCommand()`
- Commands: `signal-start`, `signal-stop`, `signal-restart`, `signal-switch`, etc.
- Uses `IPCClient` to send commands to primary

## Dead Code Categories

### Category 1: Test-Only Code - Controller System

The entire `Controller` system is **only used in tests**, never instantiated in production.

#### Files to Remove:

**1. `internal/proctmux/controller.go` (117 lines)**
- Type: `Controller` struct
- Functions: `NewController()`, `SetIPCServer()`, `LockAndLoad()`, `SubscribeToStateChanges()`, `EmitStateChangeNotification()`, `ApplySelection()`, `OnStateUpdate()`, `SendCommand()`
- **Reason:** Never instantiated in production. Only called from `controller_test.go:12`

**2. `internal/proctmux/controller_actions.go` (189 lines)**
- Functions: `OnKeypressStart()`, `OnKeypressStop()`, `OnKeypressQuit()`, `OnFilterStart()`, `OnKeypressSwitchFocus()`, `OnKeypressDocs()`, `OnKeypressRestart()`, `WaitUntilStopped()`, `OnKeypressStartWithLabel()`, `OnKeypressStopWithLabel()`, `OnKeypressRestartWithLabel()`
- **Reason:** All methods on `Controller`. Only called from old TUI and tests.

**3. `internal/proctmux/controller_navigation.go` (81 lines)**
- Functions: `handleMove()`, `handleMoveToProcessByLabel()`, `OnKeypressDown()`, `OnKeypressUp()`
- **Reason:** All methods on `Controller`. Only called from old TUI and tests.

**4. `internal/proctmux/controller_lifecycle.go` (30 lines)**
- Functions: `OnStartup()`, `Destroy()`
- **Reason:** All methods on `Controller`. Only called from old TUI and tests.

**Production replacement:** `PrimaryServer` handles all process lifecycle directly (primary.go:94-246)

**Verification:**
```bash
$ rg "NewController" --type go | grep -v "_test.go"
# Returns only the definition, no usage
```

### Category 2: Replaced Code - Old TUI System

The old `Model` type in `tui.go` was replaced by `ClientModel` in `client_tui.go`.

#### Files to Remove:

**5. `internal/proctmux/tui.go` (283 lines)**
- Type: `Model` struct
- Functions: `NewModel()`, `Init()`, `Update()`, `View()`, and helper methods
- **Reason:** Replaced by `ClientModel` in client_tui.go. Never instantiated in production.
- **Production replacement:** `cmd/proctmux/client.go:35` uses `NewClientModel()` instead

**6. `internal/proctmux/tui_cmds.go` (62 lines)**
- Functions: `startCmd()`, `stopCmd()`, `restartCmd()`, `docsCmd()`, `focusCmd()`, `applySelectionCmd()`
- **Reason:** All functions take `*Controller` parameter and are only called from old `Model.Update()` method
- **Production replacement:** `ClientModel` sends commands via `IPCClient` (client_tui.go:187-214)

**7. `internal/proctmux/tui_state.go` (116 lines)**
- Types: `UIState`, `UIMode`, helper functions
- **Reason:** Only used by old `Model`. `ClientModel` has its own UIState (client_tui.go:12-20)

**Verification:**
```bash
$ rg "NewModel\(" --type go | grep -v "_test.go" | grep -v "NewClientModel"
# Returns only the definition, no usage
```

### Category 3: Partially Dead - Process Operations

`internal/proctmux/process_ops.go` contains **6 functions, all unused** in production.

#### Functions to Remove:

**Location:** `internal/proctmux/process_ops.go`

1. **`killPane()` (lines 10-22)**
   - **Reason:** Never called. Functionality replaced by `PrimaryServer.stopProcessLocked()` (primary.go:223)

2. **`startProcess()` (lines 24-52)**
   - **Reason:** Never called. Functionality replaced by `PrimaryServer.startProcessLocked()` (primary.go:170)

3. **`focusActivePane()` (lines 54-61)**
   - **Reason:** Never called. Was for tmux pane management, no longer used.

4. **`haltAllProcesses()` (lines 63-77)**
   - **Reason:** Never called. `PrimaryServer.Stop()` handles shutdown (primary.go:248-270)

5. **`haltProcess()` (lines 79-153)**
   - **Reason:** Only called by `haltAllProcesses()` which is also dead. Replaced by `ProcessServer.StopProcess()` (process_server.go)

6. **`setProcessTerminated()` (lines 155-172)**
   - **Reason:** Never called. Process exit handled in `PrimaryServer.startProcessLocked()` goroutine (primary.go:204-218)

**Note:** This would remove the entire file (173 lines total).

**Verification:**
```bash
$ rg "killPane|startProcess\(|focusActivePane|haltAllProcesses|haltProcess\(|setProcessTerminated" \
     --type go | grep -v "func " | grep -v "_test.go"
# Returns no production usage
```

### Category 4: Unreachable Code - IPC Server Fallback

In `internal/proctmux/ipc_server.go`, there's a fallback path to `Controller` that is **never reached** in production.

#### Code to Remove:

**Location:** `internal/proctmux/ipc_server.go:207-291`

```go
// Fall back to controller if no primary server
if s.controller == nil {
    response.Error = "controller not available"
    s.sendResponse(conn, response)
    return
}

switch msg.Action {
case "start":
    // ... calls s.controller.OnKeypressStartWithLabel()
case "stop":
    // ... calls s.controller.OnKeypressStopWithLabel()
// ... etc
}
```

**Also remove:**
- Field `controller *Controller` from `IPCServer` struct (line ~28)
- Method `SetController()` (lines 415-417)

**Reason:** 
- In production, `cmd/proctmux/primary.go:42` calls `ipcServer.SetPrimaryServer(m)`, not `SetController()`
- The `controller` field is never set in production, so this path is unreachable
- If `primaryServer` is nil, the code returns early (line 206), never reaching the controller fallback

**Verification:**
```bash
$ rg "SetController" --type go | grep -v "func "
# Only found in ipc_server.go itself
```

## Impact Analysis

### Breaking Changes: **NONE**

All identified dead code is:
1. Not imported or called from production code
2. Not exported (or if exported, not used externally)
3. Not used by tests that verify production behavior

### Tests Affected

The following test file **should be removed** along with the dead code:
- `internal/proctmux/controller_test.go` (104 lines)

**Reason:** All tests in this file test the `Controller` type, which is dead code.

### Code Quality Improvements

After removal:
- **Reduced maintenance burden:** ~1,200 lines less to maintain
- **Clearer architecture:** Eliminates confusion about which system is actually used
- **Faster builds:** Less code to compile
- **Easier onboarding:** New developers won't wonder if they should use `Controller` or `PrimaryServer`

## Removal Plan

### Phase 1: Safe Removals (No Dependencies)
1. Remove `controller_test.go` (ensures tests pass after each step)
2. Remove `tui_state.go`
3. Remove `tui_cmds.go`
4. Remove `process_ops.go`

### Phase 2: Core Type Removals
5. Remove `tui.go`
6. Remove `controller_actions.go`
7. Remove `controller_navigation.go`
8. Remove `controller_lifecycle.go`
9. Remove `controller.go`

### Phase 3: Cleanup
10. Remove controller fallback from `ipc_server.go`:
    - Remove `controller` field
    - Remove `SetController()` method
    - Remove lines 207-291 (controller fallback path)

### Verification Steps

After each phase:
```bash
# Ensure all tests pass
make test

# Ensure build succeeds
make build

# Test all three production modes
./proctmux                              # Primary mode
./proctmux --mode client               # Client mode
./proctmux signal-list                 # Signal command
```

## Detailed File Breakdown

| File | Lines | Status | Reason |
|------|-------|--------|--------|
| `controller.go` | 117 | **REMOVE** | Test-only, never instantiated in production |
| `controller_actions.go` | 189 | **REMOVE** | Methods on dead Controller type |
| `controller_navigation.go` | 81 | **REMOVE** | Methods on dead Controller type |
| `controller_lifecycle.go` | 30 | **REMOVE** | Methods on dead Controller type |
| `controller_test.go` | 104 | **REMOVE** | Tests for dead Controller type |
| `tui.go` | 283 | **REMOVE** | Replaced by client_tui.go |
| `tui_cmds.go` | 62 | **REMOVE** | Only used by dead tui.go |
| `tui_state.go` | 116 | **REMOVE** | Only used by dead tui.go |
| `process_ops.go` | 173 | **REMOVE** | All functions replaced by PrimaryServer methods |
| `ipc_server.go` | ~90 | **EDIT** | Remove controller field and fallback path |
| **TOTAL** | **~1,245** | | |

## Recommended Next Steps

1. **Review this report** with the team
2. **Create a backup branch** before removal
3. **Execute removal plan** in phases
4. **Run full test suite** after each phase
5. **Test all production modes** manually
6. **Update any documentation** that references removed code

## Notes

- All findings verified by code tracing from entry points
- No external dependencies on dead code found
- Test coverage will remain high after removal (only test-only code tests removed)
- Architecture becomes clearer: `PrimaryServer` for primary mode, `ClientModel` for client mode
