# libghostty-vt Unified Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace proctmux-owned VT/ANSI interpretation in unified mode with a hard dependency on vendored `libghostty-vt`, with no fallback renderer.
**Architecture:** Keep proctmux responsible for process management, split layout, repaint framing, and process-list rendering. Add a narrow `src/terminal/ghostty_vt.zig` wrapper around Ghostty's VT terminal state, and route unified server-pane output through stateful Ghostty terminals.
**Tech Stack:** Zig 0.15.2, vendored Ghostty VT Zig sources, vendored `uucode`, existing agent-tui e2e harness, Nix dev shell.

---

## Preconditions

- Work from `/Users/nick/code/proctmux`.
- Use `nix develop -c ...` for verification; ambient Zig may not match the repo.
- Upstream Ghostty pin for this plan: `ghostty-org/ghostty@b0f8276658fbcc75318d2125d40146074a3fc505`.
- Do not add a build flag, runtime flag, or fallback path that uses `src/terminal/text.zig`.
- Do not import Ghostty directly outside `src/terminal/ghostty_vt.zig`.

## Implementation Tasks

- [ ] Vendor the minimal Ghostty VT source and required transitive Zig package.

  Copy only the terminal library subset into `third_party/libghostty-vt/` from the pinned Ghostty commit:

  ```sh
  git clone https://github.com/ghostty-org/ghostty /private/tmp/proctmux-ghostty-vendor
  git -C /private/tmp/proctmux-ghostty-vendor checkout b0f8276658fbcc75318d2125d40146074a3fc505
  mkdir -p third_party/libghostty-vt/src
  ```

  Include these Ghostty paths:

  ```text
  LICENSE
  src/lib_vt.zig
  src/terminal/
  src/unicode/
  src/input/
  src/lib/
  src/datastruct/
  src/simd/
  src/renderer/size.zig
  src/build/uucode_config.zig
  src/fastmem.zig
  src/quirks.zig
  src/tripwire.zig
  src/build_config.zig
  ```

  `src/input/` is included because `src/lib_vt.zig` exposes terminal input encoding as part of the libghostty-vt Zig API. proctmux should not use `vt.input` in this change.

  Vendor `uucode` under `third_party/uucode/` using the exact Ghostty dependency URL and hash from the pinned `build.zig.zon`:

  ```text
  https://deps.files.ghostty.org/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz
  uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9
  ```

  Add `third_party/libghostty-vt/PROCTMUX_VENDOR.md` with upstream URL, commit SHA, vendoring date, included paths, excluded paths, and a note that vendored source should stay unmodified unless a patch is listed there.

  Success criteria:

  ```sh
  test -f third_party/libghostty-vt/src/lib_vt.zig
  test -f third_party/libghostty-vt/src/terminal/Terminal.zig
  test -f third_party/libghostty-vt/src/build/uucode_config.zig
  test -f third_party/uucode/build.zig
  test -f third_party/libghostty-vt/PROCTMUX_VENDOR.md
  ```

- [ ] Make `build.zig` the authoritative Zig build path and add the Ghostty VT module.

  Update `build.zig.zon`:

  ```zig
  .uucode = .{
      .path = "third_party/uucode",
  },
  ```

  Add both vendored directories to `.paths`.

  Update `build.zig` so both the executable module and test module import:

  ```zig
  exe_module.addImport("ghostty-vt", ghostty_vt);
  test_module.addImport("ghostty-vt", ghostty_vt);
  ```

  Add a helper in `build.zig` named `addGhosttyVtModule` that:

  - creates a module rooted at `third_party/libghostty-vt/src/lib_vt.zig`
  - sets `.link_libc = true` on proctmux executable and test modules
  - adds a `terminal_options` options module with:

    ```zig
    artifact = .lib
    c_abi = false
    oniguruma = false
    simd = false
    slow_runtime_safety = false
    kitty_graphics = false
    tmux_control_mode = false
    version_string = "0.1.0"
    version_major = 0
    version_minor = 1
    version_patch = 0
    version_pre = null
    version_build = null
    ```

  - wires `uucode` with `build_config_path = b.path("third_party/libghostty-vt/src/build/uucode_config.zig")`
  - builds host generators from `third_party/libghostty-vt/src/unicode/props_uucode.zig` and `third_party/libghostty-vt/src/unicode/symbols_uucode.zig`
  - adds their stdout as anonymous module imports named `unicode_tables` and `symbols_tables`

  Update `Makefile` to call `zig build` for `build-zig`, `test-zig`, and release artifacts instead of manually duplicating `-Mroot`, `--dep`, and `-M...` module flags. Keep output compatibility by copying `zig-out/bin/proctmux` to `bin/proctmux` in `build-zig`.

  Success criteria:

  ```sh
  nix develop -c zig build test --global-cache-dir .zig-cache/global
  nix develop -c make build-zig
  ./bin/proctmux --help
  ```

