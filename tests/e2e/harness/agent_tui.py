from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BIN = REPO_ROOT / "bin" / "proctmux"
AGENT_TUI = os.environ.get("AGENT_TUI", "agent-tui")
PROCTMUX_BIN = Path(os.environ.get("PROCTMUX_E2E_BIN", str(DEFAULT_BIN))).resolve()
SHORT_TMP_PARENT = Path(os.environ.get("PROCTMUX_E2E_TMPDIR", "/tmp"))


class AgentTuiError(RuntimeError):
    pass


@dataclass
class Snapshot:
    text: str
    cursor: dict[str, object]

    @property
    def cursor_visible(self) -> bool:
        return bool(self.cursor.get("visible"))

    @property
    def client_text(self) -> str:
        return "\n".join(line[:30] for line in self.text.splitlines())

    @property
    def server_text(self) -> str:
        server_lines: list[str] = []
        for line in self.text.splitlines():
            if " | " in line:
                server_lines.append(line.split(" | ", 1)[1])
        return "\n".join(server_lines)

    def column_of(self, needle: str) -> Optional[tuple[int, str]]:
        for line in self.text.splitlines():
            idx = line.find(needle)
            if idx >= 0:
                return len(line[:idx]), line
        return None


class AgentTuiRunner:
    def __init__(self) -> None:
        SHORT_TMP_PARENT.mkdir(parents=True, exist_ok=True)
        self.tmp_root = Path(tempfile.mkdtemp(prefix="ptm-e2e-", dir=str(SHORT_TMP_PARENT)))
        self.runtime_dir = Path(tempfile.mkdtemp(prefix="atui-", dir=str(SHORT_TMP_PARENT)))
        self.sessions: list[str] = []

        self.env = os.environ.copy()
        self.env.pop("NO_COLOR", None)
        self.env.update(
            {
                "TMPDIR": str(self.runtime_dir),
                "AGENT_TUI_SESSION_STORE": str(self.tmp_root / "sessions.jsonl"),
                "AGENT_TUI_WS_STATE": str(self.tmp_root / "ws-state.json"),
                "AGENT_TUI_LOG": str(self.tmp_root / "agent-tui.log"),
                "AGENT_TUI_NO_INPUT": "1",
            }
        )

    def validate_tools(self) -> None:
        if not PROCTMUX_BIN.exists():
            raise AgentTuiError(f"missing proctmux binary: {PROCTMUX_BIN}")

        if "/" in AGENT_TUI:
            candidate = Path(AGENT_TUI)
            if not candidate.exists():
                raise AgentTuiError(f"missing agent-tui binary: {candidate}")
        elif shutil.which(AGENT_TUI, path=self.env.get("PATH")) is None:
            raise AgentTuiError(
                "agent-tui is not on PATH. Enter `nix develop` or set AGENT_TUI=/path/to/agent-tui."
            )

    def start_unified(
        self,
        name: str,
        config: str,
        *,
        cols: int = 120,
        rows: int = 40,
        unified_flag: str = "--unified",
        no_color: bool = True,
    ) -> "Session":
        cfg_dir, cfg_path = self.write_config(name, config)
        args = [
            "run",
            "--json",
            "--cwd",
            str(cfg_dir),
            "--cols",
            str(cols),
            "--rows",
            str(rows),
            "--env",
            "TERM=xterm-256color",
        ]
        if no_color:
            args.extend(["--env", "NO_COLOR=1"])
        args.extend([str(PROCTMUX_BIN), "--", unified_flag, "-f", str(cfg_path)])

        result = self.agent_json(args, timeout=20)
        session_id = str(result["session_id"])
        self.sessions.append(session_id)
        return Session(self, session_id)

    def write_config(self, name: str, body: str) -> tuple[Path, Path]:
        cfg_dir = self.tmp_root / slug(name)
        cfg_dir.mkdir()
        cfg_path = cfg_dir / "proctmux.yaml"
        cfg_path.write_text(textwrap.dedent(body).strip() + "\n", encoding="utf-8")
        return cfg_dir, cfg_path

    def agent(
        self,
        args: list[str],
        *,
        timeout: float = 15.0,
        check: bool = True,
        env_overrides: Optional[dict[str, Optional[str]]] = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if env_overrides:
            for key, value in env_overrides.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value

        proc = subprocess.run(
            [AGENT_TUI, *args],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            raise AgentTuiError(
                "agent-tui command failed\n"
                f"command: {AGENT_TUI} {' '.join(args)}\n"
                f"exit: {proc.returncode}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            )
        return proc

    def agent_json(
        self,
        args: list[str],
        *,
        timeout: float = 15.0,
        env_overrides: Optional[dict[str, Optional[str]]] = None,
    ) -> dict[str, object]:
        proc = self.agent(args, timeout=timeout, env_overrides=env_overrides)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as err:
            raise AgentTuiError(
                "agent-tui returned invalid JSON\n"
                f"command: {AGENT_TUI} {' '.join(args)}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            ) from err

    def cleanup(self, *, keep_tmp: bool) -> None:
        for session_id in list(self.sessions):
            self.agent(["--session", session_id, "kill", "--json", "--yes"], timeout=5, check=False)
        self.sessions.clear()
        self.agent(["daemon", "stop", "--json", "--yes"], timeout=5, check=False)
        if not keep_tmp:
            shutil.rmtree(self.tmp_root, ignore_errors=True)
            shutil.rmtree(self.runtime_dir, ignore_errors=True)


class Session:
    def __init__(self, runner: AgentTuiRunner, session_id: str) -> None:
        self.runner = runner
        self.session_id = session_id
        self.client = Pane(self, "client")
        self.server = Pane(self, "server")

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        self.request_quit()
        self.runner.agent(["--session", self.session_id, "kill", "--json", "--yes"], timeout=5, check=False)
        if self.session_id in self.runner.sessions:
            self.runner.sessions.remove(self.session_id)

    def request_quit(self) -> None:
        try:
            self.type("q")
            time.sleep(0.25)
        except Exception:
            pass

    def press(self, *keys: str) -> None:
        self.runner.agent_json(["--session", self.session_id, "press", "--json", *keys], timeout=5)

    def type(self, text: str) -> None:
        self.runner.agent_json(["--session", self.session_id, "type", "--json", text], timeout=5)

    def resize(self, *, cols: int, rows: int) -> None:
        self.runner.agent_json(
            ["--session", self.session_id, "resize", "--json", "--cols", str(cols), "--rows", str(rows)],
            timeout=5,
        )

    def snapshot(self, *, retain_ansi: bool = False) -> Snapshot:
        args = ["--session", self.session_id, "screenshot", "--json", "--include-cursor"]
        if retain_ansi:
            args.append("--retain-ansi")
        else:
            args.append("--strip-ansi")

        data = self.runner.agent_json(args, timeout=5, env_overrides={"NO_COLOR": None} if retain_ansi else None)
        return Snapshot(str(data.get("screenshot", "")), dict(data.get("cursor", {})))

    def wait_for_text(self, text: str, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            ["--session", self.session_id, "wait", "--json", "--assert", "-t", str(timeout_ms), text],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            raise AssertionError(f"timed out waiting for {text!r}\n{self.snapshot().text}")
        return self.snapshot()

    def wait_for_text_gone(self, text: str, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            ["--session", self.session_id, "wait", "--json", "--assert", "--gone", "-t", str(timeout_ms), text],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            raise AssertionError(f"timed out waiting for {text!r} to disappear\n{self.snapshot().text}")
        return self.snapshot()

    def wait_stable(self, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            ["--session", self.session_id, "wait", "--json", "--assert", "-t", str(timeout_ms), "--stable"],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            raise AssertionError(f"timed out waiting for stable screenshot\n{self.snapshot().text}")
        return self.snapshot()

    def wait_until(
        self,
        description: str,
        predicate: Callable[[Snapshot], bool],
        *,
        timeout: float = 10.0,
        interval: float = 0.1,
        retain_ansi: bool = False,
    ) -> Snapshot:
        deadline = time.monotonic() + timeout
        last = self.snapshot(retain_ansi=retain_ansi)
        while time.monotonic() < deadline:
            last = self.snapshot(retain_ansi=retain_ansi)
            if predicate(last):
                return last
            time.sleep(interval)
        raise AssertionError(f"timed out waiting for {description}\n\nSnapshot:\n{last.text}")

    def samples(self, *, duration: float, interval: float) -> list[Snapshot]:
        deadline = time.monotonic() + duration
        samples: list[Snapshot] = []
        while time.monotonic() < deadline:
            samples.append(self.snapshot())
            time.sleep(interval)
        return samples


class Pane:
    def __init__(self, session: Session, name: str) -> None:
        self.session = session
        self.name = name

    def text(self, snapshot: Optional[Snapshot] = None) -> str:
        snap = snapshot or self.session.snapshot()
        if self.name == "client":
            return snap.client_text
        return snap.server_text

    def wait_for_text(self, text: str, *, timeout: float = 10.0) -> Snapshot:
        return self.session.wait_until(
            f"{self.name} pane to contain {text!r}",
            lambda snap: text in self.text(snap),
            timeout=timeout,
        )


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", name).strip("-")
