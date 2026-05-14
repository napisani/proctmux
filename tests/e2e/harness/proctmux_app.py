from __future__ import annotations

from .agent_tui import AgentTuiRunner, Session


class ProctmuxApp:
    def __init__(self, runner: AgentTuiRunner) -> None:
        self.runner = runner

    def unified(
        self,
        name: str,
        config: str,
        *,
        cols: int = 120,
        rows: int = 40,
        no_color: bool = True,
    ) -> Session:
        return self.runner.start_unified(name, config, cols=cols, rows=rows, no_color=no_color)

    def unified_left(
        self,
        name: str,
        config: str,
        *,
        cols: int = 120,
        rows: int = 40,
        no_color: bool = True,
    ) -> Session:
        return self.runner.start_unified(
            name,
            config,
            cols=cols,
            rows=rows,
            unified_flag="--unified-left",
            no_color=no_color,
        )
