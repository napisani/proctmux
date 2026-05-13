# AGENTS: proctmux (Zig)

- Build: `make build` (Zig binary at `bin/proctmux`).
- Run: `make run` or `./bin/proctmux`.
- Test unit: `make test` or `make test-zig`.
- Test e2e: `make test-zig-e2e` (agent-tui runner).
- Test all release gates: `make test-all`.
- Format: `make fmt-zig` (`zig fmt build.zig src`).
- Nix dev shell: `nix develop`.
- Nix package: `nix build .#default`.
- Zig version: use the pinned `zig_0_15` from the flake when possible.
- Imports: keep `std` imports first, local imports after; avoid unused imports.
- Errors: prefer explicit error unions and narrow error propagation; avoid panics except for impossible test failures.
- Memory: pass allocators explicitly, pair every owned allocation with cleanup, and use `defer`/`errdefer`.
- Concurrency: use `std.Thread`, atomics, and mutexes; keep shared mutable state behind clear ownership boundaries.
- Terminal behavior: preserve raw-mode cleanup and cursor/alternate-screen restore paths.
- IPC: keep JSON-line protocol compatibility for primary/client/signal modes.
- Makefile: shortcuts `build`, `run`, `test`, `test-zig-e2e`, `test-all`, `dist`.
- Cursor/Copilot: none found; if added in `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md`, follow them.
- CI: `.github/workflows/release.yml` builds release artifacts; tests run locally with `make test-all`.
