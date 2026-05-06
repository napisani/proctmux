# Zig Port Target Matrix

Phase 1 establishes the Zig build foundation for the same platform families
supported by the existing Go release process.

| Product platform | Zig target | Build command |
| --- | --- | --- |
| Linux amd64 | `x86_64-linux-gnu` | `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast` |
| Linux arm64 | `aarch64-linux-gnu` | `zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast` |
| macOS amd64 | `x86_64-macos` | `zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast` |
| macOS arm64 | `aarch64-macos` | `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast` |

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
