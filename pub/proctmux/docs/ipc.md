# IPC & Signal Commands

## Overview

proctmux uses a Unix domain socket for inter-process communication between the
Primary Server and Client Sessions. The IPC Protocol is JSON-over-newline: each
message is a single JSON object terminated by `\n`.

The socket path follows `/tmp/proctmux-<hash>.socket`, where `<hash>` is derived
from Project Config. Each project gets its own socket, so multiple proctmux
instances can run side by side.

The protocol is intentionally Zig-owned and versioned. Go-era mixed-client
compatibility is not supported.

---

## Socket Discovery

`src/ipc/socket.zig` owns socket path lifecycle:

| Function | Behavior |
|---|---|
| `ipc.socket.createPathForConfig()` | Computes the socket path, removes an existing socket file at that path, and returns the path for the Primary Server to listen on. |
| `ipc.socket.getPathForConfig()` | Computes the socket path, verifies the file exists, then probes it with a Unix socket connection. |
| `ipc.socket.waitPathForConfig()` | Polls every 100ms for up to 30 seconds, waiting for the socket file to appear and pass probing. |

---

## Message Types

All messages include:

- `type`
- `protocol_version`

Current `protocol_version` is `1`.

### Snapshot (server -> clients)

```json
{
  "type": "snapshot",
  "protocol_version": 1,
  "current_process_id": 1,
  "exiting": false,
  "ui": {
    "keybinding": {
      "quit": ["q", "ctrl+c"],
      "up": ["k", "up"],
      "down": ["j", "down"],
      "start": ["s", "enter"],
      "stop": ["x"],
      "restart": ["r"],
      "filter": ["/"],
      "submit_filter": ["enter"],
      "toggle_running": ["R"],
      "toggle_help": ["?"],
      "toggle_focus": ["ctrl+w"],
      "focus_client": ["ctrl+left"],
      "focus_server": ["ctrl+right"],
      "docs": ["d"]
    },
    "layout": {
      "category_search_prefix": "cat:",
      "hide_process_description_panel": false,
      "hide_process_list_when_unfocused": false,
      "sort_process_list_alpha": false,
      "sort_process_list_running_first": false,
      "placeholder_banner": "",
      "enable_debug_process_info": false
    },
    "style": {
      "pointer_char": "▶",
      "status_running_color": "green",
      "status_halting_color": "yellow",
      "status_stopped_color": "red"
    }
  },
  "processes": [
    {
      "id": 1,
      "label": "api",
      "status": "running",
      "pid": 12345,
      "description": "API server",
      "docs": "",
      "categories": ["backend"]
    }
  ]
}
```

Snapshots are complete replacements of client-visible state. They are sent:

- as the first message on a stateful client connection;
- after Primary Server state changes;
- after selected process changes, excluding the requester when appropriate.

Snapshots intentionally omit process execution details such as `shell`, `cmd`,
`cwd`, `env`, `add_path`, `on_kill`, stop settings, and log paths.

### Command request (client -> server)

```json
{
  "type": "command",
  "protocol_version": 1,
  "request_id": 1,
  "action": "start",
  "target": "api"
}
```

`request_id` is a monotonically increasing integer. `target` is omitted for
commands that do not require a process label.

### Command response (server -> requesting client)

```json
{
  "type": "response",
  "protocol_version": 1,
  "request_id": 1,
  "success": true,
  "error": ""
}
```

For failures, `success` is `false` and `error` contains a human-readable
message.

---

## Available Commands

| Action | Target required | Description |
|---|---|---|
| `start` | yes | Start a process by label. |
| `stop` | yes | Stop a process by label. |
| `restart` | yes | Stop then start a process. |
| `switch` | yes | Change the selected process in the TUI. |
| `restart_running` | no | Restart all currently running processes. |
| `stop_running` | no | Stop all currently running processes. |

There is no `list` command. `signal-list` connects, reads the initial snapshot,
formats `snapshot.processes`, and closes the connection without sending a
command.

---

## CLI Signal Commands

The `proctmux` binary includes subcommands that connect to the running Primary
Server via IPC:

```text
proctmux signal-list              List all processes (tab-delimited: NAME, STATUS)
proctmux signal-start <name>      Start a process
proctmux signal-stop <name>       Stop a process
proctmux signal-restart <name>    Restart a process
proctmux signal-switch <name>     Switch selected process
proctmux signal-restart-running   Restart all running processes
proctmux signal-stop-running      Stop all running processes
```

These commands discover the socket from Project Config in the working directory
or from `-f <path>`. The Primary Server must already be running.

Command response timeout is 5 seconds.

---

## Security

### Socket file permissions

The socket file is created with mode `0600` (owner read/write only), restricting
access to the user who started the Primary Server.

### Peer UID verification

On connection, the server checks the connecting client's UID against its own
effective UID using platform-specific syscalls:

| Platform | Mechanism |
|---|---|
| Linux | `SO_PEERCRED` via `getsockopt` |
| macOS | `LOCAL_PEERCRED` via `getsockopt` |
| Other | Unsupported; logs a warning once and falls back to file permissions only |

Connections from a different UID are rejected.

### Snapshot data minimization

IPC snapshots only include client-visible fields. Secret-bearing or
process-execution fields are not part of the snapshot model, so they do not need
after-the-fact redaction for normal client updates.

### Write timeout

Each client write has a 2-second deadline. If a client is too slow to consume
data, the write times out and the server disconnects that client. This prevents a
slow or hung client from blocking snapshot broadcasts to other clients.

---

## Client Snapshot Model

Each stateful IPC client connection is served by its own thread. The Primary
Server broadcasts snapshot lines directly to connected clients, guarded by a
per-client write mutex and a 2-second socket write timeout. If a client
disconnects or cannot consume a broadcast quickly enough, that write is dropped
and the client is closed.
