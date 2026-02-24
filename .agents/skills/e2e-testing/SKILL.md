# Skill: e2e-testing

E2E integration tests for proctmux. This skill covers writing, running, and debugging end-to-end tests that exercise the full proctmux binary through a PTY-based test harness.

## Architecture overview

The e2e harness spawns the real `proctmux` binary on a pseudo-terminal (40 rows x 120 cols), feeds it keystrokes, and reads its screen output through a minimal VT100 terminal emulator. Tests assert on what the terminal screen looks like at any moment.

```
Test code
  -> e2e.WriteConfig()          create temp proctmux.yaml
  -> e2e.Start*Session()        build binary, spawn on PTY
  -> sess.SendKeys()            write key escape sequences to PTY
  -> sess.WaitForSnapshot()     poll the VT100 screen until predicate matches
  -> sess.Stop()                SIGINT -> wait 5s -> SIGKILL (automatic via t.Cleanup)
```

### Layers

| Layer | File | Role |
|-------|------|------|
| Build | `internal/testharness/e2e/builder.go` | Compiles `proctmux` binary once per test process (`sync.Once`). Cached across tests. |
| Config | `internal/testharness/e2e/config.go` | `WriteConfig(t, yaml)` creates a temp dir with `proctmux.yaml`. Auto-cleaned via `t.TempDir()`. |
| Environment | `internal/testharness/e2e/env.go` | Merges test env vars (`PROCTMUX_NO_ALTSCREEN=1`, `TERM=xterm-256color`) into the process environment. |
| Keys | `internal/testharness/e2e/keys.go` | Named constants for terminal escape sequences (`KeyCtrlW`, `KeyEnter`, `KeyUp`, etc.). |
| Session | `internal/testharness/e2e/session.go` | PTY management, VT100 emulator, snapshot/wait APIs. The core of the harness. |
| Launchers | `internal/testharness/e2e/start.go` | Entry points: `StartUnifiedSession`, `StartUnifiedToggleSession`, `StartClientSession`, `StartPrimaryAndClient`. |
| Tests | `tests/e2e/e2e_test.go` | Test cases with `//go:build integration` tag. |

## Running e2e tests

```bash
# Run all e2e tests
make test-e2e

# Run all e2e tests (manual)
go test -tags=integration ./tests/e2e -v

# Run a single e2e test
go test -tags=integration ./tests/e2e -run '^TestUnifiedToggle_ProcessListAndScrollback$' -v

# Run with timeout (default 10m, but set shorter for faster feedback)
go test -tags=integration ./tests/e2e -v -timeout 60s
```

The `integration` build tag is **required**. Without it, `go test ./tests/e2e` compiles to nothing. Unit tests (`go test ./...`) intentionally exclude e2e tests.

## Writing a new e2e test

### Template

```go
//go:build integration

package e2e_test

import (
    "strings"
    "testing"
    "time"

    e2e "github.com/nick/proctmux/internal/testharness/e2e"
)

func TestMyFeature(t *testing.T) {
    // 1. Create config
    cfgDir, cfgPath := e2e.WriteConfig(t, `
log_file: /tmp/proctmux-test-myfeature.log
procs:
  my-proc:
    shell: "echo MY_MARKER && sleep 30"
    autostart: true
`)

    // 2. Start a session (pick the right mode)
    sess := e2e.StartUnifiedToggleSession(t, cfgDir, cfgPath)

    // 3. Wait for initial render
    if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
        return strings.Contains(snap, "my-proc")
    }); err != nil {
        t.Fatalf("initial render failed: %v\nSnapshot:\n%s", err, sess.Snapshot())
    }

    // 4. Interact with the TUI
    if err := sess.SendKeys(e2e.KeyCtrlW); err != nil {
        t.Fatalf("failed to send keys: %v", err)
    }

    // 5. Assert on new state
    if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
        return strings.Contains(snap, "MY_MARKER")
    }); err != nil {
        t.Fatalf("after toggle: %v\nSnapshot:\n%s", err, sess.Snapshot())
    }
}
```

### Available session launchers

| Function | CLI flags | Use when |
|----------|-----------|----------|
| `StartUnifiedToggleSession(t, cfgDir, cfgPath)` | `--unified-toggle -f <path>` | Testing the toggle-view mode (in-process primary + process list/scrollback toggle) |
| `StartUnifiedSession(t, cfgDir, cfgPath)` | `--unified -f <path>` | Testing the split-pane mode (child process + terminal emulator) |
| `StartClientSession(t, cfgDir, cfgPath)` | `--client -f <path>` | Testing the standalone client TUI |
| `StartPrimaryAndClient(t, cfgDir, cfgPath)` | Starts primary headless, then client | Testing the primary/client architecture with real IPC |

All launchers accept variadic `extraEnv ...string` for injecting additional environment variables (e.g., `"MY_VAR=1"`).

### Available key constants

Defined in `internal/testharness/e2e/keys.go`:

| Constant | Bytes | Terminal meaning |
|----------|-------|-----------------|
| `KeyEnter` | `\r` | Enter/Return |
| `KeyUp` | `\x1b[A` | Arrow up |
| `KeyDown` | `\x1b[B` | Arrow down |
| `KeyRight` | `\x1b[C` | Arrow right |
| `KeyLeft` | `\x1b[D` | Arrow left |
| `KeyCtrlC` | `\x03` | Ctrl+C |
| `KeyCtrlW` | `\x17` | Ctrl+W |
| `KeyCtrlH` | `\x08` | Ctrl+H (backspace) |
| `KeyCtrlL` | `\x0c` | Ctrl+L (clear) |

To send a key not listed here, use `sess.SendString("\x1b...")` with the raw escape sequence, or `sess.SendRunes('a', 'b')` for printable characters.

