# Clean IPC Protocol Design

Date: 2026-06-09
Status: Implemented in Zig IPC refactor
Scope: Zig-only IPC protocol and client-visible state model
Compatibility: intentionally breaking with the Go/archive protocol and current Zig state wire format

## Context

The current Zig IPC layer preserves much of the Go-era shape: clients receive serialized internal application state plus a near-full config object, while command and state messages are encoded by hand in `src/ipc/command_codec.zig` and `src/ipc/state_codec.zig`.

That design works, but it has three code-quality problems:

1. **The wire format is coupled to internal state.** Clients receive far more than they need, including config fields used only for process spawning or server behavior.
2. **Redaction is required after the fact.** If IPC only sent client-visible fields, secrets and process execution details would not enter the wire model at all.
3. **Manual JSON construction is hard to maintain.** Adding, removing, or renaming fields requires synchronized encoder/decoder edits and makes the protocol schema difficult to see.

Because the cutover can intentionally break Go/Zig compatibility, the cleanest path is to redesign IPC around a small Zig-owned protocol instead of preserving old shapes.

## Goals

- Keep IPC simple, inspectable, and easy to debug.
- Use a single explicit protocol schema for all wire messages.
- Send only data clients actually need.
- Remove full `Config`/`AppState` serialization from IPC.
- Remove IPC-specific redaction of full config state.
- Reduce memory ownership complexity in state parsing.
- Make future protocol changes deliberate through versioning and golden tests.

## Non-goals

- Preserve compatibility with Go primary/client processes.
- Preserve compatibility with the current Zig state JSON shape.
- Introduce event sourcing or incremental state replay.
- Move away from Unix sockets or JSON-lines in this pass.
- Send process output over IPC. Process output remains handled by primary/unified output paths.

## Chosen Approach

Use a **versioned minimal snapshot protocol over JSON-lines**.

The transport remains one JSON object per line over the existing Unix domain socket. The payloads change to purpose-built messages:

- `snapshot`: the complete client-visible state.
- `command`: a client request to mutate server state or process lifecycle.
- `response`: the result of a command.

Clients do not reconstruct state from events. Every state broadcast is a complete snapshot. This is less clever than an event protocol and much easier to reason about: a client can always replace its local state with the latest snapshot.

## Protocol

All messages include:

- `type`: message kind.
- `protocol_version`: integer protocol version. Initial version is `1`.

Field names use `lower_snake_case`.

### Snapshot