- [ ] Add failing wrapper-level tests for the Ghostty terminal contract.

  Create `src/terminal/ghostty_vt.zig` with tests before the full implementation. Export it from `src/terminal/root.zig` as `ghostty_vt`.

  Required tests:

  - plain text renders through `Terminal.renderText`
  - `\r` overwrites a progress line
  - cursor movement updates existing cells
  - erase-line and clear-screen output do not leave stale text
  - alternate-screen enter/exit restores the main screen
  - escape sequences split across two `write` calls still work
  - resize changes the visible viewport without recreating the wrapper from callers

  Success criteria before implementation: tests compile far enough to fail because methods are unimplemented or assertions fail, not because `ghostty-vt` cannot be imported.

- [ ] Implement `src/terminal/ghostty_vt.zig`.

  Use this public API:

  ```zig
  pub const Terminal = struct {
      pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Terminal;
      pub fn deinit(self: *Terminal) void;
      pub fn resize(self: *Terminal, cols: u16, rows: u16) !void;
      pub fn write(self: *Terminal, bytes: []const u8) !void;
      pub fn renderText(self: *Terminal, allocator: std.mem.Allocator) ![]const u8;
  };
  ```

  Internals:

  - allocate a stable inner object so the Ghostty stream handler can safely keep a pointer to `vt.Terminal`
  - initialize `vt.Terminal` with `.cols`, `.rows`, and a bounded `max_scrollback`
  - keep one persistent `vt.TerminalStream` per wrapper instance so split escape sequences preserve parser state
  - call `stream.nextSlice(bytes)` in `write`
  - call Ghostty APIs such as `plainString` or `RenderState.update` in `renderText`
  - do not parse CSI, OSC, SGR, alternate-screen, cursor movement, or carriage-return bytes in proctmux code

  Success criteria:

  ```sh
  nix develop -c make test-zig
  ! rg -n "consumeEscape|applyCsi|setGraphicRendition" src/terminal src/unified
  ```

  The `rg` command should find no proctmux-owned VT parser code.

- [ ] Add incremental child-primary output consumption.

  Update `src/unified/child_primary.zig`:

  - add `pub const OutputCursor = struct { offset: u64 = 0 };`
  - track `output_base_offset: u64` alongside the existing buffered output
  - update `appendOutput` so trimming the buffer also advances `output_base_offset`
  - replace `snapshot` usage with:

    ```zig
    pub fn readSince(
        self: *ChildPrimary,
        allocator: std.mem.Allocator,
        cursor: *OutputCursor,
    ) ![]u8
    ```

  `readSince` should clamp stale cursors to `output_base_offset`, return only newly captured bytes, and advance the cursor to the current end offset.

  Success criteria:

  ```sh
  nix develop -c make test-zig
  ! rg -n "snapshot\\(" src/unified
  ```

  Production unified rendering should no longer call `snapshot()`.

- [ ] Add unified server-output state.

  Create `src/unified/server_output.zig` with a state object that owns Ghostty terminal instances for the server pane.

  Required behavior:

  - child-primary mode owns one `ghostty_vt.Terminal` and one `child_primary.OutputCursor`
  - in-process mode keeps per-process terminal state keyed by `domain.process.ProcessId`
  - in-process mode tracks consumed scrollback length per process and writes only deltas when the scrollback grows
  - if a process scrollback length shrinks, reset that process terminal and replay the new bytes once
  - if the selected process has no scrollback, return the placeholder banner
  - resize the selected terminal to `split.serverSize()` before rendering

  Success criteria:

  ```sh
  nix develop -c make test-zig
  rg -n "@import\\(\"ghostty-vt\"\\)" src
  ```

  The only production import of `ghostty-vt` should be in `src/terminal/ghostty_vt.zig`.

