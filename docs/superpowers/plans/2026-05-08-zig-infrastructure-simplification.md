# Zig Infrastructure Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the Zig implementation by moving runtime, config, terminal, IPC, process, and test infrastructure responsibilities into deeper Modules with clearer Interfaces and better Locality.

**Architecture:** Keep behavior unchanged while reducing `src/app/root.zig` from a broad runtime coordinator into a thin CLI router. Runtime modes become explicit Modules; runtime config owns load/discovery ordering; terminal rendering is separate from TUI; IPC and process internals keep their external Interfaces while gaining smaller internal Implementations.

**Tech Stack:** Zig 0.15.2, direct `zig test` / `zig build-exe` through Makefile, vendored `zig-yaml`, Unix domain sockets, PTY process management.

---

## Scope Check

This is a broad infrastructure simplification across several independent Modules. Execute it as a sequence of behavior-preserving phases. Each phase must leave the Zig app buildable and testable on its own.

No user-facing CLI behavior, config syntax, IPC wire format, process lifecycle semantics, or TUI keybinding semantics should change in this plan.

## Global Success Criteria

- `make fmt-zig` passes.
- `make test-zig` passes.
- `make build-zig` passes.
- `src/app/root.zig` only owns app entrypoints, CLI routing, exit-code/error rendering, and raw terminal entry/restore orchestration.
- `src/app/root.zig` no longer contains unified runtime loops, primary output forwarding, client IPC session loops, config discovery, terminal text rendering, terminal size probing, or test harness infrastructure.
- Runtime config load/discovery ordering exists in one Module and is used by signal, client, primary, and unified modes.
- Unified mode production and test paths share one input/render/session flow.
- IPC line reading exists in one Module and is used by both client and server.
- IPC protocol public behavior remains wire-compatible with current tests.
- `proc.Controller` keeps its public Interface but moves spawning, environment, output capture, and `on_kill` details into internal proc Modules.
- Repeated test fixtures and fake Adapters are centralized under `src/test_support`.

## File Map

Create:

- `CONTEXT.md` - project domain vocabulary for future architecture reviews.
- `src/test_support/root.zig` - test helper exports.
- `src/test_support/config.zig` - reusable config/process fixtures.
- `src/test_support/ipc.zig` - fake command handlers, fake state providers, socket wait helpers, test line readers.
- `src/test_support/io.zig` - in-memory and gated input/output test Adapters.
- `src/config/runtime.zig` - config load plus discovery application.
- `src/terminal/root.zig` - terminal Module exports.
- `src/terminal/text.zig` - terminal text renderer moved from TUI.
- `src/terminal/mode.zig` - raw terminal mode management.
- `src/terminal/dimensions.zig` - terminal size probing and defaults.
- `src/modes/root.zig` - runtime mode exports.
- `src/modes/io.zig` - production Input and Output structs.
- `src/modes/signal.zig` - signal command runtime.
- `src/modes/client.zig` - client mode runtime.
- `src/modes/primary.zig` - primary mode runtime.
- `src/unified/runtime.zig` - shared unified runtime loop.
- `src/unified/child_primary.zig` - child-primary PTY Adapter.
- `src/unified/in_process_primary.zig` - test-only in-process primary Adapter.
- `src/unified/render.zig` - unified split rendering.
- `src/ipc/line.zig` - JSON-line read/write helpers and message-kind detection.
- `src/ipc/command_codec.zig` - command/response encoding and parsing.
- `src/ipc/state_codec.zig` - state/config/process-view encoding and parsing.
- `src/proc/env.zig` - environment construction.
- `src/proc/spawn.zig` - PTY/pipe spawning and process wait status conversion.
- `src/proc/output.zig` - process output capture.
- `src/proc/on_kill.zig` - `on_kill` hook execution and timeout handling.

Modify:

- `src/root.zig` - export `terminal`, `modes`, and `test_support` under `test` only if needed.
- `src/app/root.zig` - shrink to app entrypoint/router.
- `src/config/root.zig` - export `runtime`.
- `src/tui/root.zig` - remove `terminal_text` export.
- `src/unified/root.zig` - export runtime, child primary, rendering, and child arg helpers.
- `src/ipc/root.zig` - export line and split codec Modules while preserving protocol tests.
- `src/ipc/protocol.zig` - retain public types/functions or re-export moved codec functions.
- `src/ipc/client.zig` - use `ipc.line`.
- `src/ipc/server.zig` - use `ipc.line`; collapse serve overloads behind one deeper Implementation.
- `src/proc/root.zig` - export new internal proc Modules as needed for tests.
- `src/proc/controller.zig` - keep Controller Interface, move private helpers.
- `docs/architecture.md` - update Zig Module map after refactor.
- `docs/modes.md` - ensure unified mode text matches the extracted unified Module.
- `docs/zig-port/target-matrix.md` - keep Makefile verification guidance current.

## Task 1: Add Domain Vocabulary And Central Test Support

**Files:**

- Create: `CONTEXT.md`
- Create: `src/test_support/root.zig`
- Create: `src/test_support/config.zig`
- Create: `src/test_support/ipc.zig`
- Create: `src/test_support/io.zig`
- Modify: `src/root.zig`
- Modify: `src/tui/render.zig`
- Modify: `src/tui/client_model.zig`
- Modify: `src/tui/client_session.zig`
- Modify: `src/ipc/root.zig`
- Modify: `src/primary/root.zig`
- Modify: `src/app/root.zig`

- [ ] **Step 1: Establish the baseline**

Run:

```bash
make test-zig
```

Expected: PASS. If this fails, stop and fix the current branch before refactoring infrastructure.

- [ ] **Step 2: Create `CONTEXT.md`**

Add this content:

```markdown
# proctmux Context

## Domain Vocabulary

- **Runtime Mode**: One of primary, client, unified, or signal command execution.
- **Primary Server**: The process-owning runtime that manages app state, process lifecycle, IPC command handling, and state broadcasts.
- **Client Session**: The TUI-facing runtime that reads IPC state updates, renders process lists, and sends process commands.
- **Unified Runtime**: The single-terminal runtime that composes a primary server pane and client process-list pane in one split model.
- **Project Config**: The loaded `proctmux.yaml` configuration after defaults and discovery have been applied.
- **Discovery**: The Makefile/package.json process discovery pass that merges discovered processes into Project Config.
- **IPC Protocol**: The JSON-over-newline Unix socket command, response, and state-update protocol.
- **Terminal Renderer**: The code that converts process terminal output bytes into printable text for unified mode.
- **Process Controller**: The runtime owner of PTY/pipe processes, scrollback capture, stop/cleanup behavior, and `on_kill` hooks.
```

- [ ] **Step 3: Add `src/test_support/root.zig`**

Use this export shape:

```zig
pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const io = @import("io.zig");

test {
    _ = config;
    _ = ipc;
    _ = io;
}
```

- [ ] **Step 4: Add `src/test_support/config.zig`**

Move repeated `testConfig`, `testViews`, `putShellProcess`, and `putTestProcess` helpers here. Keep ownership rules explicit: helper-created configs must be deinitialized by the caller.

Required public helper names:

```zig
pub fn basicConfig(allocator: std.mem.Allocator) !config.schema.Config
pub fn configWithProcesses(allocator: std.mem.Allocator, labels: []const []const u8) !config.schema.Config
pub fn putShellProcess(cfg: *config.schema.Config, label: []const u8, shell: []const u8) !void
pub fn processViews(cfg: *config.schema.Config) []domain.process.ProcessView
```

- [ ] **Step 5: Add `src/test_support/ipc.zig`**

Move fake IPC Adapters and socket helpers here.

Required public helper names:

```zig
pub const FakeCommandHandler = struct { ... };
pub const FakeStateProvider = struct { ... };
pub const FakePeerAuthorizer = struct { ... };
pub const FakeProcessController = struct { ... };

pub fn waitForSocketFile(path: []const u8) void
pub fn readLine(allocator: std.mem.Allocator, stream: std.net.Stream) ![]const u8
pub fn readLineTimeout(allocator: std.mem.Allocator, stream: std.net.Stream, timeout_ms: i32) ![]const u8
```

- [ ] **Step 6: Add `src/test_support/io.zig`**

Move repeated input/output test Adapters here.

Required public helper names:

```zig
pub const TestOutput = struct { ... };
pub const BytesInput = struct { ... };
pub const BlockingInput = struct { ... };
pub const FileGateInput = struct { ... };
```

- [ ] **Step 7: Update tests to use test support**

