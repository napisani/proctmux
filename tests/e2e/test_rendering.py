from __future__ import annotations

import fcntl
import os
import pty
import re
import shutil
import select
import struct
import subprocess
import termios
import textwrap
import time

import pytest

from harness import ProctmuxApp
from harness.agent_tui import PROCTMUX_BIN
from harness.assertions import (
    ansi_colored_word_found,
    expect,
    expect_ansi_colored_word,
    expect_contains,
    expect_not_contains,
    is_mostly_blank,
)


def run_tmux(tmux_socket: str, *args: str, timeout: float = 5.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["tmux", "-L", tmux_socket, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=True,
    )


def tmux_capture(tmux_socket: str, pane_id: str) -> str:
    return run_tmux(tmux_socket, "capture-pane", "-t", pane_id, "-p").stdout


def wait_tmux_pane(tmux_socket: str, pane_id: str, needle: str, *, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = tmux_capture(tmux_socket, pane_id)
        if needle in last:
            return last
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {needle!r}\n\nPane:\n{last}")


def compact_tmux_pane(text: str) -> str:
    return re.sub(r"\s+", "", text)


def attach_tmux_pty(tmux_socket: str, session: str) -> tuple[subprocess.Popen[bytes], int]:
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 220, 0, 0))
    env = os.environ.copy()
    env.update({"TERM": "xterm-256color"})
    proc = subprocess.Popen(
        ["tmux", "-L", tmux_socket, "attach-session", "-t", session],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)
    return proc, master_fd


