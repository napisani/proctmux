# Zig Port Phase 1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Zig project foundation, local Zig tooling, and a Go reference-binary path for future parity tests without replacing the working Go implementation yet.

**Architecture:** This phase creates a minimal Zig executable scaffold under `src/` and keeps it independent from the Go source tree. The Makefile gains explicit Zig targets and an explicit Go reference target so future parity work can invoke both binaries intentionally. The Nix dev shell becomes the source of the Zig toolchain used by contributors and agents.

**Tech Stack:** Zig 0.15.2 from the pinned `nixpkgs`, Zig build system, Go 1.26 reference binary, existing Makefile and Nix flake.

> Current repo note: the active Makefile uses direct `zig test` and
> `zig build-exe` invocations for local Zig verification. On macOS with the
> pinned Nix Zig 0.15.2 compiler, the `zig build` runner path can fail before
> project code runs because it does not receive the SDK/libc context. Use
> `make test-zig` and `make build-zig` for current verification.

---

## Scope

This is Phase 1 of the approved Zig port design in `docs/superpowers/specs/2026-05-06-zig-port-design.md`.

This plan does not implement config parsing, IPC, process management, `libvaxis`, or `libghostty-vt`. Those are separate subsystem plans. This plan produces a buildable Zig skeleton and preserves the current Go test/build path while naming it as the reference implementation for parity work.

## File Structure

Create:

- `build.zig` - Zig build graph for the scaffold binary and tests.
- `build.zig.zon` - Zig package manifest with the pinned minimum Zig version.
- `src/main.zig` - temporary Zig entrypoint that proves the binary builds and runs.
- `src/root.zig` - root test module for shared Zig modules.
- `src/version.zig` - scaffold version module with unit tests.
- `scripts/build-go-reference.sh` - script that builds the Go reference binary at a stable path.
- `docs/zig-port/target-matrix.md` - target matrix and Phase 1 build commands.

Modify:

- `.gitignore` - ignore Zig build output.
- `flake.nix` - add Zig to the dev/build dependency set.
- `Makefile` - add Zig scaffold targets and Go reference build target.

No Go source files should change in this phase.

---

### Task 1: Add Zig Tooling To The Development Environment

**Files:**
- Modify: `flake.nix`
- Modify: `.gitignore`

- [ ] **Step 1: Confirm Zig is currently unavailable outside the dev shell**

Run:

```bash
zig version
```

Expected: FAIL before this task is complete, with output like:

```text
zig: command not found
```

If Zig exists globally, still continue. The repository should not depend on a global Zig installation.

- [ ] **Step 2: Add Zig to the Nix dependency set**

Modify `flake.nix` so the `buildDeps` block includes `zig`.

Replace this block:

```nix
        buildDeps = with pkgs; [
          git
          go
          gnumake
        ];
```

With this block:

```nix
        buildDeps = with pkgs; [
          git
          go
          gnumake
          zig
        ];
```

Leave the existing `devDeps` expression intact so it inherits `zig` through `buildDeps`.

- [ ] **Step 3: Ignore Zig build artifacts**

Modify `.gitignore` to include Zig build directories.

Replace the current file:

```gitignore
target/
*.swp
.swn
.swo
bin/
./result
```

With:

```gitignore
target/
.zig-cache/
zig-out/
*.swp
.swn
.swo
bin/
./result
```

- [ ] **Step 4: Verify the dev shell exposes the pinned Zig compiler**

Run:

```bash
nix develop --command zig version
```

Expected: PASS with:

```text
0.15.2
```

- [ ] **Step 5: Commit the tooling change**

Run:

```bash
git add flake.nix .gitignore
git commit -m "build: add zig development tooling"
```

---

### Task 2: Add A Tested Zig Version Module

**Files:**
- Create: `src/version.zig`
- Create: `src/root.zig`

- [ ] **Step 1: Write the failing version test**

Create `src/version.zig` with this content:

```zig
const std = @import("std");

pub const app_name = "proctmux";
pub const version = "0.1.0-zig-dev";

test "banner includes app name and development version" {
    try std.testing.expectEqualStrings("proctmux 0.1.0-zig-dev", banner());
}
```

- [ ] **Step 2: Run the test and verify it fails for the expected reason**

Run:

```bash
nix develop --command zig test src/version.zig
```

Expected: FAIL with an undeclared identifier error for `banner`.

- [ ] **Step 3: Implement the minimal version function**

Replace `src/version.zig` with:

```zig
const std = @import("std");

pub const app_name = "proctmux";
pub const version = "0.1.0-zig-dev";

pub fn banner() []const u8 {
    return app_name ++ " " ++ version;
}

test "banner includes app name and development version" {
    try std.testing.expectEqualStrings("proctmux 0.1.0-zig-dev", banner());
}
```

- [ ] **Step 4: Verify the version test passes**

