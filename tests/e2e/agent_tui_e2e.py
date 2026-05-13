#!/usr/bin/env python3
"""agent-tui backed end-to-end tests for the proctmux TUI."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Union


REPO_ROOT = Path(__file__).resolve().parents[2]
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


class Runner:
    def __init__(self) -> None:
        SHORT_TMP_PARENT.mkdir(parents=True, exist_ok=True)
        self.tmp_root = Path(tempfile.mkdtemp(prefix="ptm-e2e-", dir=str(SHORT_TMP_PARENT)))
        self.runtime_dir = Path(tempfile.mkdtemp(prefix="atui-", dir=str(SHORT_TMP_PARENT)))
        self.sessions: list[str] = []
        self.failures_dir = self.tmp_root / "failures"

        self.env = os.environ.copy()
        self.env.update(
            {
                "TMPDIR": str(self.runtime_dir),
                "AGENT_TUI_SESSION_STORE": str(self.tmp_root / "sessions.jsonl"),
                "AGENT_TUI_WS_STATE": str(self.tmp_root / "ws-state.json"),
                "AGENT_TUI_LOG": str(self.tmp_root / "agent-tui.log"),
                "AGENT_TUI_NO_INPUT": "1",
                "NO_COLOR": "1",
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

    def agent(self, args: list[str], *, timeout: float = 15.0, check: bool = True) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(
            [AGENT_TUI, *args],
            cwd=REPO_ROOT,
            env=self.env,
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

    def agent_json(self, args: list[str], *, timeout: float = 15.0) -> dict[str, object]:
        proc = self.agent(args, timeout=timeout)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as err:
            raise AgentTuiError(
                "agent-tui returned invalid JSON\n"
                f"command: {AGENT_TUI} {' '.join(args)}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            ) from err

    def write_config(self, name: str, body: str) -> tuple[Path, Path]:
        cfg_dir = self.tmp_root / slug(name)
        cfg_dir.mkdir()
        cfg_path = cfg_dir / "proctmux.yaml"
        cfg_path.write_text(body.strip() + "\n", encoding="utf-8")
        return cfg_dir, cfg_path

    def start_unified(self, name: str, config: str, *, cols: int = 120, rows: int = 40) -> "Session":
        cfg_dir, cfg_path = self.write_config(name, config)
        result = self.agent_json(
            [
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
                "--env",
                "NO_COLOR=1",
                str(PROCTMUX_BIN),
                "--",
                "--unified",
                "-f",
                str(cfg_path),
            ],
            timeout=20,
        )
        session_id = str(result["session_id"])
        self.sessions.append(session_id)
        return Session(self, session_id, name)

    def stop_daemon(self) -> None:
        self.agent(["daemon", "stop", "--json", "--yes"], timeout=5, check=False)

    def cleanup(self, *, keep_tmp: bool) -> None:
        for session_id in list(self.sessions):
            self.agent(["--session", session_id, "kill", "--json", "--yes"], timeout=5, check=False)
        self.sessions.clear()
        self.stop_daemon()
        if not keep_tmp:
            shutil.rmtree(self.tmp_root, ignore_errors=True)
            shutil.rmtree(self.runtime_dir, ignore_errors=True)

    def write_failure(self, test_name: str, text: str) -> Path:
        self.failures_dir.mkdir(exist_ok=True)
        path = self.failures_dir / f"{slug(test_name)}.txt"
        path.write_text(text, encoding="utf-8")
        return path


class Session:
    def __init__(self, runner: Runner, session_id: str, test_name: str) -> None:
        self.runner = runner
        self.session_id = session_id
        self.test_name = test_name

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
            self.type_text("q")
            time.sleep(0.25)
        except Exception:
            pass

    def snapshot(self) -> Snapshot:
        data = self.runner.agent_json(
            [
                "--session",
                self.session_id,
                "screenshot",
                "--json",
                "--strip-ansi",
                "--include-cursor",
            ],
            timeout=5,
        )
        return Snapshot(str(data.get("screenshot", "")), dict(data.get("cursor", {})))

    def wait_contains(self, needle: str, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            [
                "--session",
                self.session_id,
                "wait",
                "--json",
                "--assert",
                "-t",
                str(timeout_ms),
                needle,
            ],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            snap = self.snapshot()
            raise AssertionError(f"timed out waiting for {needle!r}\n{snap.text}")
        return self.snapshot()

    def wait_gone(self, needle: str, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            [
                "--session",
                self.session_id,
                "wait",
                "--json",
                "--assert",
                "--gone",
                "-t",
                str(timeout_ms),
                needle,
            ],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            snap = self.snapshot()
            raise AssertionError(f"timed out waiting for {needle!r} to disappear\n{snap.text}")
        return self.snapshot()

    def wait_stable(self, *, timeout_ms: int = 10_000) -> Snapshot:
        proc = self.runner.agent(
            [
                "--session",
                self.session_id,
                "wait",
                "--json",
                "--assert",
                "-t",
                str(timeout_ms),
                "--stable",
            ],
            timeout=(timeout_ms / 1000) + 3,
            check=False,
        )
        if proc.returncode != 0:
            snap = self.snapshot()
            raise AssertionError(f"timed out waiting for stable screenshot\n{snap.text}")
        return self.snapshot()

    def press(self, *keys: str) -> None:
        self.runner.agent_json(["--session", self.session_id, "press", "--json", *keys], timeout=5)

    def type_text(self, text: str) -> None:
        self.runner.agent_json(["--session", self.session_id, "type", "--json", text], timeout=5)

    def resize(self, *, cols: int, rows: int) -> None:
        self.runner.agent_json(
            [
                "--session",
                self.session_id,
                "resize",
                "--json",
                "--cols",
                str(cols),
                "--rows",
                str(rows),
            ],
            timeout=5,
        )


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", name).strip("-")


def expect(condition: bool, message: str, snap: Optional[Union[Snapshot, str]] = None) -> None:
    if condition:
        return
    if isinstance(snap, Snapshot):
        message = f"{message}\n\nSnapshot:\n{snap.text}"
    elif isinstance(snap, str):
        message = f"{message}\n\nSnapshot:\n{snap}"
    raise AssertionError(message)


def expect_contains(snap: Union[Snapshot, str], needle: str, message: Optional[str] = None) -> None:
    text = snap.text if isinstance(snap, Snapshot) else snap
    expect(needle in text, message or f"expected screenshot to contain {needle!r}", snap)


def expect_not_contains(snap: Union[Snapshot, str], needle: str, message: Optional[str] = None) -> None:
    text = snap.text if isinstance(snap, Snapshot) else snap
    expect(needle not in text, message or f"expected screenshot not to contain {needle!r}", snap)


def wait_for(
    sess: Session,
    description: str,
    predicate: Callable[[Snapshot], bool],
    *,
    timeout: float = 10.0,
    interval: float = 0.1,
) -> Snapshot:
    deadline = time.monotonic() + timeout
    last = sess.snapshot()
    while time.monotonic() < deadline:
        last = sess.snapshot()
        if predicate(last):
            return last
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {description}\n\nSnapshot:\n{last.text}")


def client_pane_text(snap: Union[Snapshot, str], cols: int = 30) -> str:
    text = snap.text if isinstance(snap, Snapshot) else snap
    return "\n".join(line[:cols] for line in text.splitlines())


def column_of(snap: Union[Snapshot, str], needle: str) -> Optional[tuple[int, str]]:
    text = snap.text if isinstance(snap, Snapshot) else snap
    for line in text.splitlines():
        idx = line.find(needle)
        if idx >= 0:
            return len(line[:idx]), line
    return None


def is_mostly_blank(text: str) -> bool:
    return sum(1 for ch in text if not ch.isspace()) < 8


def sample_for(sess: Session, duration: float, interval: float) -> list[Snapshot]:
    deadline = time.monotonic() + duration
    samples: list[Snapshot] = []
    while time.monotonic() < deadline:
        samples.append(sess.snapshot())
        time.sleep(interval)
    return samples


def test_default_config_process_list_stays_visible(runner: Runner) -> None:
    with runner.start_unified(
        "default-visible",
        """
