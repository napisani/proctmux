# proctmux Context

## Domain Vocabulary

- **Runtime Mode**: One of primary, client, unified, or signal command execution.
- **Primary Server**: The process-owning runtime that manages app state, process lifecycle, IPC command handling, and state broadcasts.
- **Client Session**: The TUI-facing runtime that reads IPC snapshots, renders process lists, and sends process commands.
- **Client Snapshot**: The client-visible replacement state sent over IPC, including UI settings and process summaries but excluding process execution config.
- **Process Command**: A user or IPC command that targets process lifecycle or selection, including command semantics such as target requirements and snapshot synchronization behavior.
- **Unified Runtime**: The single-terminal runtime that composes a primary server pane and client process-list pane in one split model.
- **Project Config**: The loaded `proctmux.yaml` configuration after defaults and discovery have been applied.
- **Discovery**: The Makefile/package.json process discovery pass that merges discovered processes into Project Config.
- **IPC Protocol**: The versioned JSON-over-newline Unix socket protocol for snapshots, commands, and responses.
- **Terminal Renderer**: The code that converts process terminal output bytes into printable text for unified mode.
- **Process Controller**: The runtime owner of PTY/pipe processes, scrollback capture, stop/cleanup behavior, and `on_kill` hooks.