Update TUI, IPC, primary, proc, and app tests to import helpers from `src/test_support`. Remove duplicate local helper definitions after each file compiles.

- [ ] **Step 8: Run focused tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 9: Success criteria for Task 1**

- Duplicate fake IPC handlers are gone from `src/ipc/root.zig` and `src/tui/client_session.zig`.
- Duplicate TUI config/view fixtures are gone from `src/tui/render.zig` and `src/tui/client_model.zig`.
- App-only test inputs/outputs are either production-neutral in `src/modes/io.zig` later or centralized in `src/test_support/io.zig`.
- `CONTEXT.md` exists and uses the same domain words as this plan.

## Task 2: Create Runtime Config Module

**Files:**

- Create: `src/config/runtime.zig`
- Modify: `src/config/root.zig`
- Modify: `src/app/root.zig`
- Modify: `src/modes/signal.zig` after Task 4
- Modify: `src/modes/client.zig` after Task 4
- Modify: `src/modes/primary.zig` after Task 4
- Modify: `src/unified/runtime.zig` after Task 5

- [ ] **Step 1: Write runtime config tests**

Add tests in `src/config/root.zig` that verify explicit file loading and default file loading both apply discovery.

Test shape:

```zig
test "runtime config loads explicit file and applies Makefile discovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
            \\general:
            \\  procs_from_make_targets: true
            \\procs:
            \\  explicit:
            \\    shell: "echo explicit"
            \\
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Makefile",
        .data =
            \\build:
            \\\t@echo build
            \\
    });

    var loaded = try runtime.loadInDir(std.testing.allocator, tmp.dir, "proctmux.yaml");
    defer loaded.deinit();

    try std.testing.expect(loaded.config.procs.contains("explicit"));
    try std.testing.expect(loaded.config.procs.contains("make:build"));
}
```

- [ ] **Step 2: Run the new test and verify failure**

Run:

```bash
make test-zig
```

Expected: FAIL because `config.runtime.loadInDir` does not exist.

- [ ] **Step 3: Implement `src/config/runtime.zig`**

Move `loadRuntimeConfig` from `src/app/root.zig` into this Module.

Target Interface:

```zig
const std = @import("std");
const load = @import("load.zig");
const discover = @import("../discover/root.zig");

pub const LoadedRuntimeConfig = load.LoadedConfig;

pub fn loadInDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
) !LoadedRuntimeConfig {
    var loaded = if (config_file.len > 0)
        try load.loadFileInDir(allocator, dir, config_file)
    else
        try load.loadDefaultInDir(allocator, dir);
    errdefer loaded.deinit();

    const discovery_cwd = std.fs.path.dirname(loaded.config.file_path) orelse ".";
    try discover.apply_mod.apply(loaded.config.allocator, &loaded.config, discovery_cwd);
    return loaded;
}
```

- [ ] **Step 4: Export runtime config**

Update `src/config/root.zig`:

```zig
pub const runtime = @import("runtime.zig");
```

Add `_ = runtime;` to the root test block.

- [ ] **Step 5: Replace app usage**

Replace all current `loadRuntimeConfig(...)` calls in `src/app/root.zig` with:

```zig
var loaded = try config.runtime.loadInDir(allocator, dir, config_file);
```

Remove the private `loadRuntimeConfig` function from `src/app/root.zig`.

- [ ] **Step 6: Run tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 7: Success criteria for Task 2**

- `rg -n "loadRuntimeConfig|discover\\.apply" src/app src/modes src/unified` returns no production runtime config helper in app/modes/unified.
- Signal, client, primary, and unified runtimes use `config.runtime.loadInDir`.
- Runtime config tests prove discovery is applied.

## Task 3: Create Terminal Module

**Files:**

- Create: `src/terminal/root.zig`
- Create: `src/terminal/text.zig`
- Create: `src/terminal/mode.zig`
- Create: `src/terminal/dimensions.zig`
- Modify: `src/root.zig`
- Modify: `src/tui/root.zig`
- Modify: `src/app/root.zig`
- Modify: `src/unified/render.zig` after Task 5

- [ ] **Step 1: Move terminal text renderer**

Move `src/tui/terminal_text.zig` to `src/terminal/text.zig`.

Update imports that call:

```zig
tui.terminal_text.render(...)
```

