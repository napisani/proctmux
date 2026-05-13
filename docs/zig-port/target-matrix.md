# Zig Port Target Matrix

The Zig release path targets the supported Unix platform families.

| Product platform | Zig target | Release build target |
| --- | --- | --- |
| Linux amd64 | `x86_64-linux-gnu` | `proctmux-linux-amd64` |
| Linux arm64 | `aarch64-linux-gnu` | `proctmux-linux-arm64` |
| macOS amd64 | `x86_64-macos` | `proctmux-darwin-amd64` |
| macOS arm64 | `aarch64-macos` | `proctmux-darwin-arm64` |

The current local Zig verification path intentionally goes through the
Makefile. The Makefile drives `zig build` for both tests and binaries so the
same module graph is used in development, release builds, and e2e runs. On
macOS, the Makefile passes the configured SDK path into `zig build`.

Release artifacts are built with:

```bash
make build-release-artifact ZIG_TARGET=<zig-target> ARTIFACT_NAME=<artifact-name>
```

## Local Verification

Run these commands from a Nix development shell:

```bash
make fmt-zig
make test-zig
make test-zig-e2e
make build-zig
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

## Vendored Dependencies

Zig package and source dependencies are vendored under `third_party/` and wired
through `build.zig.zon` / `build.zig`:

- `third_party/zig-yaml/` -- YAML parsing.
- `third_party/libghostty-vt/` -- Ghostty terminal state used by unified-mode
  process output rendering.
- `third_party/uucode/` -- Unicode table dependency required by the pinned
  Ghostty VT code.

Ghostty provenance, included paths, and local build shims are documented in
`third_party/libghostty-vt/PROCTMUX_VENDOR.md`.
