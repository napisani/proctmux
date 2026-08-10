# Zig Port Design

Date: 2026-05-06

## Overview

This design ports proctmux from Go to Zig as a hard cutover. The shipped
`proctmux` binary becomes Zig-only. The existing Go implementation remains in
the repository during the migration only as a parity oracle for tests,
fixtures, and reference behavior. Go is not a deployment target after the
cutover.

The Zig implementation should preserve user-facing behavior at the command,
configuration, IPC, process-management, and TUI workflow boundaries while
allowing the internal architecture to use Zig-native patterns and libraries.
The current implementation uses Zig-native process-list rendering and a narrow
terminal-text renderer for unified mode. `libghostty-vt` and `libvaxis` remain
credible future replacement candidates, but behavioral parity is the acceptance
boundary; those libraries are not required if the in-tree renderer passes the
same parity gates.

## Goals

- Replace the deployed Go binary with a Zig implementation.
- Preserve the existing CLI surface:
  - `proctmux`
  - `proctmux start`
  - `proctmux --client`
  - `proctmux --unified`
  - `proctmux --unified-left`
  - `proctmux --unified-right`
  - `proctmux --unified-top`
  - `proctmux --unified-bottom`
  - `proctmux config-init [path]`
  - all `signal-*` commands
- Preserve active YAML configuration structure, defaults, and behavior.
- Ignore stale/dead config fields with warnings instead of implementing them.
- Preserve Unix socket JSON-lines IPC behavior and socket discovery.
- Preserve all three runtime modes: primary, client, and unified.
- Use vendored/pinned dependencies; do not assume system-installed libraries.
- Target macOS and Linux on amd64 and arm64.
- Achieve behavioral parity for the TUI, with a visually familiar but not
  pixel-identical process list.

## Non-Goals

- Keep Go as a shipped binary, compatibility layer, or distribution path.
- Preserve Go package structure or internal implementation paradigms.
- Preserve stale README/config-init fields that are not active in the current
  Go implementation.
- Replace the IPC protocol during the initial port.
- Add Windows support.
- Require screenshot-perfect TUI parity.

## Compatibility Boundaries

The port treats active Go behavior as the source of truth. Documentation and
templates are useful references, but current implementation behavior wins when
they disagree.

### CLI

The Zig binary must remain a command-line drop-in replacement for the active
CLI surface. User-visible flag conflicts, subcommand names, and signal-command
behavior should be preserved where practical.

### Configuration

The Zig config loader must preserve:

- Config search order: `proctmux.yaml`, `proctmux.yml`, `procmux.yaml`,
  `procmux.yml`
- `-f <path>` override behavior
- Active top-level and process config fields
- Defaults for keybindings, layout, style, shell command, process stop timeout,
  PTY size, and placeholder behavior
- Config hashing behavior used for socket discovery
- `config-init` as a generated starter config

Dead or stale config fields should be parsed as unknown/dead fields and should
emit warnings. They should not affect behavior.

### IPC

The initial Zig implementation preserves the current protocol:

- Unix domain socket
- Socket path derived from a hash of the effective config
- JSON object per line
- State broadcasts
- Command request/response messages
- Redacted config environment values in IPC state
- Peer UID verification on Linux and macOS
- Slow-client timeout/backpressure semantics

Zig internals should model IPC messages with typed tagged unions and explicit
serialization/deserialization, but the wire format should remain compatible.
An additive protocol version field may be introduced only if it does not break
existing Go/Zig interoperability tests.

### TUI

TUI acceptance is behavioral parity:

- Same default and configurable keybindings
- Same process control workflows
- Same filter lifecycle
- Same fuzzy and category filtering behavior
- Same running-only toggle behavior
- Same help toggle behavior
- Same docs action if the behavior is active in Go
- Same focus switching in unified mode
- Same split orientations
- Same `layout.hide_process_list_when_unfocused` behavior

The process list may differ slightly in rendering from the Go Bubble Tea
reference. It should remain visually familiar:
selected row, status marker, pointer, process label, debug information, panels,
and messages should correspond to the Go UI.

## Library Choices

### Terminal Emulation

Unified mode currently uses an in-tree Zig renderer for the terminal pane.

Rationale:

- It keeps release builds self-contained while the port is still being
  validated.
- It covers the active Go parity surface: ANSI clear/cursor behavior,
  alternate screen restoration, SGR style preservation, resize reflow, keyboard
  routing, and large output coverage.
- It avoids taking dependency risk for terminal behavior that is not yet needed
  by the documented parity suite.

Integration requirements:

- Keep terminal parsing isolated from TUI and mode orchestration code.
- Preserve focused parity tests for ANSI styles, alternate screen behavior,
  resize propagation, keyboard routing, PTY EOF, and large output.
- If terminal requirements outgrow the in-tree renderer, vendor and pin
  `libghostty-vt` behind the same narrow boundary.

### Process-List TUI

The process-list TUI currently uses an in-tree Zig model and renderer.

Rationale:

- It keeps filtering, keybinding matching, IPC actions, and rendering directly
  testable in unit and parity tests.
- The active UI surface is compact enough that a local renderer is simpler than
  adapting a framework during the port.
- It avoids framework-specific layout drift while the Go reference remains the
  parity oracle.

Design constraint:

- Keep proctmux UI state, filtering, keybinding matching, and IPC actions
  independent from any future rendering framework. If `libvaxis` is adopted
  later, it should render and route events, not own application semantics.

## Target Architecture

The Zig architecture should preserve the current conceptual boundaries without
copying the Go package layout mechanically.

Proposed modules:

| Module | Responsibility |
| --- | --- |
| `cli` | Parse flags/subcommands and preserve the command surface. |
| `config` | Load YAML, apply defaults, validate active fields, warn on dead fields, generate starter config. |
| `discover` | Discover processes from Makefile targets and `package.json` scripts. |
| `domain` | Process model, state, process views, statuses, filtering, sorting. |
| `ipc` | Socket path hashing, Unix socket server/client, JSON-lines protocol, request correlation, state broadcasts, peer UID checks. |
| `proc` | PTY-backed process execution, command building, environment merging, stop/restart lifecycle, `on_kill`. |
| `ring` | Bounded scrollback buffer with live subscribers. |
| `viewer` | Primary-mode stdout relay with snapshot plus live subscription semantics. |
| `tui` | Zig client UI model/rendering, key handling, process list, filter input, messages, help, focus behavior. |
| `terminal` | In-tree terminal text rendering for unified output; optional future `libghostty-vt` wrapper boundary. |
| `modes` | Primary, client, unified, and signal command orchestration. |
| `parity` | Test utilities for invoking the Go reference implementation during migration. |

## Runtime Composition

### Primary Mode

Primary mode owns:

- Config loading and process discovery
- App state
- Process controller
- IPC server
- Stdin forwarding to the selected process PTY
- Stdout viewer for selected process output
- Signal handling and shutdown

It remains the authoritative owner of process lifecycle and state.

### Client Mode

Client mode owns:

- Socket discovery and connection
- IPC client subscription
- Process-list TUI
- Command dispatch to the primary server

It does not manage processes directly.

### Unified Mode

Unified mode should continue to compose the primary server as a child process in
a PTY. It then connects to that child primary server over the same IPC protocol
used by standalone client mode.

This preserves one control path:

- Process lifecycle still belongs to primary mode.
- Client actions still travel through IPC.
- Signal commands still use the same IPC protocol.
- Unified mode gets terminal output by feeding the child primary PTY into
  the terminal renderer.

Avoiding an in-process unified server prevents two separate control paths from
drifting apart.

### Signal Commands

Signal commands remain short-lived IPC clients. They discover the socket from
the current config, send one command, wait for a response, print or report the
result, and exit.

## Parity Strategy

The Go implementation remains in-tree during migration as a reference oracle.
The Zig implementation should pass parity gates before replacing Go as the
default binary.

### Config Parity

Verify:

- Search order and `-f` override
- YAML parsing for active fields
- Defaults
- Dead-field warnings
- Config hash/socket path behavior
- Starter config generation intent

### Discovery Parity

Verify:

- Makefile target extraction regex
- Package manager detection order
- `package.json` script name validation
- Generated process names and fields
- Explicit process precedence over discovered processes

### Domain Parity

Verify:

- Process ordering and sequential IDs
- Status meanings
- Fuzzy filter ranking
- Category filter matching
- Running-only filtering
- Alpha and running-first sorting

### IPC Parity

Verify:

- Socket creation, lookup, probe, and wait behavior
- Message shapes
- Request/response correlation
- State broadcasts
- Command errors
- Redaction of process env values
- Peer UID checks on Linux and macOS
- Slow-client write timeout and dropped-update behavior

During migration, include interoperability tests:

- Go client to Zig server
- Zig client to Go server

These tests can be removed or quarantined after the final cutover, but they are
valuable while the protocol is being reimplemented.

### Process Parity

Verify:

- `shell` and `cmd` resolution
- Working directory handling
- Environment inheritance and overrides
- `add_path`
- PTY size
- Autostart
- Autofocus
- Stop signal and timeout
- SIGKILL escalation
- 500ms restart delay
- `on_kill` runs once for user-initiated stops
- Natural process exits do not run `on_kill`
- Quit stops all running processes