### Session API reference

| Method | Returns | Use |
|--------|---------|-----|
| `sess.SendKeys(keys ...KeySequence)` | `error` | Send named key constants |
| `sess.SendString(s string)` | `error` | Send raw bytes to PTY |
| `sess.SendRunes(runes ...rune)` | `error` | Send individual characters |
| `sess.Snapshot()` | `string` | Current rendered screen (what a user sees right now) |
| `sess.CleanOutput()` | `string` | Full transcript with ANSI stripped (everything ever output) |
| `sess.RawOutput()` | `[]byte` | Full raw PTY bytes (ANSI codes intact) |
| `sess.WaitForSnapshot(timeout, predicate)` | `error` | Poll screen every 25ms until predicate is true |
| `sess.WaitFor(substring, timeout)` | `error` | Poll clean transcript until substring found |
| `sess.WaitForRaw(substring, timeout)` | `error` | Poll raw bytes until substring found |
| `sess.Stop()` | `error` | Graceful shutdown (automatic via `t.Cleanup`) |

### Snapshot vs CleanOutput

- **`Snapshot()`** = what is on the 40x120 screen right now. Use this for "does the UI currently show X?" assertions. This is what you want 90% of the time.
- **`CleanOutput()`** = everything the process has ever output, with ANSI codes stripped. Use this for "did this string ever appear?" checks (e.g., verifying a process wrote to stdout at some point, even if the screen has since changed).

## Config patterns

### Process that produces output then stays alive

```yaml
procs:
  my-proc:
    shell: "echo SOME_MARKER && sleep 30"
    autostart: true
```

The `sleep 30` keeps the process alive for the duration of the test. The `SOME_MARKER` gives the test a unique string to search for in the scrollback or output. Use `autostart: true` when you want the process running immediately.

### Multiple processes

```yaml
procs:
  proc-a:
    shell: "sleep 60"
  proc-b:
    shell: "sleep 60"
```

### Process with a log file (for debugging)

```yaml
log_file: /tmp/proctmux-test-myfeature.log
procs:
  my-proc:
    shell: "echo hello && sleep 30"
    autostart: true
```

The log file captures proctmux's internal logging (process start/stop, IPC messages, errors). Invaluable for debugging test failures.

## Debugging failing tests

### 1. Read the snapshot on failure

Always include the snapshot in failure messages:

```go
if err := sess.WaitForSnapshot(5*time.Second, func(snap string) bool {
    return strings.Contains(snap, "expected-text")
}); err != nil {
    t.Fatalf("assertion failed: %v\nSnapshot:\n%s", err, sess.Snapshot())
}
```

The snapshot shows exactly what the VT100 emulator rendered -- this is what the test "sees."

### 2. Check the log file

Add `log_file: /tmp/proctmux-test-debug.log` to your config YAML, run the failing test, then read the log:

```bash
cat /tmp/proctmux-test-debug.log
```

The log shows process lifecycle events (start, stop, exit), IPC commands, and any errors.

### 3. Add temporary debug logging

If the test snapshot shows unexpected content, add `log.Printf()` calls in the code being tested. The log output goes to the log file (not the PTY), so it won't interfere with the VT100 emulator.

### 4. Check for `\r` (carriage return) issues

Raw PTY output uses `\r\n` line endings. If lipgloss is rendering content with `Width()` padding, the `\r` can cause the cursor to reset to column 0 and padding spaces overwrite visible text. The `tailLines()` function in `toggle_model.go` strips `\r` for this reason. If you see blank lines where content should be, check for `\r` in the data.

### 5. VT100 emulator limitations

The test harness VT100 emulator is intentionally minimal. It handles:
- Cursor movement (up/down/left/right/absolute position)
- Erase display and erase line
- Carriage return, newline, tab
- Printable character writing with line wrapping

It does NOT handle:
- Scrolling (cursor clamps at bottom row, does not scroll the buffer)
- Alternate screen buffer (disabled via `PROCTMUX_NO_ALTSCREEN=1`)
- SGR sequences (colors/bold/italic are ignored)
- Mouse events
- Unicode combining characters

If the TUI uses features the emulator doesn't support, the snapshot may not match what a real terminal shows.

### 6. Timing issues

- `WaitForSnapshot` polls every 25ms. Allow at least 1-2 seconds for UI operations.
- Use 5-second timeouts for most assertions. Slow CI machines need headroom.
- Process autostart is asynchronous. Always `WaitForSnapshot` for the process to appear before interacting.
- After sending keys, always `WaitForSnapshot` for the result rather than immediately reading `Snapshot()`. The TUI may not have processed the key yet.

### 7. DSR (Device Status Report)

Bubble Tea may send DSR queries (`ESC[6n`) to detect terminal size. The harness auto-responds with a hardcoded position (`ESC[24;80R`). If you see unexpected behavior related to terminal size detection, this is why.

## Conventions

- Build tag: always `//go:build integration` on the first line.
- Package: `e2e_test` (external test package).
- Test names: `TestModeName_WhatIsBeingTested` (e.g., `TestUnifiedToggle_ProcessListAndScrollback`).
- Config: use `e2e.WriteConfig()` with inline YAML. Do not use fixture files.
- Cleanup: automatic via `t.Cleanup()`. Do not call `sess.Stop()` manually.
- Timeouts: 5 seconds for `WaitForSnapshot` is the standard.
- Markers: use unique uppercase strings like `HELLO_TOGGLE_E2E` in process output to avoid false matches.
- Log files: use `/tmp/proctmux-test-<testname>.log` for debugging. These are not cleaned up automatically.
- Assertions: always include `sess.Snapshot()` in failure messages.
