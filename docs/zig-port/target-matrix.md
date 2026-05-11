# Zig Port Target Matrix

The Zig release path targets the same platform families supported by the
previous Go release process.

| Product platform | Zig target | Release build target |
| --- | --- | --- |
| Linux amd64 | `x86_64-linux-gnu` | `proctmux-linux-amd64` |
| Linux arm64 | `aarch64-linux-gnu` | `proctmux-linux-arm64` |
| macOS amd64 | `x86_64-macos` | `proctmux-darwin-amd64` |
| macOS arm64 | `aarch64-macos` | `proctmux-darwin-arm64` |

The current local Zig verification path intentionally goes through the
Makefile. On macOS with the pinned Nix Zig 0.15.2 compiler, `zig build` does not
receive the SDK/libc context needed by the build runner. The Makefile uses direct
`zig test` and `zig build-exe` invocations with the same module wiring as the
build graph.

Release artifacts are built with:

```bash
make build-release-artifact ZIG_TARGET=<zig-target> ARTIFACT_NAME=<artifact-name>
```

## Local Verification

Run these commands from a Nix development shell:

```bash
make fmt-zig
make test-zig
make build-zig
make build-go-reference
```

If `zig` is not on `PATH`, pass the pinned compiler explicitly:

```bash
make fmt-zig ZIG=/nix/store/fh292vnr8i4znyjqy65mkyc0qkcb5k6v-zig-0.15.2/bin/zig
make test-zig ZIG=/nix/store/fh292vnr8i4znyjqy65mkyc0qkcb5k6v-zig-0.15.2/bin/zig
make build-zig ZIG=/nix/store/fh292vnr8i4znyjqy65mkyc0qkcb5k6v-zig-0.15.2/bin/zig
```

The Zig tests include Unix socket listener and process lifecycle coverage, so
they must run in an environment that permits local socket binds and child
process execution.

The Go binary produced by `make build-go-reference` is used as the reference
executable for parity tests.