A snapshot contains only client-visible state:

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
      "categories": ["backend"]
    }
  ]
}
```

The snapshot intentionally omits process execution details:

- no `shell`
- no `cmd`
- no `cwd`
- no `env`
- no `add_path`
- no stop/on_kill settings
- no log file paths
- no full config hash inputs

If a future UI feature needs more data, add a specific client-visible field rather than sending full config again.

### Command

Commands use a numeric request id and an optional target label:

```json
{
  "type": "command",
  "protocol_version": 1,
  "request_id": 1,
  "action": "start",
  "target": "api"
}
```

Supported actions:

- `start` requires `target`.
- `stop` requires `target`.
- `restart` requires `target`.
- `switch` requires `target`.
- `restart_running` has no target.
- `stop_running` has no target.

The old `list` action is removed. `signal-list` connects, reads the initial snapshot, formats the process table, and closes the connection.

### Response

Responses are small and uniform:

```json
{
  "type": "response",
  "protocol_version": 1,
  "request_id": 1,
  "success": true,
  "error": ""
}
```

For failures, `success` is `false` and `error` contains a human-readable message.

## Architecture

### New client-visible domain model

Add a small client-visible state model, separate from process runtime config:

- `src/domain/client_snapshot.zig`

This module owns:

- `ClientSnapshot`
- `UiConfig`
- `UiKeybindingConfig`
- `UiLayoutConfig`
- `UiStyleConfig`
- `ProcessSummary`

The primary server builds `ClientSnapshot` from `AppState + ProcessController`. The TUI consumes `ClientSnapshot`. IPC only encodes/decodes this model.

This keeps UI and IPC away from full `config.schema.Config` and prevents accidental exposure of process execution fields.

### Deepened IPC Protocol module

Use one focused protocol module:

- `src/ipc/protocol.zig`

Responsibilities:

- define wire message DTOs
- encode snapshot/command/response JSON-lines
- decode snapshot/command/response JSON-lines through one `Message` union
- validate `protocol_version`
- map command action strings to enums
- own golden tests for the IPC Protocol

The clean end state is one IPC Protocol module. `command_codec.zig`, `state_codec.zig`, and interim pass-through protocol layers are removed once callers move to `protocol.zig`.

### Server flow

1. Primary state changes.
2. IPC server asks the primary for a fresh `ClientSnapshot`.
3. `protocol.snapshotLine()` encodes the snapshot.
4. Server broadcasts the snapshot line to connected clients.

On a command:

1. Server decodes `protocol.Message.command`.
2. Server validates action/target.
3. Server calls primary command handling.
4. Server writes `protocol.Response`.
5. If state changed, server broadcasts a fresh snapshot.

### Client flow

1. Client connects to the Unix socket.
2. Server immediately sends a `snapshot` line.
3. Client initializes the TUI model from the snapshot.
4. Commands are sent as `command` messages.
5. Responses are matched by numeric `request_id`.
6. New snapshots replace the client-visible state.

### Signal command flow

Named signal commands still send `command` messages and wait for `response`.

`signal-list` becomes snapshot-based:

1. Connect to the primary socket.
2. Read the initial snapshot.
3. Format `NAME\tSTATUS` from `snapshot.processes`.
4. Close the connection without sending a command.

## Error Handling

- Unsupported `protocol_version` returns `error.UnsupportedProtocolVersion` during decode.
- Unknown message type returns `error.InvalidMessageType`.
- Unknown command action returns `error.UnknownCommand`.
- Missing target for named commands produces a command response with `success: false`.
- Malformed JSON closes the client connection; the server logs at debug level and does not broadcast partial state.
- Command execution failures are returned in the response `error` string.

The line size limit remains bounded by the existing IPC line reader limit.

## Memory Management

Snapshot decoding should use arena-style ownership per decoded message. The parsed snapshot owns all strings/slices through a single parsed allocation or arena, so cleanup is one call. Avoid side lists such as `owned_config_strings`.

Encoding functions allocate a single owned line returned to the caller:

- caller owns encoded line
- caller frees encoded line after write/broadcast

This keeps ownership local and avoids nested deinit requirements for full config objects.

## Security and Redaction

The new snapshot model does not include secret-bearing or process-execution fields. Therefore IPC no longer needs to create a redacted copy of full config state for normal state broadcasts.

Keep the existing Unix socket protections:

- owner-only socket permissions
- same-user peer credential checks where supported
- write deadlines for slow clients

Add a test that snapshot JSON does not contain sensitive/process-execution field names such as `env`, `shell`, `cmd`, `cwd`, `on_kill`, `log_file`, or `stdout_debug_log_file`.

## Testing

Add golden tests in `src/ipc/protocol.zig` for:

1. snapshot encode
2. snapshot decode
3. command encode/decode
4. response encode/decode
5. unsupported protocol version
6. unknown command action
7. snapshot excludes process execution and log fields

Update existing IPC/client/server tests to assert behavior through snapshots instead of full state lines.

Add or update e2e coverage for:

- client connects and renders process list from snapshot
- start/stop/restart command still updates status
- `signal-list` works from the initial snapshot
- multiple clients receive replacement snapshots after state changes

## Migration Steps

1. Add `domain.client_snapshot` with conversion from server `AppState + ProcessController`.
2. Deepen `ipc.protocol` and add golden tests.
3. Update IPC server to emit snapshot lines and parse new command requests.
4. Update IPC client/session code to read snapshots and send new commands.
5. Refactor TUI client model to consume `ClientSnapshot` instead of full `AppState`/`Config`.
6. Change `signal-list` to read initial snapshot instead of sending a list command.
7. Delete old state/command codec code once no callers remain.
8. Update `docs/ipc.md` and any mode/config docs that describe IPC state.

## Cutover Notes

This is an intentional protocol break. During and after the change:

- Go clients cannot talk to Zig primaries.
- Zig clients from before this change cannot talk to new Zig primaries.
- The only supported compatibility boundary is the new `protocol_version` field.

Because Go is being replaced by Zig, this is acceptable and preferred over carrying compatibility complexity.
