# Process Lifecycle

This document describes how proctmux manages the full lifecycle of processes: allocation, starting, stopping, restarting, and cleanup. All behavior described here is derived from the source code.

## How Processes Run

Each process runs inside a pseudo-terminal (PTY) allocated via the `creack/pty` library. The PTY provides a master/slave pair:

- **Master side** (`ptmx`): held by proctmux, set to raw mode so no processing happens on the parent side.
- **Slave side**: attached to the child process as stdin, stdout, and stderr. The child sees a real terminal -- `isatty()` returns true, terminal escape sequences work, and the kernel handles signal generation (e.g., Ctrl+C sends SIGINT to the child's process group).

The default PTY size is **80 columns x 24 rows**. This can be overridden per-process via `terminal_cols` and `terminal_rows` in the process config. The size is set via `pty.Setsize` (TIOCSWINSZ ioctl), and the child can query it with TIOCGWINSZ.

**Output pipeline:**

```
Child process -> PTY slave -> PTY master -> io.Copy -> RingBuffer (1MB)
```

Each process has a dedicated 1MB ring buffer (`buffer.RingBuffer`) that stores scrollback output. The ring buffer is circular -- when it fills up, the oldest data is silently overwritten. The `io.Copy` goroutine runs for the lifetime of the PTY and forwards all output from the master fd to the ring buffer.

**Process IDs:** Each process gets a unique sequential integer ID starting at 1, assigned during `NewAppState()` based on sorted config key order (`internal/domain/state.go:39`).

## Starting a Process

A process can be started in three ways:

- **TUI:** press `s` or `enter` on a selected process
- **CLI:** `proctmux signal-start <name>`
- **Autostart:** processes with `autostart: true` start automatically (see [Autostart](#autostart))

### Command Resolution

The `shell` and `cmd` fields are mutually exclusive and resolve differently (`internal/process/builder.go`):

- **`shell`**: Passed to a shell interpreter. The default is `sh -c "<command>"`. This can be overridden globally via the `shell_cmd` config field (e.g., `shell_cmd: ["/bin/bash", "-c"]`).
- **`cmd`**: Executed directly via `exec.Command` with no shell wrapper. The first element is the executable; the rest are arguments.

If neither is specified, the process fails to start with "no shell or cmd specified".

### Environment

The child process inherits the full environment of the proctmux parent process, with two layers of customization (`internal/process/builder.go:36`):

1. **`add_path`**: Each entry is appended to the existing `$PATH` (colon-separated).
2. **`env`**: Each key-value pair is added to (or overrides) the environment.

### Working Directory

If `cwd` is specified in the process config, the child process starts in that directory. Otherwise, it inherits the working directory of the proctmux process.

## Stopping a Process

A process can be stopped in two ways:

- **TUI:** press `x` on a selected process
- **CLI:** `proctmux signal-stop <name>`

### Signal Escalation

Stopping follows a signal escalation sequence (`internal/process/controller.go:190`):

1. Send the configured stop signal (default: SIGTERM / signal 15). The signal number is configurable per-process via the `stop` field.
2. Wait for `stop_timeout_ms` milliseconds (default: 3000ms) for the process to exit.
3. If the process is still running after the timeout, send SIGKILL (signal 9).
4. Wait up to 2 more seconds for the SIGKILL to take effect.

After the process exits:

- The PTY file descriptor is closed.
- The OS process handle is released.
- The process is removed from the controller's active process map.

## on_kill Hook

The `on_kill` field accepts a string list (command + arguments) that runs as a cleanup hook.

Key behavior (`internal/process/controller.go:411`):

- Runs **exactly once** after a user-initiated stop (via TUI key, CLI signal command, or quit).
- Does **not** run when a process exits on its own or crashes. The `CleanupProcess` path explicitly sets `runOnKill: false`.
- Executed with the process's configured `cwd` and `env`.
- Has a **30-second timeout** enforced via `context.WithTimeout`. If the hook does not finish in time, it is killed.
- Guarded by `sync.Once` so it cannot execute more than once per process instance.

Typical use case: cleanup commands like `docker kill <container>` or removing temporary files.

## Restarting a Process

A process can be restarted in two ways:

- **TUI:** press `r` on a selected process
- **CLI:** `proctmux signal-restart <name>`

The restart sequence (`internal/proctmux/primary.go:202`):

1. Stop the process (full signal escalation as described above).
2. Wait **500ms**.
3. Start the process again.

To restart all currently running processes: `proctmux signal-restart-running`. This iterates over all running processes and issues a restart command for each one.

## Process States

Process status is defined in `internal/domain/process.go`:

| Status | Meaning |
|---|---|
| `Running` | Process has a valid OS process handle and is executing. |
| `Halted` | Process is not running -- either never started, was stopped, or has exited. |
| `Halting` | Transitional state while a stop is in progress. |
| `Exited` | Defined in the enum but not currently distinguished from `Halted` by the controller. |

State is **derived live** from the `ProcessController` each time it is queried (`internal/process/controller.go:354`). There is no stored status field -- the controller checks whether the process has a valid `cmd.Process` handle to determine if it is running. State is recomputed and broadcast to clients after every start, stop, or restart operation.

## Autostart

Processes with `autostart: true` are started during `PrimaryServer.Start()` (`internal/proctmux/primary.go:165`):

1. The primary server iterates over all configured processes in order.
2. Any process with `autostart: true` is started immediately.
3. After all autostart processes have been launched, a single state broadcast is sent to clients.

Autostart runs before any client connects, so all designated processes are already running by the time the TUI or any IPC client attaches.

## Quit Behavior

When the TUI client quits (press `q` or `ctrl+c`), it sends a `stop-running` command to the primary server (`internal/tui/input.go:160`). The primary server then stops **all** currently running processes, using the full signal escalation sequence for each one (`internal/ipc/server.go:285`).

This means quitting the TUI stops everything. Processes are not left running in the background.

**Multi-client note:** If multiple clients are connected to the same primary server and one client quits, the `stop-running` command stops all processes for every connected client. There is no "disconnect without stopping" action -- quitting always halts all processes.

The same behavior can be triggered from the CLI with `proctmux signal-stop-running`.

## Scrollback Buffer

Each process has a 1MB circular ring buffer (`internal/buffer/ring_buffer.go`) that stores its output history.

When the viewer switches to a process, it uses `SnapshotAndSubscribe()` (`internal/viewer/viewer.go:185`) to atomically:

1. Capture a snapshot of all historical data currently in the ring buffer.
2. Register a live reader channel for new writes.

This atomic operation eliminates the race window between reading history and subscribing to new output -- no bytes are lost during the switch.

The viewer then:

1. Writes the clear-screen escape sequence and the historical snapshot to stdout in a single write (no blank-screen flicker).
2. Starts a goroutine that relays live output from the reader channel to stdout.

When switching away from a process, the viewer stops the relay goroutine, removes the reader from the ring buffer, and repeats the process for the newly selected process.
