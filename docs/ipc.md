# IPC & Signal Commands

## Overview

proctmux uses a Unix domain socket for inter-process communication between
the primary server and clients. The wire protocol is JSON-over-newline: each
message is a single JSON object terminated by `\n`.

The socket path follows the pattern `/tmp/proctmux-<hash>.socket`, where
`<hash>` is a hash derived from the config file contents. This means each
project (with its own `proctmux.yaml`) gets its own socket, and multiple
proctmux instances can run side by side without conflict.

---

## Socket Discovery

The `internal/ipc/socket.go` module provides three functions for socket
lifecycle management:

| Function | Behavior |
|---|---|
| `ipc.CreateSocket(cfg)` | Computes the socket path from the config hash, removes any existing socket file at that path, and returns the path for the server to listen on. |
| `ipc.GetSocket(cfg)` | Computes the socket path, verifies the file exists, then probes it with a test TCP connection (500ms timeout) to confirm the server is alive. Returns an error if the socket is missing or unresponsive. |
| `ipc.WaitForSocket(cfg)` | Polls every 100ms for up to 30 seconds, waiting for the socket file to appear and pass the probe check. An optional progress callback variant (`WaitForSocketWithProgress`) reports elapsed and total time. |

### PROCTMUX_SOCKET environment variable

When set, the `PROCTMUX_SOCKET` env var provides the socket path directly,
bypassing config-hash discovery and the probe connection entirely. This is
used internally by unified-toggle mode: the coordinator spawns a `--client`
child process with the env var set so the child can connect immediately
without a probe. The probe would otherwise create a spurious short-lived
connection that races with the real client's initial-state delivery.

---

## Message Types

All messages are JSON objects separated by newlines.

### State broadcast (server -> all clients)

```json
{
  "type": "state",
  "state": {
    "config": { "..." : "..." },
    "current_proc_id": 0,
    "processes": ["..."]
  },
  "process_views": [
    {
      "id": 1,
      "label": "my-proc",
      "status": 1,
      "pid": 12345,
      "config": { "..." : "..." }
    }
  ]
}
```

State broadcasts are sent:

- On every state change (process start, stop, exit, selection change).
- As the initial message when a new client connects.

Config environment variables are redacted before transmission (see
[Security](#security)).

### Command request (client -> server)

```json
{
  "type": "command",
  "request_id": "1",
  "action": "start",
  "label": "my-proc"
}
```

The `request_id` is a monotonically increasing integer (as a string) that
the client uses to correlate responses.

### Command response (server -> requesting client)

Success:

```json
{
  "type": "response",
  "request_id": "1",
  "success": true
}
```

Error:

```json
{
  "type": "response",
  "request_id": "1",
  "success": false,
  "error": "process not found: my-proc"
}
```

For the `list` command, the response includes a `process_list` field:

```json
{
  "type": "response",
  "request_id": "1",
  "success": true,
  "process_list": [
    { "name": "my-proc", "running": true, "index": 0 }
  ]
}
```

---

## Available Commands

| Command | Label required | Description |
|---|---|---|
| `start` | yes | Start a process by label. |
| `stop` | yes | Stop a process by label. |
| `restart` | yes | Stop then start a process (500ms delay between stop and start). |
| `switch` | yes | Change the selected/active process in the TUI. |
| `list` | no | Return all processes with name, running status, and index. |
| `restart-running` | no | Restart all currently running processes. |
| `stop-running` | no | Stop all currently running processes. |

Commands that require a label will return an error (`"missing process name"`)
if the label is omitted.

---

## CLI Signal Commands

The `proctmux` binary includes subcommands that connect to the running
primary server via IPC:

```
proctmux signal-list              List all processes (tab-delimited: NAME, STATUS)
proctmux signal-start <name>      Start a process
proctmux signal-stop <name>       Stop a process
proctmux signal-restart <name>    Restart a process
proctmux signal-switch <name>     Switch active process
proctmux signal-restart-running   Restart all running processes
proctmux signal-stop-running      Stop all running processes
```

These commands discover the socket from the config file in the working
directory (or from `-f <path>`). The primary server must already be running.

- Command response timeout: 5 seconds.
- Connection retries: up to 5 attempts with 2-second delays between each.

---

## Security

### Socket file permissions

The socket file is created with mode `0600` (owner read/write only),
restricting access to the user who started the server.

### Peer UID verification

On connection, the server checks the connecting client's UID against its own
effective UID using platform-specific syscalls:

| Platform | Mechanism |
|---|---|
| Linux | `SO_PEERCRED` via `getsockopt` |
| macOS | `LOCAL_PEERCRED` via `getsockopt` |
| Other | Unsupported -- logs a warning once, falls back to file permissions only |

Connections from a different UID are rejected with an error.

### Config redaction

The `internal/redact/` package strips environment variable values from
process configs before IPC transmission. Specifically, the `Env` field on
every process config is set to `nil` in the redacted copy. This ensures
secrets defined in `env:` blocks are never sent to IPC clients.

### Write timeout

Each client write has a 2-second deadline. If a client is too slow to
consume data, the write times out and the server disconnects that client.
This prevents a slow or hung client from blocking state broadcasts to other
clients.

---

## Client Channel Model

Each IPC client maintains a buffered Go channel (capacity 10) for receiving
state updates. When the server broadcasts a state change, it is sent to each
client's channel. If the channel is full (the client is not consuming updates
fast enough), the update is dropped and a warning is logged. This
back-pressure mechanism ensures that a slow client cannot block the server or
other clients.