Run:

```bash
nix develop --command zig test src/version.zig
```

Expected: PASS with:

```text
All 1 tests passed.
```

- [ ] **Step 5: Add the root test module**

Create `src/root.zig` with this content:

```zig
pub const version = @import("version.zig");

test {
    _ = version;
}
```

- [ ] **Step 6: Verify root tests include the version module**

Run:

```bash
nix develop --command zig test src/root.zig
```

Expected: PASS and include the version test in the test count.

- [ ] **Step 7: Commit the version module**

Run:

```bash
git add src/version.zig src/root.zig
git commit -m "build: add zig version module"
```

---

### Task 3: Add The Zig Build Graph And Minimal Binary

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`

- [ ] **Step 1: Write the minimal executable entrypoint**

Create `src/main.zig` with this content:

```zig
const std = @import("std");
const version = @import("version.zig");

pub fn main() void {
    std.debug.print("{s}\n", .{version.banner()});
}
```

This scaffold intentionally prints the version banner only. Full CLI parsing is covered by the CLI subsystem plan.

- [ ] **Step 2: Add the Zig package manifest**

Create `build.zig.zon` with this content:

```zig
.{
    .name = .proctmux,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

- [ ] **Step 3: Add the Zig build graph**

Create `build.zig` with this content:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "proctmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run proctmux");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 4: Format Zig files**

Run:

```bash
nix develop --command zig fmt build.zig src
```

Expected: PASS with no output.

- [ ] **Step 5: Run the Zig unit tests through the build graph**

Run:

```bash
nix develop --command make test-zig
```

Expected: PASS with all Zig tests passing.

- [ ] **Step 6: Build the scaffold binary**

Run:

```bash
nix develop --command make build-zig
```

Expected: PASS and create:

```text
zig-out/bin/proctmux
```

- [ ] **Step 7: Run the scaffold binary**

Run:

```bash
nix develop --command make run-zig
```

Expected: PASS with:

```text
proctmux 0.1.0-zig-dev
```

- [ ] **Step 8: Commit the build graph**

Run:

```bash
git add build.zig build.zig.zon src/main.zig
git commit -m "build: add zig scaffold binary"
```

---

### Task 4: Add Makefile Targets For Zig And Go Reference Builds

**Files:**
- Modify: `Makefile`
- Create: `scripts/build-go-reference.sh`

- [ ] **Step 1: Add Makefile variables**

In `Makefile`, after the existing variable block:

```makefile
APP_NAME=proctmux
BINARY_NAME=$(APP_NAME)
VERSION=0.1.0
BUILD_DIR=bin
SRC_DIR=cmd/$(APP_NAME)
INTERNAL_DIR=internal
```

Add:

```makefile
ZIG=zig
ZIG_OUT=zig-out
GO_REFERENCE_BINARY=$(BUILD_DIR)/$(BINARY_NAME)-go-reference
```

- [ ] **Step 2: Add Zig build targets**

In `Makefile`, add these targets after the existing `build` target:

```makefile
.PHONY: build-zig
build-zig:
	@echo "Building the Zig scaffold..."
	$(ZIG) build -Doptimize=Debug
	@mkdir -p $(BUILD_DIR)
	@cp $(ZIG_OUT)/bin/$(BINARY_NAME) $(BUILD_DIR)/$(BINARY_NAME)

.PHONY: run-zig
run-zig:
	@echo "Running the Zig scaffold..."
	$(ZIG) build run

.PHONY: test-zig
test-zig:
	@echo "Running Zig tests..."
	$(ZIG) build test

.PHONY: fmt-zig
fmt-zig:
	@echo "Formatting Zig files..."
	$(ZIG) fmt build.zig src
```

Do not change the existing `build`, `run`, or `test` targets in this phase. They remain pointed at the Go implementation until a later cutover task explicitly changes them.

- [ ] **Step 3: Add the Go reference build script**

Create `scripts/build-go-reference.sh` with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bin/proctmux-go-reference"

mkdir -p "$ROOT/bin"
go build -o "$OUT" "$ROOT/cmd/proctmux"
printf '%s\n' "$OUT"
```

- [ ] **Step 4: Make the script executable**

Run:

```bash
chmod +x scripts/build-go-reference.sh
```

- [ ] **Step 5: Add the Go reference Makefile target**

In `Makefile`, add this target after `test-zig`:

```makefile
.PHONY: build-go-reference
build-go-reference:
	@echo "Building Go reference binary for parity tests..."
	@scripts/build-go-reference.sh
```

- [ ] **Step 6: Update Makefile help output**

In the `help` target, after:

```makefile
	@echo "  make build      - Build the application for current platform"
```

Add:

```makefile
	@echo "  make build-zig  - Build the Zig scaffold for current platform"
```

After:

```makefile
	@echo "  make run        - Build and run the application"