to call:

```zig
terminal.text.render(...)
```

- [ ] **Step 2: Add terminal root exports**

Create `src/terminal/root.zig`:

```zig
pub const text = @import("text.zig");
pub const mode = @import("mode.zig");
pub const dimensions = @import("dimensions.zig");

test {
    _ = text;
    _ = mode;
    _ = dimensions;
}
```

- [ ] **Step 3: Move terminal dimensions**

Create `src/terminal/dimensions.zig` and move `TerminalDimensions`, `terminalDimensionsFromFd`, `default_terminal_width`, and `default_terminal_height` from `src/app/root.zig`.

Target Interface:

```zig
pub const Size = struct {
    width: i32,
    height: i32,
};

pub fn fromFds(output_fd: ?std.posix.fd_t, input_fd: ?std.posix.fd_t) Size
```

- [ ] **Step 4: Move raw terminal mode**

Create `src/terminal/mode.zig` and move `TerminalMode` behavior from `src/app/root.zig`.

Target Interface:

```zig
pub const Mode = struct {
    fd: std.posix.fd_t,
    original: ?std.posix.termios = null,

    pub fn enterIfNeeded(should_enter: bool, fd: std.posix.fd_t) Mode
    pub fn restore(self: *Mode) void
};
```

Keep `argsNeedRawTerminal` in `src/app/root.zig` because it depends on CLI parsing.

- [ ] **Step 5: Export terminal Module**

Update `src/root.zig`:

```zig
pub const terminal = @import("terminal/root.zig");
```

Add `_ = terminal;` to the root test block.

Remove `terminal_text` from `src/tui/root.zig`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 7: Success criteria for Task 3**

- `rg -n "terminal_text" src` returns no matches.
- `rg -n "TerminalMode|terminalDimensions" src/app/root.zig` returns no terminal Implementation details.
- Terminal text rendering tests still pass through the new `terminal.text` Module.

## Task 4: Extract Signal, Client, And Primary Runtime Modes

**Files:**

- Create: `src/modes/root.zig`
- Create: `src/modes/io.zig`
- Create: `src/modes/signal.zig`
- Create: `src/modes/client.zig`
- Create: `src/modes/primary.zig`
- Modify: `src/root.zig`
- Modify: `src/app/root.zig`

- [ ] **Step 1: Create `src/modes/io.zig`**

Move production `Input`, `Output`, `FileInput`, and `EmptyInput` from `src/app/root.zig` into `src/modes/io.zig`.

Target exports:

```zig
pub const Input = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,
    fd: ?std.posix.fd_t = null,

    pub fn readBytes(self: Input, buffer: []u8) !usize
};

pub const Output = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    fd: ?std.posix.fd_t = null,

    pub fn writeAll(self: Output, bytes: []const u8) !void
};
```

- [ ] **Step 2: Create `src/modes/signal.zig`**

Move signal routing from `src/app/root.zig`.

Target Interface:

```zig
pub fn run(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config_file: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
    output: io.Output,
) !void
```

Implementation must load config with `config.runtime.loadInDir` and call `commands.signal.runWithConfig`.

- [ ] **Step 3: Create `src/modes/client.zig`**

Move `runClient`, `runClientInputLoop`, `runClientPollLoop`, `handleClientInput`, `renderClient`, and client-only helpers from `src/app/root.zig`.

Target Interface:

```zig
pub fn run(
    dir: std.fs.Dir,
    config_file: []const u8,
    input: io.Input,
    output: io.Output,
) !void
```

- [ ] **Step 4: Create `src/modes/primary.zig`**

Move `runPrimaryUntilStopped`, `PrimaryOutputRun`, `runPrimaryOutputLoop`, primary scrollback writing, placeholder writing, `PrimaryInputRun`, and `forwardPrimaryInput`.

Target Interface:

```zig
pub fn runUntilStopped(
    dir: std.fs.Dir,
    config_file: []const u8,
    input: io.Input,
    output: io.Output,
    stopped: *std.atomic.Value(bool),
) !void
```

- [ ] **Step 5: Create mode root exports**

Create `src/modes/root.zig`:

```zig
pub const io = @import("io.zig");
pub const signal = @import("signal.zig");
pub const client = @import("client.zig");
pub const primary = @import("primary.zig");

test {
    _ = io;
    _ = signal;
    _ = client;
    _ = primary;
}
```

