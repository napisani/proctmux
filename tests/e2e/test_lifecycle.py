from __future__ import annotations

import os
import signal
import time
from pathlib import Path

import pytest

from harness import ProctmuxApp
from harness.assertions import expect


TARGET = "lifecycle-target"


def lifecycle_config(
    *,
    events_path: Path,
    run_count_path: Path,
    child_pid_path: Path,
    autostart: bool,
    stop_signal: int | None = None,
) -> str:
    stop_line = f"        stop: {stop_signal}\n" if stop_signal is not None else ""
    autostart_value = "true" if autostart else "false"
    return f"""
    layout:
      placeholder_banner: "IDLE"
    log_file: proctmux.log
    procs:
      {TARGET}:
        shell: |
          n=0
          if [ -f "{run_count_path}" ]; then n=$(cat "{run_count_path}"); fi
          n=$((n + 1))
          printf '%s\\n' "$n" > "{run_count_path}"
          printf 'RUN_%s\\n' "$n"
          trap 'printf "PARENT_TERM_%s\\n" "$n" >> "{events_path}"; exit 0' TERM
          trap 'printf "PARENT_INT_%s\\n" "$n" >> "{events_path}"; exit 0' INT
          child_loop() {{
            trap 'printf "CHILD_TERM_%s\\n" "$n" >> "{events_path}"; exit 0' TERM
            trap 'printf "CHILD_INT_%s\\n" "$n" >> "{events_path}"; exit 0' INT
            while :; do sleep 1; done
          }}
          child_loop &
          child_pid=$!
          printf '%s\\n' "$child_pid" > "{child_pid_path}"
          wait "$child_pid"
{stop_line}        stop_timeout_ms: 2000
        autostart: {autostart_value}
        on_kill:
          - sh
          - -c
          - 'n=$(cat "{run_count_path}" 2>/dev/null || printf 0); printf "ON_KILL_%s\\n" "$n" >> "{events_path}"'
    """


def wait_for_path_text(path: Path, needle: str, *, timeout: float = 8.0) -> str:
    deadline = time.monotonic() + timeout
    text = ""
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            if needle in text:
                return text
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {needle!r} in {path}\n\n{text}")


