# AGENTS: proctmux (Zig)

- Build: `make build` (Zig binary at `bin/proctmux`).
- Run: `make run` or `./bin/proctmux`.
- Test unit: `make test`.
- Test e2e: `make test-e2e` (agent-tui runner).
- Test all release gates: `make test-all`.
- Format: `make fmt` (`zig fmt build.zig src`).
- Nix dev shell: `nix develop`.
- Nix package: `nix build .#default`.
- Zig version: use the pinned `zig_0_15` from the flake when possible.
- Imports: keep `std` imports first, local imports after; avoid unused imports.
- Errors: prefer explicit error unions and narrow error propagation; avoid panics except for impossible test failures.
- Memory: pass allocators explicitly, pair every owned allocation with cleanup, and use `defer`/`errdefer`.
- Concurrency: use `std.Thread`, atomics, and mutexes; keep shared mutable state behind clear ownership boundaries.
- Terminal behavior: preserve raw-mode cleanup and cursor/alternate-screen restore paths.
- IPC: keep JSON-line protocol compatibility for primary/client/signal modes.
- Makefile: shortcuts `build`, `run`, `test`, `test-e2e`, `test-all`, `dist`.
- Cursor/Copilot: none found; if added in `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md`, follow them.
- CI: `.github/workflows/release.yml` builds release artifacts; tests run locally with `make test-all`.

## Commenting Guidelines

- Prefer **intent-based comments**: explain why code exists, what invariant it preserves, what tradeoff it encodes, or what external behavior it protects.
- Prefer clearer code before adding comments. If a comment only explains confusing mechanics, first try better names, smaller functions, or clearer structure.
- Avoid comments that merely narrate imperative code already visible in the implementation, such as “loop over processes” or “set the flag to true.”
- Treat comments as maintained code. When behavior changes, update or remove comments that no longer describe the current intent.

### Module Comments

- Add module-level comments to relevant files, especially modules that own domain concepts, IPC protocol behavior, process lifecycle, terminal behavior, concurrency, memory ownership, or test harnesses.
- In Zig modules, prefer `//!` at the top of the file.
- Cover the Module’s responsibility, intended callers/use cases, important invariants, ownership boundaries, and non-obvious seams.
- Include explicit non-goals when helpful: what this Module intentionally does not own.

### Function and Type Comments

- Use `///` for public functions/types when their contract is not obvious from the name/signature.
- Explain caller obligations, ownership/lifetime expectations, error behavior, concurrency expectations, ordering constraints, or important side effects.
- Private helper comments should be selective and explain intent, not mechanics.

### Within-Function Comments

- Add within-function comments only around important reasoning points: locking decisions, race avoidance, cleanup ordering, protocol compatibility, terminal quirks, memory ownership, or deliberately surprising behavior.
- Keep comments lightweight and high-signal. A few comments that preserve design intent are better than broad narration.
