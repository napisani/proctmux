# Git Hooks

This directory contains versioned git hooks for the proctmux project.

## Installation

To install these hooks in your local repository:

```bash
make install-hooks
```

## Available Hooks

### pre-commit

Automatically updates `vendorHash` in `flake.nix` when `go.mod` or `go.sum` changes are committed.

**What it does:**
- Detects when you're committing changes to `go.mod` or `go.sum`
- Runs `make update-vendor-hash` to calculate and update the correct hash
- Automatically stages the updated `flake.nix` file
- Prevents commits if the hash update fails (with option to override)

**Why it's useful:**
- Ensures Nix users can always build from source
- Prevents "hash mismatch" errors for `nix run` and `nix build`
- Automates a manual step that's easy to forget

**Performance:**
- Only runs when `go.mod` or `go.sum` are being committed
- Skipped for all other commits (no overhead)

## Manual Installation

If you prefer not to use `make install-hooks`, you can manually copy hooks:

```bash
cp .githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## Skipping Hooks

To skip hooks for a specific commit:

```bash
git commit --no-verify
```

⚠️ **Warning**: Only skip if you know what you're doing. Remember to run `make update-vendor-hash` manually before creating a release.