Update `src/root.zig` to export `modes`.

- [ ] **Step 6: Shrink app routing**

Update `src/app/root.zig` so mode branches call:

```zig
try modes.signal.run(allocator, dir, parsed.config_file, parsed.subcommand, parsed.args, output);
try modes.client.run(dir, parsed.config_file, input, output);
try modes.primary.runUntilStopped(dir, parsed.config_file, input, output, stopped);
```

- [ ] **Step 7: Run tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 8: Success criteria for Task 4**

- `rg -n "runClient|runPrimaryUntilStopped|PrimaryOutputRun|forwardPrimaryInput" src/app/root.zig` returns no matches.
- App tests still cover CLI routing, but runtime behavior tests live with mode Modules or test support.
- `src/app/root.zig` is meaningfully smaller and no longer owns primary/client runtime loops.

## Task 5: Deepen Unified Runtime

**Files:**

- Create: `src/unified/runtime.zig`
- Create: `src/unified/child_primary.zig`
- Create: `src/unified/in_process_primary.zig`
- Create: `src/unified/render.zig`
- Modify: `src/unified/root.zig`
- Modify: `src/app/root.zig`
- Modify: `src/tui/split_model.zig`

- [ ] **Step 1: Move child primary Adapter**

Move `UnifiedChildPrimary`, `captureUnifiedChildOutput`, and `waitUnifiedChild` from `src/app/root.zig` into `src/unified/child_primary.zig`.

Target public type:

```zig
pub const ChildPrimary = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env_map: *const std.process.EnvMap,
        cwd: []const u8,
    ) !*ChildPrimary

    pub fn deinit(self: *ChildPrimary) void
    pub fn sink(self: *ChildPrimary) tui.split_model.InputSink
    pub fn snapshot(self: *ChildPrimary, allocator: std.mem.Allocator) ![]u8
};
```

- [ ] **Step 2: Move unified rendering**

Move `renderUnifiedChild`, `renderUnifiedChildContent`, `renderUnified`, `renderUnifiedContent`, `unifiedChildServerText`, `unifiedServerText`, `writeTextBlock`, `writeSideBySide`, `displayWidth`, and frame clear helpers into `src/unified/render.zig`.

Rendering must depend on `terminal.text.render`, not `tui.terminal_text.render`.

- [ ] **Step 3: Create in-process primary Adapter for tests**

Move `UnifiedServerInput`, `UnifiedPrimaryRun`, and `runUnifiedPrimaryServer` into `src/unified/in_process_primary.zig`.

This Adapter remains test-only in practice, but it should compile with normal Zig tests.

- [ ] **Step 4: Create shared unified runtime loop**

Create `src/unified/runtime.zig` with a shared input/render loop used by both child-primary and in-process-primary paths.

Target external Interface:

```zig
pub fn run(
    dir: std.fs.Dir,
    parent_args: []const []const u8,
    config_file: []const u8,
    orientation: cli.UnifiedSplit,
    input: modes.io.Input,
    output: modes.io.Output,
) !void
```

The production path must still relaunch the current executable with `PROCTMUX_EMBEDDED_PRIMARY=1`. The test path may still use the in-process primary Adapter, but it must call the same session/input/render loop as production after the server pane Adapter is created.

- [ ] **Step 5: Update app routing**

Replace the unified branch in `src/app/root.zig` with:

```zig
try unified.runtime.run(dir, args, parsed.config_file, parsed.unified_orientation, input, output);
```

- [ ] **Step 6: Run unified-focused tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 7: Success criteria for Task 5**

- `rg -n "runUnified|UnifiedChildPrimary|UnifiedRenderRun|renderUnified|UnifiedServerInput" src/app/root.zig` returns no matches.
- `src/unified/root.zig` fails the deletion test in the right direction: deleting it would break real unified behavior, not only helper functions.
- Production and test unified paths share the same key input handling, state polling, resize, and render flow.

## Task 6: Deepen IPC Line And Codec Modules

**Files:**

- Create: `src/ipc/line.zig`
- Create: `src/ipc/command_codec.zig`
- Create: `src/ipc/state_codec.zig`
- Modify: `src/ipc/root.zig`
- Modify: `src/ipc/protocol.zig`
- Modify: `src/ipc/client.zig`
- Modify: `src/ipc/server.zig`

