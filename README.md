# proctmux

A TUI utility for running multiple commands in parallel within tmux panes.

This app is intended to be a drop-in replacement of [procmux](https://github.com/napisani/procmux) for tmux users. Utilizing tmux panes/windows gives the user a more powerful and familiar environment for managing their long-running processes.

## TODO

List of features requiring development to bring proctmux near parity with procmux:

- Display:
    - sort process list
- Processes:
    - interpolation

## Signal Server

proctmux can expose a lightweight HTTP server to remotely control running processes. When enabled, the server runs alongside the TUI and accepts a small set of commands (start/stop/restart).

Enable in `proctmux.yaml`:

```yaml
signal_server:
  host: "localhost"
  port: 9792
  enable: true
```

Notes:
- The server only starts when `enable: true`.
- The TUI must be running for the server to accept requests.

### Endpoints (for reference)
- `GET /` → returns a JSON list of processes (name, running, index, scroll_mode)
- `POST /start-by-name/{name}`
- `POST /stop-by-name/{name}`
- `POST /restart-by-name/{name}`
- `POST /restart-running`
- `POST /stop-running`

## CLI Client

The binary also supports client subcommands that send requests to the running signal server.

Usage:

```bash
# Start the TUI (and server, if enabled)
proctmux start

# Client subcommands (require the server to be enabled and running)
proctmux signal-start "<process-name>"
proctmux signal-stop "<process-name>"
proctmux signal-restart "<process-name>"
proctmux signal-restart-running
proctmux signal-stop-running
```

If the server is disabled or unreachable, client commands will exit with an error.