log_file: proctmux.log
procs:
  echo-default:
    shell: "echo DEFAULT_OUTPUT && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains("echo-default")
        sess.press("Ctrl+W")
        time.sleep(0.5)
        expect_contains(sess.snapshot(), "echo-default")


def test_explicit_false_process_list_stays_visible(runner: Runner) -> None:
    with runner.start_unified(
        "explicit-false-visible",
        """
log_file: proctmux.log
layout:
  hide_process_list_when_unfocused: false
procs:
  echo-explicit:
    shell: "echo EXPLICIT_OUTPUT && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains("echo-explicit")
        sess.press("Ctrl+W")
        time.sleep(0.5)
        expect_contains(sess.snapshot(), "echo-explicit")


def test_hide_on_unfocus_ctrlw(runner: Runner) -> None:
    with runner.start_unified(
        "hide-ctrlw",
        """
log_file: proctmux.log
layout:
  hide_process_list_when_unfocused: true
procs:
  hide-test:
    shell: "echo HIDE_CTRLW_OUTPUT && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains("hide-test")
        sess.press("Ctrl+W")
        wait_for(
            sess,
            "process list hidden after ctrl+w",
            lambda snap: "hide-test" not in snap.text and "process list hidden" in snap.text,
        )
        sess.press("Ctrl+W")
        sess.wait_contains("hide-test")


def test_hide_on_unfocus_focus_keys(runner: Runner) -> None:
    with runner.start_unified(
        "hide-focus-keys",
        """
log_file: proctmux.log
layout:
  hide_process_list_when_unfocused: true
procs:
  focus-key-test:
    shell: "echo FOCUS_KEY_OUTPUT && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains("focus-key-test")
        sess.type_text("\x1b[1;5C")
        wait_for(
            sess,
            "process list hidden after ctrl+right",
            lambda snap: "focus-key-test" not in snap.text and "process list hidden" in snap.text,
        )
        sess.type_text("\x1b[1;5D")
        sess.wait_contains("focus-key-test")


def test_hide_on_unfocus_restore_no_cross_pane_leakage(runner: Runner) -> None:
    proc_label = "sentinel-proc-UNIQUELABEL"
    proc_output = "PROCESS_OUTPUT_UNIQUETOKEN"
    with runner.start_unified(
        "hide-restore-clean",
        f"""
log_file: proctmux.log
layout:
  hide_process_list_when_unfocused: true
procs:
  {proc_label}:
    shell: "echo {proc_output} && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains(proc_label)
        sess.press("Ctrl+W")
        sess.wait_contains("process list hidden")
        sess.press("Ctrl+W")
        snap = sess.wait_contains(proc_label)
        expect_not_contains(client_pane_text(snap), proc_output, "process output leaked into client pane")


def test_rapid_stdout_no_excessive_repaints(runner: Runner) -> None:
    with runner.start_unified(
        "rapid-stdout",
        """
log_file: proctmux.log
procs:
  rapid-output:
    shell: "i=1; while [ $i -le 500 ]; do echo LINE_$i; i=$((i + 1)); done; sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains("rapid-output")
        sess.type_text("j")
        sess.wait_contains("LINE_")
        samples = sample_for(sess, duration=2.0, interval=0.1)
        missing_label = [sample.text for sample in samples if "rapid-output" not in sample.text]
        blank = [sample.text for sample in samples if is_mostly_blank(sample.text)]
        expect(not missing_label, "process list disappeared during rapid output", missing_label[0] if missing_label else None)
        expect(not blank, "mostly blank frame observed during rapid output", blank[0] if blank else None)
        snap = sess.wait_stable(timeout_ms=10_000)
        expect_contains(snap, "rapid-output")
        expect_contains(snap, "LINE_")


def test_side_by_side_panes_stay_separated_with_long_process_labels(runner: Runner) -> None:
    output_token = "SPLIT_OK"
    long_label = "process-list-label-that-is-long-enough-to-cross-the-client-pane"
    with runner.start_unified(
        "split-boundary",
        f"""
log_file: proctmux.log
procs:
  {long_label}:
    shell: "printf '{output_token}\\n'; sleep 60"
    autostart: true
""",
    ) as sess:
        wait_for(sess, "split panes render expected content", lambda snap: long_label in snap.text and output_token in snap.text)
        sess.resize(cols=80, rows=24)
        sess.type_text("k")
        snap = wait_for(sess, "output token after resize", lambda candidate: output_token in candidate.text)
        found = column_of(snap, output_token)
        expect(found is not None, "output token missing after resize", snap)
        col, line = found or (-1, "")
        expect(
            col == 48,
            f"server output started at column {col}, want fixed split boundary 48\nLine: {line!r}",
            snap,
        )


def test_keypress_no_excessive_full_clears(runner: Runner) -> None:
    with runner.start_unified(
        "keypress-clears",
        """
log_file: proctmux.log
procs:
  alpha-service:
    shell: "sleep 60"
  beta-worker:
    shell: "sleep 60"
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)
        samples: list[Snapshot] = []
        for key in ["j", "k", "j", "k"]:
            sess.type_text(key)
            time.sleep(0.05)
            samples.extend(sample_for(sess, duration=0.2, interval=0.05))
        missing = [
            sample.text
            for sample in samples
            if "alpha-service" not in sample.text or "beta-worker" not in sample.text or is_mostly_blank(sample.text)
        ]
        expect(not missing, "process list flickered or blanked during navigation", missing[0] if missing else None)


def test_cursor_hidden_during_navigation_and_output(runner: Runner) -> None:
    with runner.start_unified(
        "cursor-hidden",
        """
log_file: proctmux.log
procs:
  cursor-output:
    shell: "i=1; while [ $i -le 60 ]; do echo CURSOR_LINE_$i; i=$((i + 1)); sleep 0.03; done; sleep 60"
    autostart: true
  idle-worker:
    shell: "sleep 60"
""",
    ) as sess:
        snap = wait_for(sess, "process list", lambda s: "cursor-output" in s.text and "idle-worker" in s.text)
        expect(not snap.cursor_visible, "cursor is visible after initial unified render", snap)
        sess.type_text("j")
        snap = sess.wait_contains("CURSOR_LINE_")
        expect(not snap.cursor_visible, "cursor is visible while selected process emits output", snap)
        for key in ["j", "k", "j", "k"]:
            sess.type_text(key)
            time.sleep(0.075)
            snap = sess.snapshot()
            expect(not snap.cursor_visible, f"cursor is visible after navigation key {key!r}", snap)


def test_process_switch_to_stopped_shows_only_placeholder(runner: Runner) -> None:
    stopped_stale_tail = "STOPPED_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    alpha_token = "ABCDEFGHIJK" + stopped_stale_tail
    with runner.start_unified(
        "switch-stopped",
        f"""
layout:
  placeholder_banner: "IDLE BANNER"
log_file: proctmux.log
procs:
  alpha-running:
    shell: "printf '{alpha_token}\\n'; sleep 60"
    autostart: true
  beta-stopped:
    shell: "sleep 60"
    autostart: false
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-running" in snap.text and "beta-stopped" in snap.text)
        sess.wait_contains(alpha_token)
        sess.type_text("j")
        snap = sess.wait_contains("IDLE BANNER")
        expect_not_contains(snap, stopped_stale_tail, "stale running-process output remained after selecting stopped process")


def test_process_switch_running_to_running_shows_only_active_output(runner: Runner) -> None:
    running_stale_tail = "RUNNING_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    beta_token = "BETA_OUTPUT"
    alpha_token = "ABCDEFGHIJK" + running_stale_tail
    with runner.start_unified(
        "switch-running",
        f"""
layout:
  placeholder_banner: "IDLE BANNER"
log_file: proctmux.log
procs:
  alpha-running:
    shell: "printf '{alpha_token}\\n'; sleep 60"
    autostart: true
  beta-running:
    shell: "printf '{beta_token}\\n'; sleep 60"
    autostart: true
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-running" in snap.text and "beta-running" in snap.text)
        sess.wait_contains(alpha_token)
        sess.type_text("j")
        snap = sess.wait_contains(beta_token)
        expect_not_contains(snap, running_stale_tail, "stale first-process output remained after selecting second running process")
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after selecting running process")


def test_select_never_run_process_shows_no_process_banner(runner: Runner) -> None:
    stale_tail = "NEVER_RUN_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    running_token = "RUNNING_BEFORE_NEVER_RUN_" + stale_tail
    with runner.start_unified(
        "never-run-selection",
        f"""
layout:
  placeholder_banner: "NO PROCESS"
log_file: proctmux.log
procs:
  alpha-running:
    shell: "printf '{running_token}\\n'; sleep 60"
    autostart: true
  beta-never-run:
    shell: "sleep 60"
    autostart: false
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        sess.wait_contains(running_token)
        sess.type_text("j")
        snap = sess.wait_contains("NO PROCESS")
        expect_not_contains(snap, stale_tail, "previous running-process output remained after selecting never-run process")


def test_select_exited_process_shows_last_run_output(runner: Runner) -> None:
    stale_tail = "EXITED_SELECTION_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    running_token = "RUNNING_BEFORE_EXITED_SELECTION_" + stale_tail
    exited_token = "EXITED_PROCESS_LAST_RUN_OUTPUT"
    with runner.start_unified(
        "exited-selection",
        f"""
layout:
  placeholder_banner: "NO PROCESS"
log_file: proctmux.log
procs:
  alpha-running:
    shell: "printf '{running_token}\\n'; sleep 60"
    autostart: true
  beta-exited:
    shell: "printf '{exited_token}\\n'"
    autostart: true
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-running" in snap.text and "beta-exited" in snap.text)
        sess.wait_contains(running_token)
        time.sleep(0.25)
        sess.type_text("j")
        snap = sess.wait_contains(exited_token)
        expect_not_contains(snap, stale_tail, "previous running-process output remained after selecting exited process")
        expect_not_contains(snap, "NO PROCESS", "NO PROCESS banner remained after selecting exited process with scrollback")


def test_start_selected_stopped_process_shows_its_output(runner: Runner) -> None:
    started_token = "START_SELECTED_OUTPUT"
    with runner.start_unified(
        "start-selected",
        f"""
layout:
  placeholder_banner: "IDLE BANNER"
log_file: proctmux.log
procs:
  start-target:
    shell: "printf '{started_token}\\n'; sleep 60"
    autostart: false
""",
    ) as sess:
        sess.wait_contains("start-target")
        sess.type_text("j")
        sess.wait_contains("IDLE BANNER")
        sess.type_text("s")
        snap = sess.wait_contains(started_token)
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after starting selected process")


def test_restart_selected_process_shows_restarted_output(runner: Runner) -> None:
    with runner.start_unified(
        "restart-selected",
        """
layout:
  placeholder_banner: "IDLE BANNER"
log_file: proctmux.log
procs:
  restart-target:
    shell: |
      n=0
      if [ -f restart-count.txt ]; then n=$(cat restart-count.txt); fi
      n=$((n + 1))
      printf '%s' "$n" > restart-count.txt
      printf 'RESTART_SELECTED_OUTPUT_%s\\n' "$n"
      sleep 60
    autostart: true
""",
    ) as sess:
        sess.wait_contains("restart-target")
        sess.wait_contains("RESTART_SELECTED_OUTPUT_1")
        sess.type_text("r")
        snap = sess.wait_contains("RESTART_SELECTED_OUTPUT_2")
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after restarting selected process")
        expect_not_contains(snap, "RESTART_SELECTED_OUTPUT_1", "previous run output remained after restarting selected process")


def test_hide_on_unfocus_rapid_toggle_no_cross_leakage(runner: Runner) -> None:
    proc_label = "sentinel-rapid-UNIQUELABEL"
    proc_output = "PROCESS_OUTPUT_RAPID_TOKEN"
    with runner.start_unified(
        "rapid-toggle-clean",
        f"""
log_file: proctmux.log
layout:
  hide_process_list_when_unfocused: true
procs:
  {proc_label}:
    shell: "echo {proc_output} && sleep 60"
    autostart: true
""",
    ) as sess:
        sess.wait_contains(proc_label)
        for _ in range(10):
            sess.press("Ctrl+W")
            time.sleep(0.05)
        snap = sess.wait_contains(proc_label)
        expect_not_contains(client_pane_text(snap), proc_output, "process output leaked into client pane after rapid toggle")


def test_filter_type_match_submit_escape(runner: Runner) -> None:
    with runner.start_unified(
        "filter-type-submit-escape",
        """
log_file: proctmux.log
procs:
  alpha-service:
    shell: "sleep 600"
    autostart: false
  beta-worker:
    shell: "sleep 600"
    autostart: false
  gamma-api:
    shell: "sleep 600"
    autostart: false
""",
    ) as sess:
        wait_for(
            sess,
            "all processes visible",
            lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text and "gamma-api" in snap.text,
        )
        sess.type_text("/")
        time.sleep(0.2)
        sess.type_text("alpha")
        snap = wait_for(sess, "alpha filter", lambda s: "alpha-service" in s.text)
        expect_contains(snap, "alpha-service")
        sess.press("Enter")
        time.sleep(0.2)
        expect_contains(sess.snapshot(), "alpha-service")
        sess.type_text("/")
        time.sleep(0.2)
        sess.type_text("zzz")
        time.sleep(0.3)
        sess.press("Escape")
        snap = wait_for(
            sess,
            "all processes restored after escape",
            lambda s: "alpha-service" in s.text and "beta-worker" in s.text and "gamma-api" in s.text,
        )
        expect_contains(snap, "alpha-service")


def test_filter_no_match_state(runner: Runner) -> None:
    with runner.start_unified(
        "filter-no-match",
        """
log_file: proctmux.log
procs:
  alpha-service:
    shell: "sleep 600"
    autostart: false
  beta-worker:
    shell: "sleep 600"
    autostart: false
""",
    ) as sess:
        wait_for(sess, "process list", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)
        sess.type_text("/")
        time.sleep(0.2)
        sess.type_text("zzzzz")
        snap = wait_for(
            sess,
            "no matching process entries",
            lambda s: "alpha-service" not in client_pane_text(s) and "beta-worker" not in client_pane_text(s),
        )
        expect_not_contains(client_pane_text(snap), "alpha-service")
        expect_not_contains(client_pane_text(snap), "beta-worker")
        sess.press("Enter")
        time.sleep(0.3)
        sess.type_text("/")
        time.sleep(0.2)
        sess.press("Escape")
        wait_for(sess, "processes restored", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)


def test_filter_navigation_while_filtered(runner: Runner) -> None:
    with runner.start_unified(
        "filter-navigation",
        """
log_file: proctmux.log
procs:
  alpha-one:
    shell: "sleep 600"
    autostart: false
  alpha-two:
    shell: "sleep 600"
    autostart: false
  beta-only:
    shell: "sleep 600"
    autostart: false
""",
    ) as sess:
        wait_for(
            sess,
            "all processes visible",
            lambda snap: "alpha-one" in snap.text and "alpha-two" in snap.text and "beta-only" in snap.text,
        )
        sess.type_text("/")
        time.sleep(0.2)
        sess.type_text("alpha")
        sess.press("Enter")
        snap = wait_for(
            sess,
            "both alpha processes visible",
            lambda s: "alpha-one" in client_pane_text(s) and "alpha-two" in client_pane_text(s),
        )
        expect_contains(client_pane_text(snap), "alpha-one")
        expect_contains(client_pane_text(snap), "alpha-two")
        sess.type_text("j")
        time.sleep(0.3)
        client = client_pane_text(sess.snapshot())
        expect_contains(client, "alpha-one", "expected alpha-one still visible after filtered navigation")
        expect_contains(client, "alpha-two", "expected alpha-two still visible after filtered navigation")


TESTS: list[tuple[str, Callable[[Runner], None]]] = [
    ("TestUnified_DefaultConfig_ProcessListStaysVisible", test_default_config_process_list_stays_visible),
    ("TestUnified_ExplicitFalse_ProcessListStaysVisible", test_explicit_false_process_list_stays_visible),
    ("TestUnified_HideOnUnfocus_CtrlW", test_hide_on_unfocus_ctrlw),
    ("TestUnified_HideOnUnfocus_FocusKeys", test_hide_on_unfocus_focus_keys),
    ("TestUnified_HideOnUnfocus_RestoreNoCrossPaneLeakage", test_hide_on_unfocus_restore_no_cross_pane_leakage),
    ("TestUnified_RapidStdout_NoExcessiveRepaints", test_rapid_stdout_no_excessive_repaints),
    ("TestUnified_SideBySidePanesStaySeparatedWithLongProcessLabels", test_side_by_side_panes_stay_separated_with_long_process_labels),
    ("TestUnified_Keypress_NoExcessiveFullClears", test_keypress_no_excessive_full_clears),
    ("TestUnified_CursorHiddenDuringNavigationAndOutput", test_cursor_hidden_during_navigation_and_output),
    ("TestUnified_ProcessSwitchToStoppedShowsOnlyPlaceholder", test_process_switch_to_stopped_shows_only_placeholder),
    ("TestUnified_ProcessSwitchRunningToRunningShowsOnlyActiveOutput", test_process_switch_running_to_running_shows_only_active_output),
    ("TestUnified_SelectNeverRunProcessShowsNoProcessBanner", test_select_never_run_process_shows_no_process_banner),
    ("TestUnified_SelectExitedProcessShowsLastRunOutput", test_select_exited_process_shows_last_run_output),
    ("TestUnified_StartSelectedStoppedProcessShowsItsOutput", test_start_selected_stopped_process_shows_its_output),
    ("TestUnified_RestartSelectedProcessShowsRestartedOutput", test_restart_selected_process_shows_restarted_output),
    ("TestUnified_HideOnUnfocus_RapidToggleNoCrossLeakage", test_hide_on_unfocus_rapid_toggle_no_cross_leakage),
    ("TestUnified_Filter_TypeMatchSubmitEscape", test_filter_type_match_submit_escape),
    ("TestUnified_Filter_NoMatchState", test_filter_no_match_state),
    ("TestUnified_Filter_NavigationWhileFiltered", test_filter_navigation_while_filtered),
]

SKIPPED: dict[str, str] = {
    "TestUnifiedErrorMessageExpires": "unified e2e pending deterministic TUI synchronization",
    "TestPrimaryClientStartProcess": "primary/client e2e pending tmux stub implementation",
}


def selected_pattern() -> str:
    if len(sys.argv) > 1:
        return "|".join(sys.argv[1:])
    return os.environ.get("AGENT_TUI_E2E_RUN") or os.environ.get("ZIG_E2E_RUN") or ""


def selected(pattern: str, name: str) -> bool:
    return not pattern or re.search(pattern, name) is not None


def main() -> int:
    pattern = selected_pattern()
    runner = Runner()
    failures = 0
    skipped = 0
    passed = 0

    try:
        runner.validate_tools()
        for name, reason in SKIPPED.items():
            if selected(pattern, name):
                print(f"=== RUN   {name}")
                print(f"--- SKIP: {name}: {reason}")
                skipped += 1

        tests = [(name, fn) for name, fn in TESTS if selected(pattern, name)]
        if not tests and not skipped:
            print(f"no e2e tests matched filter {pattern!r}", file=sys.stderr)
            return 2

        for name, fn in tests:
            print(f"=== RUN   {name}", flush=True)
            started = time.monotonic()
            try:
                fn(runner)
            except Exception as err:
                failures += 1
                elapsed = time.monotonic() - started
                details = "".join(traceback.format_exception(type(err), err, err.__traceback__))
                path = runner.write_failure(name, details)
                print(f"--- FAIL: {name} ({elapsed:.2f}s)")
                print(details.rstrip())
                print(f"failure details: {path}")
            else:
                passed += 1
                elapsed = time.monotonic() - started
                print(f"--- PASS: {name} ({elapsed:.2f}s)")
    finally:
        runner.cleanup(keep_tmp=failures > 0 or os.environ.get("KEEP_E2E_TMP") == "1")

    total = passed + failures + skipped
    print(f"PASS={passed} FAIL={failures} SKIP={skipped} TOTAL={total}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