def read_pty_until(master_fd: int, needle: bytes, *, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    captured = bytearray()
    while time.monotonic() < deadline:
        timeout_left = max(0.0, min(0.05, deadline - time.monotonic()))
        ready, _, _ = select.select([master_fd], [], [], timeout_left)
        if master_fd not in ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        captured.extend(chunk)
        if needle in captured:
            break
    return bytes(captured)


def read_pty_for(master_fd: int, *, duration: float) -> bytes:
    deadline = time.monotonic() + duration
    captured = bytearray()
    while time.monotonic() < deadline:
        timeout_left = max(0.0, min(0.05, deadline - time.monotonic()))
        ready, _, _ = select.select([master_fd], [], [], timeout_left)
        if master_fd not in ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        captured.extend(chunk)
    return bytes(captured)


def start_raw_unified_pty(config_dir, config_path):
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    env = os.environ.copy()
    env.update({"NO_COLOR": "1", "TERM": "xterm-256color"})
    proc = subprocess.Popen(
        [str(PROCTMUX_BIN), "--unified", "-f", str(config_path)],
        cwd=config_dir,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)
    return proc, master_fd


@pytest.mark.go_name("TestUnified_RapidStdout_NoExcessiveRepaints")
def test_rapid_stdout_no_excessive_repaints(app: ProctmuxApp) -> None:
    with app.unified(
        "rapid-stdout",
        """
        log_file: proctmux.log
        procs:
          rapid-output:
            shell: "i=1; while [ $i -le 500 ]; do echo LINE_$i; i=$((i + 1)); done; sleep 60"
            autostart: true
        """,
    ) as tui:
        tui.wait_for_text("rapid-output")
        tui.type("j")
        tui.wait_for_text("LINE_")
        samples = tui.samples(duration=2.0, interval=0.1)
        missing_label = [sample.text for sample in samples if "rapid-output" not in sample.text]
        blank = [sample.text for sample in samples if is_mostly_blank(sample.text)]
        expect(not missing_label, "process list disappeared during rapid output", missing_label[0] if missing_label else None)
        expect(not blank, "mostly blank frame observed during rapid output", blank[0] if blank else None)
        snap = tui.wait_stable(timeout_ms=10_000)
        expect_contains(snap, "rapid-output")
        expect_contains(snap, "LINE_")


@pytest.mark.go_name("TestUnified_Keypress_NoExcessiveFullClears")
def test_keypress_no_excessive_full_clears(app: ProctmuxApp) -> None:
    with app.unified(
        "keypress-clears",
        """
        log_file: proctmux.log
        procs:
          alpha-service:
            shell: "sleep 60"
          beta-worker:
            shell: "sleep 60"
        """,
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)
        samples = []
        for key in ["j", "k", "j", "k"]:
            tui.type(key)
            time.sleep(0.05)
            samples.extend(tui.samples(duration=0.2, interval=0.05))
        missing = [
            sample.text
            for sample in samples
            if "alpha-service" not in sample.text or "beta-worker" not in sample.text or is_mostly_blank(sample.text)
        ]
        expect(not missing, "process list flickered or blanked during navigation", missing[0] if missing else None)


@pytest.mark.go_name("TestUnified_CursorHiddenDuringNavigationAndOutput")
def test_cursor_hidden_during_navigation_and_output(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        snap = tui.wait_until("process list", lambda s: "cursor-output" in s.text and "idle-worker" in s.text)
        expect(not snap.cursor_visible, "cursor is visible after initial unified render", snap)
        snap = tui.wait_for_text("CURSOR_LINE_")
        expect(not snap.cursor_visible, "cursor is visible while selected process emits output", snap)
        tui.type("j")
        for key in ["j", "k", "j", "k"]:
            tui.type(key)
            time.sleep(0.075)
            snap = tui.snapshot()
            expect(not snap.cursor_visible, f"cursor is visible after navigation key {key!r}", snap)


@pytest.mark.go_name("TestUnified_OutputPreservesAnsiColors")
def test_unified_output_preserves_ansi_colors(app: ProctmuxApp) -> None:
    color_patterns = (
        (31, "Red"),
        (32, "Green"),
        (33, "Yellow"),
        (34, "Blue"),
    )
    with app.unified_left(
        "ansi-colors-preserved",
        """
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        shell_cmd:
          - "/bin/bash"
          - "-c"
        procs:
          "test ansi":
            shell: |
              echo -e '\\033[31mRed\\033[0m \\033[32mGreen\\033[0m \\033[33mYellow\\033[0m \\033[34mBlue\\033[0m'
              sleep 60
            autostart: true
        """,
        no_color=False,
    ) as tui:
        tui.wait_for_text("Red Green Yellow Blue")
        raw = tui.wait_until(
            "raw unified output with ANSI foreground colors",
            lambda snap: all(ansi_colored_word_found(snap.text, code, word) for code, word in color_patterns),
            retain_ansi=True,
        )
        for color_code, word in color_patterns:
            expect_ansi_colored_word(raw.text, color_code, word)


@pytest.mark.go_name("TestUnified_OutputHandlesCarriageReturnProgress")
def test_unified_output_handles_carriage_return_progress(app: ProctmuxApp) -> None:
    with app.unified(
        "carriage-return-progress",
        """
        log_file: proctmux.log
        procs:
          progress-output:
            shell: |
              printf 'progress 10%%'
              sleep 0.1
              printf '\\rprogress done\\r\\n'
              sleep 60
            autostart: true
        """,
    ) as tui:
        snap = tui.wait_for_text("progress done")
        expect_not_contains(snap, "progress 10%", "carriage-return progress update left stale text visible")


@pytest.mark.go_name("TestUnified_ProcessCursorControlsNotEmittedToOuterTerminal")
def test_unified_process_cursor_controls_not_emitted_to_outer_terminal(tmp_path) -> None:
    config_path = tmp_path / "proctmux.yaml"
    config_path.write_text(
        textwrap.dedent(
            """
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          term-start:
            shell: |
              printf '\\033[?25'
              sleep 0.15
              printf 'h'
              sleep 0.15
              printf '\\033[2'
              sleep 0.15
              printf ' q'
              sleep 0.35
              printf 'PROMPT_READY\\n'
              sleep 60
            autostart: false
        """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    proc, master_fd = start_raw_unified_pty(tmp_path, config_path)
    try:
        captured = bytearray(read_pty_until(master_fd, b"term-start", timeout=5.0))
        os.write(master_fd, b"j")
        os.write(master_fd, b"s")
        captured.extend(read_pty_until(master_fd, b"PROMPT_READY", timeout=5.0))
        captured.extend(read_pty_for(master_fd, duration=0.25))
        before_cleanup = bytes(captured)

        expect(b"PROMPT_READY" in before_cleanup, "process output did not reach raw unified PTY")
        expect(
            b"\x1b[2 q" not in before_cleanup,
            "cursor-shape escape was emitted to the outer terminal",
            before_cleanup.decode("utf-8", errors="replace"),
        )
        expect(
            b"\x1b[?25h" not in before_cleanup,
            "process show-cursor escape was emitted to the outer terminal",
            before_cleanup.decode("utf-8", errors="replace"),
        )
        last_prompt = before_cleanup.rfind(b"PROMPT_READY")
        last_hide = before_cleanup.rfind(b"\x1b[?25l")
        expect(
            last_hide > last_prompt,
            "unified did not re-hide the outer cursor after rendering process-start output",
            before_cleanup.decode("utf-8", errors="replace"),
        )
        sync_start = before_cleanup.find(b"\x1b[?2026h")
        sync_end = before_cleanup.find(b"\x1b[?2026l")
        expect(
            sync_start >= 0 and sync_end > sync_start,
            "unified process-start redraw was not bracketed by synchronized update mode",
            before_cleanup.decode("utf-8", errors="replace"),
        )
    finally:
        try:
            os.write(master_fd, b"q")
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        os.close(master_fd)


@pytest.mark.go_name("TestUnified_TmuxSplit_CursorPassthroughNotRendered")
def test_unified_tmux_split_cursor_passthrough_not_rendered(tmp_path) -> None:
    if shutil.which("tmux") is None:
        pytest.skip("tmux is required for this regression")

    config_path = tmp_path / "proctmux.yaml"
    config_path.write_text(
        textwrap.dedent(
            """
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          prompt-cursor:
            shell: |
              printf 'CURSOR_BEFORE'
              i=1
              while [ $i -le 12 ]; do
                printf '\\033[?25h'
                sleep 0.02
                printf '\\033[2 q'
                sleep 0.02
                printf '\\033Ptmux;\\033\\033[2 q\\033\\\\'
                printf 'CURSOR_LINE_%s\\n' "$i"
                i=$((i + 1))
              done
              printf 'CURSOR_AFTER\\n'
              sleep 60
            autostart: false
        """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    tmux_socket = f"proctmux-e2e-{os.getpid()}-{time.monotonic_ns()}"
    session = "cursor_passthrough"
    pane_id = ""
    attach_proc: subprocess.Popen[bytes] | None = None
    master_fd: int | None = None
    try:
        run_tmux(tmux_socket, "new-session", "-d", "-x", "220", "-y", "40", "-s", session, "sleep 60")
        pane_id = run_tmux(
            tmux_socket,
            "split-window",
            "-h",
            "-P",
            "-F",
            "#{pane_id}",
            "-t",
            f"{session}:0",
            "-c",
            str(tmp_path),
            f'TERM=tmux-256color NO_COLOR=1 "{PROCTMUX_BIN}" --unified -f "{config_path}"',
        ).stdout.strip()

        wait_tmux_pane(tmux_socket, pane_id, "prompt-cursor", timeout=5.0)
        attach_proc, master_fd = attach_tmux_pty(tmux_socket, session)
        read_pty_until(master_fd, b"prompt-cursor", timeout=5.0)
        read_pty_for(master_fd, duration=0.25)

        os.write(master_fd, b"j")
        os.write(master_fd, b"s")
        raw_after_start = read_pty_until(master_fd, b"CURSOR_AFTER", timeout=5.0)
        raw_after_start += read_pty_for(master_fd, duration=0.25)

        pane = wait_tmux_pane(tmux_socket, pane_id, "CURSOR_AFTER", timeout=5.0)
        time.sleep(0.25)
        pane += tmux_capture(tmux_socket, pane_id)

        compact = compact_tmux_pane(pane)
        expect("CURSOR_BEFORECURSOR_LINE_1" in compact, "cursor passthrough split expected output", pane)
        expect("CURSOR_LINE_12" in compact, "cursor passthrough split expected final output", pane)
        expect("CURSOR_AFTER" in compact, "cursor passthrough split expected final marker", pane)
        expect("CURSOR_BEFOREqCURSOR_LINE_1" not in compact, "cursor-shape final byte rendered in tmux split", pane)
        expect("tmux;" not in pane, "tmux passthrough wrapper rendered in unified output", pane)
        expect("[2 q" not in pane, "cursor-shape sequence text rendered in unified output", pane)
        expect(
            b"\x1b[2 q" not in raw_after_start,
            "cursor-shape escape reached the outer terminal through tmux during process start",
            raw_after_start.decode("utf-8", errors="replace"),
        )
        expect(
            b"\x1b[?25h" not in raw_after_start,
            "cursor-show escape reached the outer terminal through tmux during process start",
            raw_after_start.decode("utf-8", errors="replace"),
        )
    finally:
        if master_fd is not None:
            try:
                os.write(master_fd, b"q")
            except OSError:
                pass
        elif pane_id:
            run_tmux(tmux_socket, "send-keys", "-t", pane_id, "q", timeout=2.0)
        if attach_proc is not None:
            try:
                attach_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                attach_proc.terminate()
                try:
                    attach_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    attach_proc.kill()
                    attach_proc.wait(timeout=2)
        if master_fd is not None:
            os.close(master_fd)
        subprocess.run(["tmux", "-L", tmux_socket, "kill-session", "-t", session], timeout=5, check=False)


@pytest.mark.go_name("TestUnified_OutputRestoresMainScreenAfterAlternateScreen")
def test_unified_output_restores_main_screen_after_alternate_screen(app: ProctmuxApp) -> None:
    with app.unified(
        "alternate-screen-restore",
        """
        log_file: proctmux.log
        procs:
          alternate-output:
            shell: |
              printf 'main-screen\\r\\n'
              sleep 0.1
              printf '\\033[?1049h\\033[Halt-screen'
              sleep 0.1
              printf '\\033[?1049lafter-alt\\r\\n'
              sleep 60
            autostart: true
        """,
    ) as tui:
        snap = tui.wait_for_text("after-alt")
        expect_contains(snap, "main-screen")
        expect_not_contains(snap, "alt-screen", "alternate-screen contents remained visible after returning to main screen")