```

Add:

```makefile
	@echo "  make run-zig    - Run the Zig scaffold"
```

After:

```makefile
	@echo "  make test       - Run tests"
```

Add:

```makefile
	@echo "  make test-zig   - Run Zig tests"
	@echo "  make build-go-reference - Build Go reference binary for parity tests"
```

- [ ] **Step 7: Verify the Zig Makefile targets**

Run:

```bash
nix develop --command make fmt-zig
nix develop --command make test-zig
nix develop --command make build-zig
```

Expected: PASS. `bin/proctmux` should exist and be the Zig scaffold binary.

- [ ] **Step 8: Verify the Go reference target**

Run:

```bash
nix develop --command make build-go-reference
```

Expected: PASS and print:

```text
/Users/nick/code/proctmux/bin/proctmux-go-reference
```

Then run:

```bash
./bin/proctmux-go-reference --help
```

Expected: PASS and print the existing Go usage text beginning with:

```text
Usage:
```

- [ ] **Step 9: Commit the build targets**

Run:

```bash
git add Makefile scripts/build-go-reference.sh
git commit -m "build: add zig and go reference targets"
```

---

### Task 5: Document The Phase 1 Target Matrix

**Files:**
- Create: `docs/zig-port/target-matrix.md`

- [ ] **Step 1: Create the Zig port docs directory**

Run:

```bash
mkdir -p docs/zig-port
```

- [ ] **Step 2: Write the target matrix document**

Create `docs/zig-port/target-matrix.md` with this content:

````markdown
# Zig Port Target Matrix

The Zig release path targets the same platform families supported by the
previous Go release process.

| Product platform | Zig target | Release build target |
| --- | --- | --- |
| Linux amd64 | `x86_64-linux-gnu` | `proctmux-linux-amd64` |
| Linux arm64 | `aarch64-linux-gnu` | `proctmux-linux-arm64` |
| macOS amd64 | `x86_64-macos` | `proctmux-darwin-amd64` |
| macOS arm64 | `aarch64-macos` | `proctmux-darwin-arm64` |

Release artifacts are built with:

```bash
make build-release-artifact ZIG_TARGET=<zig-target> ARTIFACT_NAME=<artifact-name>
```

## Phase 1 Checks

Run these commands from a Nix development shell:

```bash
make fmt-zig
make test-zig
make build-zig
make build-go-reference
```

The Zig binary produced by Phase 1 is only a scaffold. The Go binary produced
by `make build-go-reference` is used as the reference executable for parity
tests in subsequent phases.
````

- [ ] **Step 3: Verify the document references all required platforms**

Run:

```bash
rg -n "x86_64-linux-gnu|aarch64-linux-gnu|x86_64-macos|aarch64-macos" docs/zig-port/target-matrix.md
```

Expected: PASS with one row for each target.

- [ ] **Step 4: Commit the target matrix**

Run:

```bash
git add docs/zig-port/target-matrix.md
git commit -m "docs: add zig target matrix"
```

---

### Task 6: Run Foundation Verification

**Files:**
- No file changes expected.

- [ ] **Step 1: Verify the working tree is clean before final checks**

Run:

```bash
git status --short
```

Expected: no output.

- [ ] **Step 2: Run existing Go tests**

Run:

```bash
nix develop --command make test
```

Expected: PASS. This confirms Phase 1 did not break the current Go implementation.

- [ ] **Step 3: Run Zig format and tests**

Run:

```bash
nix develop --command make fmt-zig
nix develop --command make test-zig
```

Expected: PASS.

- [ ] **Step 4: Build both binaries**

Run:

```bash
nix develop --command make build-zig
nix develop --command make build-go-reference
```

Expected: PASS and create:

```text
bin/proctmux
bin/proctmux-go-reference
```

- [ ] **Step 5: Smoke test the Zig scaffold binary**

Run:

```bash
./bin/proctmux 2>&1
```

Expected: PASS with:

```text
proctmux 0.1.0-zig-dev
```

- [ ] **Step 6: Smoke test the Go reference binary**

Run:

```bash
./bin/proctmux-go-reference --help
```

Expected: PASS and print usage text beginning with:

```text
Usage:
```

- [ ] **Step 7: Record the completed foundation state**

Run:

```bash
git log --oneline -n 5
git status --short
```

Expected: recent commits include:

```text
build: add zig development tooling
build: add zig version module
build: add zig scaffold binary
build: add zig and go reference targets
docs: add zig target matrix
```

`git status --short` should print no tracked changes.

---

## Handoff Notes

After this plan is complete, the next implementation plan should cover Phase 2: config, domain, and discovery parity. It should use the Go reference binary created here only when executable parity checks are useful; pure config/domain/discovery behavior should primarily be tested with deterministic Zig unit tests and shared fixtures.