### TUI Parity

Verify behavior with a harness that drives key sequences and observes resulting
state, not by strict screenshots.

Coverage should include:

- Navigation and wraparound
- Start, stop, restart
- Live filter input
- Filter submit/cancel/toggle behavior
- Category search
- Running-only toggle
- Help toggle
- Docs action if active
- Message expiry
- Focus switching
- Split orientations
- Hide-list-when-unfocused behavior

### Terminal Validation

Unified terminal rendering is validated manually and with focused automated
tests where possible:

- ANSI colors and styles
- Alternate screen apps
- Resize propagation
- Keyboard routing to the focused pane
- PTY EOF and child exit handling
- Large output without excessive CPU or memory use

## Migration Phases

### Phase 1: Repo And Build Foundation

Add the Zig project structure, vendored dependency strategy, target matrix,
build scripts, and a parity-test path that can build and invoke the Go
reference binary.

Outputs:

- Zig build skeleton
- Vendored dependency plan
- Target definitions for macOS/Linux amd64/arm64
- Go reference binary build path for tests only

### Phase 2: Config, Domain, And Discovery

Port config loading/defaults/hash, active schema validation, dead-field
warnings, process model, filtering/sorting, and process discovery.

Outputs:

- Config fixtures
- Golden tests
- Go-vs-Zig parity tests for deterministic pure logic

### Phase 3: IPC

Port Unix socket discovery, JSON-lines messages, client/server behavior,
request correlation, redaction, peer UID verification, timeouts, and
backpressure.

Outputs:

- IPC unit tests
- Go/Zig interoperability tests
- Signal-command protocol fixtures

### Phase 4: Process Controller And Ring Buffer

Port PTY process execution, command building, env/cwd handling, output
buffering, lifecycle operations, autostart/autofocus, `on_kill`, and viewer
semantics.

Outputs:

- Process lifecycle integration tests
- Ring buffer tests
- Viewer behavior tests

### Phase 5: Primary Mode And Signal Commands

Wire the Zig primary server and all `signal-*` commands through the new
modules.

Outputs:

- Headless primary mode
- Working signal commands
- Scripted end-to-end tests for process control

### Phase 6: Client TUI

Implement the process-list client with a Zig-native model and renderer.

Outputs:

- Client mode TUI
- TUI behavior harness tests
- Manual validation against a running primary

### Phase 7: Unified Mode

Compose unified mode, implement the terminal renderer boundary, and validate
focused terminal behavior against the Go reference.

Outputs:

- Unified left/right/top/bottom modes
- Focus and input routing
- Resize behavior
- Hide-list-when-unfocused behavior
- Manual terminal validation

### Phase 8: Cutover Hardening

Complete parity testing, release builds, documentation updates, and removal or
quarantine of Go deployment paths.

Outputs:

- Passing full parity suite
- Passing end-to-end scenarios
- macOS/Linux amd64/arm64 release artifacts
- Updated docs that describe Zig as the implementation
- Go retained only if still needed for historical reference tests

## Key Risks

### Optional Terminal Library Churn

If the project adopts `libghostty-vt`, expect API churn. Keep it vendored and
pinned, and isolate all Ghostty API usage inside the terminal boundary.

### Zig TUI Ecosystem Maturity

If the project adopts `libvaxis` or another TUI framework later, validate it
with a small process-list prototype before spreading framework assumptions.

### PTY And Signal Semantics

PTYs, process groups, signal delivery, and terminal resizing differ subtly by
platform. Add integration tests early on both macOS and Linux.

### Config Drift

Use active Go behavior and tests as the source of truth. Treat stale docs as
inputs to cleanup, not requirements.

### IPC Scope Creep

Do not replace JSON-lines IPC during the initial port. The protocol is simple,
debuggable, and an effective parity boundary.

### Hard Cutover

Because Go will not ship after cutover, release readiness depends on parity
evidence. The implementation plan should make every phase produce runnable,
testable behavior.

## Acceptance Criteria

- The Zig binary preserves the active CLI surface.
- Existing active config files continue to work.
- Dead/stale config fields produce warnings and no behavior.
- Primary, client, unified, and signal-command modes work on macOS/Linux
  amd64/arm64.
- IPC protocol compatibility is validated during migration.
- Process lifecycle behavior matches active Go behavior.
- TUI workflows match active Go behavior.
- Unified mode terminal behavior is covered by focused parity tests.
- Dependencies needed for release builds are vendored/pinned.
- Go build/distribution paths are removed or quarantined before final release.
