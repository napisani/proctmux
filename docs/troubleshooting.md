# Troubleshooting

Common issues, their causes, and how to fix them.

---

## "Loading process list..." stays visible

**Problem:** The client TUI shows "Loading process list..." and never shows the actual process list.

**Cause:** The client hasn't received the initial state update from the primary server via IPC. The client connects to the primary's Unix socket and waits for a `StateUpdate` message containing the full process list.

**Solutions:**

- Ensure the primary server is running. Check for the socket file: `ls /tmp/proctmux-*.socket`
- Verify you're in the same directory with the same `proctmux.yaml`. The socket path is derived from a hash of the config file contents (after defaults are applied), so a different config produces a different socket.
- Check the log file for IPC connection errors (see [Logging](#logging) below).
- Try resizing the terminal window. This forces a re-render and can unstick a stale display.

---

## Signal commands fail with "locate proctmux instance"

**Problem:** `proctmux signal-start <name>` (or `signal-stop`, `signal-restart`) fails with an error about being unable to locate a proctmux instance.

**Cause:** No running proctmux instance was found, or there is a config mismatch between the running instance and the current directory. Signal commands connect to the same IPC socket that clients use, which is keyed by a hash of the config file contents.

**Solutions:**

- Ensure proctmux is running in another terminal.
- Run signal commands from the same directory as the primary server.
- Check that the same `proctmux.yaml` file exists and is accessible. If you moved or renamed the config, the socket path will differ.

---

## Socket already exists / stale socket

**Problem:** proctmux fails to start because the socket file already exists from a previous crashed session.

**Cause:** The socket file in `/tmp/` was not cleaned up on crash. Normally proctmux removes and recreates the socket on startup via `os.RemoveAll` in `CreateSocket`.

**Solution:** The socket is automatically removed on startup in most cases. If it persists, manually delete the stale socket:

```sh
rm /tmp/proctmux-*.socket
```

---

## Process output not visible

**Problem:** A process is running but its output isn't showing in the terminal.

**Cause:** In primary+client mode, process output is rendered only in the primary terminal. The client TUI displays the process list and status but does not show stdout/stderr output.

**Solutions:**

- Use unified mode (`--unified`) to see both the process list and process output in a single terminal. Unified mode composes the primary server and client within a single application -- no tmux required.
- In primary+client mode, switch to the primary terminal to see the selected process output.

---

## Processes don't stop cleanly

**Problem:** A process hangs on stop or doesn't respond to the stop signal.

**Cause:** The process may not handle the configured stop signal, or it may take longer to shut down than the configured timeout allows.

**Solutions:**

- Override the stop signal in your config. For example, `stop: 2` sends SIGINT instead of the default SIGTERM. This is useful for processes that handle `ctrl+c` but not SIGTERM.
- Adjust the timeout: `stop_timeout_ms: 10000` gives the process 10 seconds to exit before SIGKILL escalation.
- Use `on_kill` for external cleanup:
  ```yaml
  procs:
    my-service:
      cmd: ["docker", "compose", "up"]
      on_kill: ["docker", "kill", "my-container"]
  ```
- After the timeout expires, proctmux always escalates to SIGKILL. If a process still won't die after SIGKILL, the issue is at the OS level.

---

## on_kill hook doesn't run

**Problem:** The `on_kill` command configured for a process doesn't execute when the process exits.

**Cause:** `on_kill` only runs when a process is explicitly stopped by the user (via the TUI or a signal command). It does **not** run when a process exits on its own or crashes.

**Solution:** This is by design. The `on_kill` hook is meant for cleanup of side effects that only matter when the user intentionally stops a process (e.g., killing a Docker container that the process started). If you need cleanup on natural exit, handle it within the process itself or a wrapper script.

---

## Client and primary out of sync

**Problem:** The client shows stale process state (e.g., a process shows as "running" when it has already stopped).

**Cause:** The IPC update channel between the primary and client may be full. The channel is buffered with a capacity of 10 messages. If the client is slow to consume updates, newer updates are dropped.

**Solutions:**

- This typically resolves automatically on the next state change, since each update contains the full state.
- Check the log file for `"updatesCh full, dropping state update"` warnings. Frequent occurrences may indicate a performance issue.
- Restart the client.

---

## Colors not working

**Problem:** Status colors or per-process colors don't render correctly in the TUI.

**Cause:** The terminal doesn't support the color format being used, or the color value is invalid.

**Solutions:**

- Use standard color names: `red`, `green`, `blue`, `yellow`, `magenta`, `cyan`, `white`
- Use ANSI-prefixed names: `ansigreen`, `ansired`, `ansiblue`
- Use hex values for truecolor terminals: `#ff0000`
- Ensure your terminal emulator supports the color depth you're targeting. Most modern terminals support truecolor, but tmux may require `set -g default-terminal "tmux-256color"` or similar configuration.

---

## Keybindings not working in unified mode

**Problem:** Keys like `j`/`k` don't navigate the process list in unified mode.

**Cause:** Focus is on the server pane instead of the client pane. In unified mode, only the focused pane receives keyboard input.

**Solution:** Press `ctrl+left` to focus the client pane, or `ctrl+w` to toggle focus between panes.

---

## Logging

proctmux does not log to stdout by default. To enable logging, add these options to your `proctmux.yaml`:

```yaml
log_file: "/tmp/proctmux.log"
stdout_debug_log_file: "/tmp/proctmux_stdout.log"
```

- `log_file`: General application log. Includes IPC events, process lifecycle events, stdin forwarding, and viewer switches.
- `stdout_debug_log_file`: Raw process stdout/stderr output, useful for debugging output rendering issues.

To monitor logs in real time:

```sh
tail -f /tmp/proctmux.log
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `PROCTMUX_SOCKET` | Override the IPC socket path. When set, the client connects directly without probing the config-hash-based socket path. Useful for custom deployment scenarios. |
| `PROCTMUX_NO_ALTSCREEN` | Set to `1` to disable alternate screen mode. Useful for debugging TUI output, since alt-screen clears the terminal on exit. |