- [ ] Route unified rendering through the new state object.

  Update `src/unified/runtime.zig`:

  - initialize one `server_output.State` inside `runInteractiveRuntime`
  - pass `*server_output.State` through `RenderLoop`, `InputLoop`, and `renderFrame`
  - keep the existing render mutex as the owner of render-state mutation

  Update `src/unified/render.zig`:

  - remove `terminal.text.render(...)`
  - accept already-rendered server text from `server_output.State`
  - keep split composition, line fitting, clear-line-tail behavior, and status bar rendering in proctmux

  Success criteria:

  ```sh
  nix develop -c make test-zig
  ! rg -n "terminal\\.text|text\\.render" src
  ```

  The `rg` command should return no results.

- [ ] Delete the old text renderer and replace its tests.

  Delete:

  ```text
  src/terminal/text.zig
  ```

  Remove `pub const text = @import("text.zig");` from `src/terminal/root.zig`.

  Replace tests that asserted proctmux-owned VT parsing with Ghostty-wrapper tests. Keep tests for proctmux-owned split composition and process switching.

  Success criteria:

  ```sh
  test ! -e src/terminal/text.zig
  nix develop -c make test-zig
  ```

- [ ] Add agent-tui e2e coverage for terminal-sequence behavior.

  Update `tests/e2e/agent_tui_e2e.py` with at least two cases:

  - carriage-return progress output: a selected running process emits repeated `\r` progress updates, and the unified output pane shows only the current line state
  - alternate-screen output: a process enters alternate screen, writes content, exits alternate screen, and the unified output pane does not leave alternate-screen content behind after exit

  Reuse the existing agent-tui runner helpers. Do not add Go tests.

  Success criteria:

  ```sh
  nix develop -c make test-zig-e2e
  ```

- [ ] Update docs for the new backend and build path.

  Update:

  ```text
  docs/architecture.md
  docs/tui.md
  docs/zig-port/target-matrix.md
  ```

  Required doc facts:

  - unified output rendering uses vendored `libghostty-vt`
  - proctmux no longer owns process-output VT/ANSI interpretation
  - the Zig build is driven by `zig build` through the Makefile
  - vendored dependency provenance is recorded in `third_party/libghostty-vt/PROCTMUX_VENDOR.md`

  Success criteria:

  ```sh
  rg -n "libghostty-vt|Ghostty" docs third_party/libghostty-vt/PROCTMUX_VENDOR.md
  ```

- [ ] Run final verification and self-review.

  Run:

  ```sh
  nix develop -c make fmt-zig
  nix develop -c make test-zig
  nix develop -c make test-zig-e2e
  nix build .#default --no-link
  test ! -e src/terminal/text.zig
  ! rg -n "terminal\\.text|text\\.render|consumeEscape|applyCsi|setGraphicRendition" src
  rg -n "@import\\(\"ghostty-vt\"\\)" src
  ```

  Expected final `rg` results:

  - no old text-renderer/parser matches
  - only `src/terminal/ghostty_vt.zig` imports `ghostty-vt`

  Self-review checklist:

  - no fallback renderer remains
  - vendored files are not reformatted by `make fmt-zig`
  - Ghostty API usage is contained to `src/terminal/ghostty_vt.zig`
  - production child-primary rendering feeds deltas, not full snapshots, on each frame
  - unified split composition remains proctmux-owned
  - e2e tests exercise the new behavior through the real TUI

## Acceptance Criteria

- `src/terminal/text.zig` is deleted.
- `src/unified/render.zig` no longer calls `terminal.text.render`.
- No production proctmux module parses process-output CSI/OSC/SGR/VT sequences.
- Unified output pane rendering is backed by vendored `libghostty-vt`.
- The build has no fallback path for non-Ghostty terminal-output rendering.
- `nix develop -c make test-zig` passes.
- `nix develop -c make test-zig-e2e` passes.
- `nix build .#default --no-link` passes.