def wait_for_pid(path: Path, *, previous: int | None = None, timeout: float = 8.0) -> int:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        if path.exists():
            last = path.read_text(encoding="utf-8").strip()
            if last:
                pid = int(last)
                if previous is None or pid != previous:
                    return pid
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for pid in {path}; last value {last!r}")


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_pid_dead(pid: int, *, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not pid_is_alive(pid):
            return
        time.sleep(0.1)
    raise AssertionError(f"pid {pid} was still alive")


def kill_leftover_pid(pid: int | None) -> None:
    if pid is None or not pid_is_alive(pid):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return


def lifecycle_paths(app: ProctmuxApp, name: str) -> tuple[Path, Path, Path]:
    base = app.runner.tmp_root / name
    base.mkdir()
    return base / "events.txt", base / "run-count.txt", base / "child.pid"


@pytest.mark.go_name("TestUnified_StopSelectedWithOnKillTerminatesProcessGroup")
def test_stop_selected_with_on_kill_terminates_process_group(app: ProctmuxApp) -> None:
    events_path, run_count_path, child_pid_path = lifecycle_paths(app, "stop-default")
    child_pid_1: int | None = None
    child_pid_2: int | None = None

    try:
        with app.unified(
            "lifecycle-stop-default",
            lifecycle_config(
                events_path=events_path,
                run_count_path=run_count_path,
                child_pid_path=child_pid_path,
                autostart=True,
            ),
        ) as tui:
            tui.wait_for_text("RUN_1")
            child_pid_1 = wait_for_pid(child_pid_path)

            tui.type("x")

            wait_for_path_text(events_path, "ON_KILL_1")
            wait_for_path_text(events_path, "PARENT_TERM_1")
            wait_for_path_text(events_path, "CHILD_TERM_1")
            wait_for_pid_dead(child_pid_1)
            expect(f"{TARGET}\tstopped" in tui.signal("signal-list").stdout, "process did not stop")

            tui.type("s")
            tui.wait_for_text("RUN_2")
            child_pid_2 = wait_for_pid(child_pid_path, previous=child_pid_1)
            expect(child_pid_2 != child_pid_1, "restart after stop reused the old child process")
    finally:
        kill_leftover_pid(child_pid_1)
        kill_leftover_pid(child_pid_2)


@pytest.mark.go_name("TestUnified_RestartSelectedWithCustomSignalRunsOnKillAndReapsChildren")
def test_restart_selected_with_custom_signal_runs_on_kill_and_reaps_children(app: ProctmuxApp) -> None:
    events_path, run_count_path, child_pid_path = lifecycle_paths(app, "restart-int")
    child_pid_1: int | None = None
    child_pid_2: int | None = None

    try:
        with app.unified(
            "lifecycle-restart-int",
            lifecycle_config(
                events_path=events_path,
                run_count_path=run_count_path,
                child_pid_path=child_pid_path,
                autostart=True,
                stop_signal=2,
            ),
        ) as tui:
            tui.wait_for_text("RUN_1")
            child_pid_1 = wait_for_pid(child_pid_path)

            tui.type("r")

            tui.wait_for_text("RUN_2")
            child_pid_2 = wait_for_pid(child_pid_path, previous=child_pid_1)
            wait_for_path_text(events_path, "ON_KILL_1")
            wait_for_path_text(events_path, "PARENT_INT_1")
            wait_for_path_text(events_path, "CHILD_INT_1")
            wait_for_pid_dead(child_pid_1)
            expect(child_pid_2 != child_pid_1, "restart reused the old child process")
            expect(f"{TARGET}\trunning" in tui.signal("signal-list").stdout, "process was not running after restart")
    finally:
        kill_leftover_pid(child_pid_1)
        kill_leftover_pid(child_pid_2)


@pytest.mark.go_name("TestUnified_SignalCommandsStartRestartAndStopWithOnKill")
def test_signal_commands_start_restart_and_stop_with_on_kill(app: ProctmuxApp) -> None:
    events_path, run_count_path, child_pid_path = lifecycle_paths(app, "signal-commands")
    child_pid_1: int | None = None
    child_pid_2: int | None = None

    try:
        with app.unified(
            "lifecycle-signal-commands",
            lifecycle_config(
                events_path=events_path,
                run_count_path=run_count_path,
                child_pid_path=child_pid_path,
                autostart=False,
                stop_signal=2,
            ),
        ) as tui:
            tui.wait_for_text(TARGET)

            tui.signal("signal-start", TARGET)
            tui.wait_for_text("RUN_1")
            child_pid_1 = wait_for_pid(child_pid_path)
            expect(f"{TARGET}\trunning" in tui.signal("signal-list").stdout, "signal-start did not start process")

            tui.signal("signal-restart", TARGET)
            tui.wait_for_text("RUN_2")
            child_pid_2 = wait_for_pid(child_pid_path, previous=child_pid_1)
            wait_for_path_text(events_path, "ON_KILL_1")
            wait_for_path_text(events_path, "PARENT_INT_1")
            wait_for_path_text(events_path, "CHILD_INT_1")
            wait_for_pid_dead(child_pid_1)

            tui.signal("signal-stop", TARGET)
            wait_for_path_text(events_path, "ON_KILL_2")
            wait_for_path_text(events_path, "PARENT_INT_2")
            wait_for_path_text(events_path, "CHILD_INT_2")
            wait_for_pid_dead(child_pid_2)
            expect(f"{TARGET}\tstopped" in tui.signal("signal-list").stdout, "signal-stop did not stop process")
    finally:
        kill_leftover_pid(child_pid_1)
        kill_leftover_pid(child_pid_2)
