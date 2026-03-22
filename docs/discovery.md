# Process Discovery

proctmux can automatically discover runnable processes from Makefile targets
and package.json scripts. This removes the need to manually define every
process in your configuration file -- common project tasks are picked up
at startup and appear alongside your explicit entries.

Discovery is opt-in. Enable it with two config flags under `general`:

```yaml
general:
  procs_from_make_targets: true
  procs_from_package_json: true
```

Discovery runs at startup, before the primary server starts. Discovered
processes are merged into `cfg.Procs`. Explicit config entries always win
on name collision.

---

## Makefile Discovery

**Enable:** `general.procs_from_make_targets: true`

Scans the `Makefile` in the working directory. Targets are extracted with the
regex `^([A-Za-z0-9_.-]+):`, which matches lines starting with a valid target
name followed by `:`.

Each matched target produces a process entry:

| Field         | Value                                |
|---------------|--------------------------------------|
| Name          | `make:<target>` (e.g. `make:build`)  |
| `shell`       | `"make <target>"`                    |
| `cwd`         | working directory                    |
| `description` | `"Auto-discovered Makefile target"`  |
| `categories`  | `["makefile"]`                       |

If `Makefile` does not exist in the working directory, discovery is silently
skipped.

---

## package.json Discovery

**Enable:** `general.procs_from_package_json: true`

Scans `package.json` in the working directory. Reads the `scripts` object and
creates a process for each script whose name matches `^[A-Za-z0-9:_-]+$`
(alphanumeric characters, colons, underscores, and hyphens).

### Package manager detection

The package manager is detected by checking for lock files and config files in
the working directory. The first match wins:

| Priority | Manager | Files checked                                          |
|----------|---------|--------------------------------------------------------|
| 1        | pnpm    | `pnpm-lock.yaml`, `.pnpmfile.cjs`, `pnpm-workspace.yaml` |
| 2        | bun     | `bun.lockb`, `bunfig.toml`                             |
| 3        | yarn    | `yarn.lock`, `.yarnrc`, `.yarnrc.yml`, `.yarnrc.yaml`  |
| 4        | npm     | `package-lock.json`, `npm-shrinkwrap.json`             |
| 5        | deno    | `deno.json`, `deno.jsonc`                              |

If none of those files are found, npm is used as the fallback.

### Command generation

Each manager produces a different command list:

| Manager | Command                          |
|---------|----------------------------------|
| pnpm    | `["pnpm", "run", "<script>"]`   |
| yarn    | `["yarn", "<script>"]`          |
| bun     | `["bun", "run", "<script>"]`    |
| deno    | `["deno", "task", "<script>"]`  |
| npm     | `["npm", "run", "<script>"]`    |

### Generated process fields

| Field         | Value                                                              |
|---------------|--------------------------------------------------------------------|
| Name          | `<manager>:<script>` (e.g. `pnpm:dev`, `npm:build`, `bun:test`)   |
| `cmd`         | manager-specific command list (see table above)                    |
| `cwd`         | working directory                                                  |
| `description` | `"Auto-discovered <manager> script: <script-body>"` (or without script body if empty) |
| `categories`  | `["<manager>"]` (e.g. `["pnpm"]`)                                 |

---

## Precedence Rules

- Explicit `procs` entries in config always take precedence over discovered
  processes.
- If a discovered process name collides with an explicit entry, the discovered
  one is skipped and a log message is emitted.
- Multiple discoverers can run simultaneously. They do not conflict with each
  other since naming prefixes are distinct (`make:` vs `pnpm:` vs `npm:` etc.).

---

## Plugin Architecture

Discovery uses a registry pattern defined in the `procdiscover` package:

1. Each discoverer registers itself via an `init()` function that calls
   `procdiscover.Register()`.
2. Each registration includes an `enabled` function that checks the relevant
   config flag (e.g. `procs_from_make_targets`).
3. At startup, `procdiscover.Apply()` iterates all registered discoverers and
   merges results into the process list.
4. Adding a new discoverer requires implementing the `ProcDiscoverer` interface
   and calling `Register()` -- no changes to existing code are needed.

---

## Example

```yaml
general:
  procs_from_make_targets: true
  procs_from_package_json: true

procs:
  "my-server":
    shell: "go run ./cmd/server"
    # This won't be overridden even if a make:my-server target exists
```

Given:
- A Makefile with `build:` and `test:` targets
- A package.json with `dev` and `lint` scripts, in a project using pnpm

The final process list would be:

| Process       | Source      |
|---------------|-------------|
| `my-server`   | config      |
| `make:build`  | discovered  |
| `make:test`   | discovered  |
| `pnpm:dev`    | discovered  |
| `pnpm:lint`   | discovered  |