- [ ] **Step 1: Move line reading**

Create `src/ipc/line.zig` and move duplicate line readers from client/server/tests.

Target Interface:

```zig
pub const MessageKind = enum {
    command,
    response,
    state,
    unknown,
};

pub fn read(allocator: std.mem.Allocator, stream: std.net.Stream, max_len: usize) ![]const u8
pub fn readTimeout(allocator: std.mem.Allocator, stream: std.net.Stream, max_len: usize, timeout_ms: i32) ![]const u8
pub fn messageKind(allocator: std.mem.Allocator, line: []const u8) !MessageKind
```

- [ ] **Step 2: Update IPC client and server**

Replace client/server private `readLine`, `readLineTimeout`, and client-private `messageKind` with `ipc.line`.

- [ ] **Step 3: Run IPC-focused tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 4: Split command and response codec**

Move command/response types and functions from `src/ipc/protocol.zig` into `src/ipc/command_codec.zig`:

```zig
pub const Command = protocol.Command;
pub const Response = protocol.Response;
pub const CommandRequest = protocol.CommandRequest;
pub const ProcessListItem = protocol.ProcessListItem;

pub fn commandName(command: Command) []const u8
pub fn commandFromName(name: []const u8) !Command
pub fn commandRequestLine(...) ![]const u8
pub fn parseCommandRequestLine(...) !CommandRequest
pub fn responseLine(...) ![]const u8
pub fn parseResponseLine(...) !Response
```

Keep `src/ipc/protocol.zig` re-exporting the same public names first so callers do not all change in one patch.

- [ ] **Step 5: Split state codec**

Move state/config/process view encoding and parsing from `src/ipc/protocol.zig` into `src/ipc/state_codec.zig`.

Keep these public names available through `protocol.zig` until all callers are migrated:

```zig
pub const StateUpdate = state_codec.StateUpdate;
pub const stateLine = state_codec.stateLine;
pub const parseStateLine = state_codec.parseStateLine;
```

- [ ] **Step 6: Collapse server overloads**

Keep one internal server Implementation driven by an options struct:

```zig
const ServeOptions = struct {
    state_provider: ?StateProvider = null,
    authorizer: PeerAuthorizer = defaultPeerAuthorizer(),
    one_command: bool = false,
};
```

Preserve existing public functions while migrating call sites. Remove public wrappers only when no production or test caller uses them.

- [ ] **Step 7: Run full tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 8: Success criteria for Task 6**

- `rg -n "fn readLine|fn readLineTimeout|fn messageKind" src/ipc/client.zig src/ipc/server.zig` returns no matches.
- IPC wire-format tests still pass without changing expected JSON.
- `protocol.zig` has a smaller Interface surface or acts as a compatibility export layer.
- Server connection behavior, peer authorization, state broadcasts, and command responses remain covered by tests.

## Task 7: Deepen Process Runtime Internals

**Files:**

- Create: `src/proc/env.zig`
- Create: `src/proc/spawn.zig`
- Create: `src/proc/output.zig`
- Create: `src/proc/on_kill.zig`
- Modify: `src/proc/root.zig`
- Modify: `src/proc/controller.zig`
- Modify: `src/proc/builder.zig`

- [ ] **Step 1: Move environment construction**

Move `buildEnvironmentMap` from `src/proc/controller.zig` into `src/proc/env.zig`.

Target Interface:

```zig
pub fn buildMap(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !std.process.EnvMap
```

Keep `builder.buildEnvironmentFromBase` where it is until no tests require it.

- [ ] **Step 2: Move `on_kill` hook execution**

Move `executeOnKillCommand`, `executeOnKillCommandWithTimeoutMs`, `OnKillWaitState`, `waitOnKillChild`, and `waitForOnKillChild` into `src/proc/on_kill.zig`.

Target Interface:

```zig
pub fn execute(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
) !void

pub fn executeWithTimeoutMs(
    allocator: std.mem.Allocator,
    proc_cfg: *const config.schema.ProcessConfig,
    timeout_ms: u64,
) !void
```

- [ ] **Step 3: Move spawn and wait helpers**

Move `startPtyInstance`, `startPipeInstance`, `shouldUsePipeProcess`, `termStatus`, terminal row/col resolution, and process wait details into `src/proc/spawn.zig`.

