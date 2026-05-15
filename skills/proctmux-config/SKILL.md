---
name: proctmux-config
description: Use this skill whenever the user wants to create, edit, explain, validate, or troubleshoot a proctmux.yaml/procmux.yaml file, add or change proctmux processes, configure lifecycle behavior such as stop signals/on_kill/autostart, customize unified-mode layout/keybindings/style, or enable Makefile/package.json process discovery. Use it even when the user says this casually, such as "add my dev server to proctmux", "fix this proctmux config", "write a config for these services", or "what YAML option controls focus".
---

# Proctmux Config

Use this skill to produce accurate `proctmux.yaml` files for proctmux users.
Assume the reader is an external consumer who has the proctmux binary and
project files, but no access to internal proctmux project files.

Before writing or changing a config, read `references/proctmux-yaml.md`. It
contains a standalone option reference, defaults, lifecycle semantics,
discovery behavior, and legacy fields that are currently ignored. Do not tell
the user to inspect proctmux internals.

## Workflow

1. Identify the user's goal: new config, process entry, lifecycle behavior,
   keybindings, layout/style, discovery, or troubleshooting.
2. If an existing config is available, inspect it first and preserve unrelated
   entries. Do not rewrite the whole file unless the user asks for a full
   replacement.
3. Use active option names only. Avoid legacy ignored fields unless you are
   explicitly removing or explaining them.
4. Prefer the smallest config that expresses the requested behavior. Defaults
   cover most UI and lifecycle settings.
5. For each process, choose either `shell` or `cmd`:
   - Use `shell` for pipes, redirects, globs, variable expansion, compound
     commands, or shell builtins.
   - Use `cmd` for direct executable + argument lists where shell interpolation
     is not needed.
   - If both are set, proctmux gives `shell` precedence, so avoid setting both.
6. When adding stop/restart behavior, document the effective signal and timeout.
   `stop` is a POSIX signal number, and `stop_timeout_ms` controls escalation to
   SIGKILL.
7. When adding `on_kill`, make it idempotent. It runs only for user-initiated
   stops/restarts, with the process `cwd` and `env`, and has a 30 second hook
   timeout.
8. Validate from the user's perspective: the config should be usable with
   `proctmux -f path/to/proctmux.yaml`, or discovered automatically when named
   `proctmux.yaml`, `proctmux.yml`, `procmux.yaml`, or `procmux.yml`.
9. Return YAML in a fenced `yaml` block unless editing a repository file
   directly. If editing directly, summarize the changed file and the relevant
   options used.

## Validation Checklist

Check generated configs against these constraints:

- Top-level active keys are `general`, `layout`, `style`, `keybinding`,
  `shell_cmd`, `log_file`, `stdout_debug_log_file`, and `procs`.
- `procs` is a map from display label to process config. Labels may contain
  spaces when quoted.
- List-valued fields must be YAML sequences of strings, not comma-separated
  strings.
- Boolean fields should be YAML booleans (`true`/`false`).
- Integer fields should be decimal numbers.
- `layout.processes_list_width` should be between 1 and 100; values `<= 0` or
  `> 100` reset to the default `30`.
- `style` color values currently support ANSI-style names and numeric ANSI
  color indexes; do not assume arbitrary hex colors are rendered by the TUI.
- `shell_cmd` is the global command prefix used for process `shell` strings.
  Effective default is `["sh", "-c"]`.
- `terminal_rows` and `terminal_cols` apply to each process PTY and default to
  `24` and `80` when omitted or non-positive.
- Unknown fields are ignored with warnings; do not rely on ignored legacy
  fields for behavior.

## Common Patterns

**Node app with PATH additions**

```yaml
procs:
  web:
    shell: "npm run dev"
    cwd: "."
    add_path: ["./node_modules/.bin"]
    autostart: true
    categories: ["frontend"]
```

**Direct command without shell interpolation**

```yaml
procs:
  worker:
    cmd: ["python", "-m", "myapp.worker"]
    env:
      WORKER_CONCURRENCY: "4"
    categories: ["worker"]
```

**Lifecycle cleanup**

```yaml
procs:
  stack:
    shell: "docker compose up"
    stop: 2
    stop_timeout_ms: 10000
    on_kill: ["docker", "compose", "down"]
```

## Output Style

When the user asks for a new file, provide a complete `proctmux.yaml` with
short comments only where they clarify a non-obvious choice. When the user asks
to modify an existing config, show only the relevant diff or edit the file
directly if you have workspace access.

When explaining options, cite the exact YAML path, such as
`procs.web.stop_timeout_ms` or `layout.hide_process_list_when_unfocused`.
