# Process Discovery

proctmux can discover runnable processes from Makefile targets and `package.json`
scripts. Discovery is controlled per source:

- In a **configless project**, both built-in sources run automatically.
- When a config file exists, discovery is disabled by default. Enable an
  individual source with its `general.procs_from_*` setting.

```yaml
general:
  procs_from_make_targets: true
  procs_from_package_json: false
```

If no config exists, proctmux creates an in-memory default configuration. If a
config exists, its explicit `procs` entries remain authoritative and discovered
entries are added only for explicitly enabled sources. Explicit entries win on
name collision.

Discovery is best effort. Missing source files are skipped, and malformed or
unreadable source files are logged and skipped so they do not prevent startup.

---

## Makefile Discovery

**Enable:** `general.procs_from_make_targets: true`

Scans `Makefile` in the current directory. Targets matching
`^([A-Za-z0-9_.-]+):` become processes:

| Field | Value |
|---|---|
| Name | `make:<target>` (for example `make:build`) |
| `shell` | `make <target>` |
| `cwd` | current project directory |
| `description` | `Auto-discovered Makefile target` |
| `categories` | `["makefile"]` |

---

## package.json Discovery

**Enable:** `general.procs_from_package_json: true`

Scans `package.json` and creates a process for each script whose name matches
`^[A-Za-z0-9:_-]+$`.

Package manager detection checks these files in order:

1. pnpm: `pnpm-lock.yaml`, `.pnpmfile.cjs`, `pnpm-workspace.yaml`
2. bun: `bun.lockb`, `bunfig.toml`
3. yarn: `yarn.lock`, `.yarnrc`, `.yarnrc.yml`, `.yarnrc.yaml`
4. npm: `package-lock.json`, `npm-shrinkwrap.json`
5. deno: `deno.json`, `deno.jsonc`

If no marker is found, npm is used. Generated labels and commands are:

| Manager | Label | Command |
|---|---|---|
| pnpm | `pnpm:<script>` | `["pnpm", "run", "<script>"]` |
| yarn | `yarn:<script>` | `["yarn", "<script>"]` |
| bun | `bun:<script>` | `["bun", "run", "<script>"]` |
| deno | `deno:<script>` | `["deno", "task", "<script>"]` |
| npm | `npm:<script>` | `["npm", "run", "<script>"]` |

Each process uses the project directory as `cwd`, has a manager category, and
is stopped initially. Its description includes the script body when available.

---

## Extensible Source Interface

Discovery sources are isolated under `src/discover/`. Each source registers a
name, an enable predicate for its `general.procs_*` setting, and a discover
function:

```zig
pub const Source = struct {
    name: []const u8,
    enabled: *const fn (general: *const GeneralConfig) bool,
    discover: *const fn (allocator: Allocator, cwd: []const u8) anyerror!ProcessMap,
};
```

The coordinator can apply all registered sources for configless startup or only
sources whose settings are enabled for a file-backed config. Adding a future
format requires a source module, its `general.procs_from_*` setting, and one
registry entry; runtime modes do not change.

---

## Example

Given a project with a Makefile containing `build:` and a package.json with a
`dev` script, running `proctmux` without a config presents both discovered
processes. To selectively enable discovery in a file-backed config:

```yaml
general:
  procs_from_make_targets: true
  procs_from_package_json: false

procs:
  api:
    shell: "./api-server"
```

This produces `api` and `make:build`, but not `npm:dev`.