Keep `Instance` in `controller.zig` for this phase unless moving it makes the Interface smaller.

- [ ] **Step 4: Move output capture**

Move `captureOutput` into `src/proc/output.zig`.

Target Interface:

```zig
pub fn capture(instance: *controller.Instance) void
```

If importing `controller.Instance` creates a cycle, keep `captureOutput` in `controller.zig` and only move it after `Instance` has a better home. Do not introduce a fake Seam with one Adapter.

- [ ] **Step 5: Update controller to compose internals**

`Controller.startProcess` should read as lifecycle orchestration:

```zig
const command_spec = (try builder.buildCommand(...)) orelse return error.InvalidProcessConfig;
var env_map = try env.buildMap(...);
instance.* = try spawn.start(...);
instance.output_thread = try std.Thread.spawn(.{}, output.capture, .{instance});
instance.wait_thread = try std.Thread.spawn(.{}, spawn.waitForExit, .{instance});
```

- [ ] **Step 6: Run proc-focused and full tests**

Run:

```bash
make test-zig
```

Expected: PASS.

- [ ] **Step 7: Success criteria for Task 7**

- `proc.Controller` public functions are unchanged for callers.
- `src/proc/controller.zig` primarily reads as process lifecycle orchestration.
- `on_kill` timeout tests live with the `on_kill` Module.
- PTY and pipe spawn behavior remains covered.
- Process lifecycle docs remain accurate.

## Task 8: Final Cleanup, Docs, And Verification

**Files:**

- Modify: `docs/architecture.md`
- Modify: `docs/modes.md`
- Modify: `docs/zig-port/target-matrix.md`
- Modify: `src/root.zig`
- Modify: `src/app/root.zig`
- Modify: any stale imports left by prior tasks

- [ ] **Step 1: Remove stale exports and imports**

Run:

```bash
rg -n "terminal_text|loadRuntimeConfig|UnifiedChildPrimary|runUnifiedInProcess|readLineTimeout|executeOnKillCommand" src
```

Expected: matches only in intentionally renamed Modules or tests that directly target the renamed Module. Remove stale production references.

- [ ] **Step 2: Update architecture docs**

Update `docs/architecture.md` so the Zig Module map reflects:

- `app` as CLI router.
- `modes` as runtime mode owner.
- `config.runtime` as Project Config loader.
- `terminal` as Terminal Renderer and terminal mode helper.
- `unified` as Unified Runtime owner.
- `ipc.line`, `ipc.command_codec`, and `ipc.state_codec` as IPC internals.
- `proc` internals as process lifecycle Implementation details.

- [ ] **Step 3: Update modes docs**

Update `docs/modes.md` so unified mode describes the extracted child-primary runtime and the shared test/runtime flow.

- [ ] **Step 4: Run final verification**

Run:

```bash
make fmt-zig
make test-zig
make build-zig
```

Expected: all PASS.

- [ ] **Step 5: Confirm structural success criteria**

Run:

```bash
wc -l src/app/root.zig src/unified/root.zig src/unified/runtime.zig src/ipc/protocol.zig src/proc/controller.zig
rg -n "discover\\.apply" src/app src/modes src/unified
rg -n "fn readLine|fn readLineTimeout" src/ipc/client.zig src/ipc/server.zig
rg -n "terminal_text" src
```

Expected:

- `src/app/root.zig` is substantially smaller than its pre-plan size of roughly 2450 lines.
- `discover.apply` is not called directly by app/modes/unified runtime code.
- IPC client/server do not own private line readers.
- `terminal_text` no longer appears.

- [ ] **Step 6: Final success criteria for Task 8**

- All global success criteria are met.
- Docs describe the new Module ownership accurately.
- No behavior change was introduced outside the intended infrastructure simplification.
- The codebase passes the deletion test for the new Modules: deleting runtime config, terminal, modes, unified, IPC line/codec, or proc internals would reintroduce complexity across multiple callers.

## Execution Notes

- Preserve the current dirty worktree. Do not revert user changes.
- Prefer one task per commit if committing during execution.
- Run `make test-zig` after every task because the Zig port is still in active migration and compile-time breakage is cheap to catch early.
- Keep public behavior stable. If a task needs a behavior change to proceed, stop and write a short ADR before continuing.
