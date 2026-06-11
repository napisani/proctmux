from __future__ import annotations

import pytest

from harness import ProctmuxApp
from harness.assertions import expect_contains, expect_not_contains


@pytest.mark.go_name("TestUnified_StdoutAndStderrVisibleAfterProcessExit")
def test_unified_stdout_and_stderr_visible_after_process_exit(app: ProctmuxApp) -> None:
    with app.unified(
        "unified-stdout-stderr-exit",
        """
        log_file: proctmux.log
        procs:
          stream-check:
            shell: |
              printf 'UNIFIED_STDOUT_BEFORE\\n'
              printf 'UNIFIED_STDERR_MIDDLE\\n' >&2
              printf 'UNIFIED_STDOUT_AFTER\\n'
            autostart: true
        """,
    ) as tui:
        snap = tui.wait_until(
            "unified stdout and stderr retained in server pane",
            lambda snap: "UNIFIED_STDOUT_BEFORE" in snap.server_text
            and "UNIFIED_STDERR_MIDDLE" in snap.server_text
            and "UNIFIED_STDOUT_AFTER" in snap.server_text,
        )
        expect_contains(snap.server_text, "UNIFIED_STDOUT_BEFORE")
        expect_contains(snap.server_text, "UNIFIED_STDERR_MIDDLE")
        expect_contains(snap.server_text, "UNIFIED_STDOUT_AFTER")


@pytest.mark.go_name("TestPrimary_StdoutAndStderrVisibleAfterProcessExit")
def test_primary_stdout_and_stderr_visible_after_process_exit(app: ProctmuxApp) -> None:
    with app.primary(
        "primary-stdout-stderr-exit",
        """
        log_file: proctmux.log
        procs:
          stream-check:
            shell: |
              printf 'PRIMARY_STDOUT_BEFORE\\n'
              printf 'PRIMARY_STDERR_MIDDLE\\n' >&2
              printf 'PRIMARY_STDOUT_AFTER\\n'
            autostart: true
        """,
    ) as tui:
        snap = tui.wait_until(
            "primary stdout and stderr retained in output",
            lambda snap: "PRIMARY_STDOUT_BEFORE" in snap.text
            and "PRIMARY_STDERR_MIDDLE" in snap.text
            and "PRIMARY_STDOUT_AFTER" in snap.text,
        )
        expect_contains(snap.text, "PRIMARY_STDOUT_BEFORE")
        expect_contains(snap.text, "PRIMARY_STDERR_MIDDLE")
        expect_contains(snap.text, "PRIMARY_STDOUT_AFTER")


@pytest.mark.go_name("TestUnified_TtyProcessOutputVisibleInServerPane")
def test_unified_tty_process_output_visible_in_server_pane(app: ProctmuxApp) -> None:
    with app.unified(
        "unified-tty-output",
        """
        log_file: proctmux.log
        procs:
          tty-check:
            shell: |
              if [ -t 0 ]; then printf 'UNIFIED_TTY_STDIN:YES\\n'; else printf 'UNIFIED_TTY_STDIN:NO\\n'; fi
              if [ -t 1 ]; then printf 'UNIFIED_TTY_STDOUT:YES\\n'; else printf 'UNIFIED_TTY_STDOUT:NO\\n'; fi
              if [ -t 2 ]; then printf 'UNIFIED_TTY_STDERR:YES\\n' >&2; else printf 'UNIFIED_TTY_STDERR:NO\\n' >&2; fi
              i=1
              while [ $i -le 12 ]; do
                printf 'UNIFIED_TTY_LINE_%02d\\n' "$i"
                i=$((i + 1))
              done
              sleep 60
            autostart: true
        """,
        rows=45,
    ) as tui:
        snap = tui.wait_until(
            "unified TTY status and output lines in server pane",
            lambda snap: "UNIFIED_TTY_STDIN:YES" in snap.server_text
            and "UNIFIED_TTY_STDOUT:YES" in snap.server_text
            and "UNIFIED_TTY_STDERR:YES" in snap.server_text
            and "UNIFIED_TTY_LINE_01" in snap.server_text
            and "UNIFIED_TTY_LINE_12" in snap.server_text,
        )
        expect_contains(snap.server_text, "UNIFIED_TTY_STDIN:YES")
        expect_contains(snap.server_text, "UNIFIED_TTY_STDOUT:YES")
        expect_contains(snap.server_text, "UNIFIED_TTY_STDERR:YES")
        expect_contains(snap.server_text, "UNIFIED_TTY_LINE_01")
        expect_contains(snap.server_text, "UNIFIED_TTY_LINE_12")


@pytest.mark.go_name("TestUnified_ShellReadHandlesBackspaceInput")
def test_unified_shell_read_handles_backspace_input(app: ProctmuxApp) -> None:
    with app.unified(
        "unified-shell-read-backspace",
        """
        shell_cmd:
          - /bin/bash
          - -c
        log_file: proctmux.log
        procs:
          interactive-name:
            shell: |
              echo 'Hello, what is your name?'
              read name
              echo "Nice to meet you, $name!"
            autostart: true
        """,
    ) as tui:
        tui.wait_for_text("Hello, what is your name?")
        tui.press("Tab")
        tui.type("abc")
        tui.press("Backspace")
        tui.type("d")
        tui.press("Enter")

        snap = tui.wait_for_text("Nice to meet you, abd!")
        expect_contains(snap.server_text, "Nice to meet you, abd!")
        expect_not_contains(snap.server_text, "^?", "backspace was rendered literally instead of editing shell read input")
        expect_not_contains(snap.server_text, "^H", "backspace was rendered literally instead of editing shell read input")


@pytest.mark.go_name("TestUnified_ReadlineStyleProcessHandlesEditedInput")
def test_unified_readline_style_process_handles_edited_input(app: ProctmuxApp) -> None:
    with app.unified(
        "unified-readline-edited-input",
        """
        shell_cmd:
          - /bin/bash
          - -lc
        log_file: proctmux.log
        procs:
          readline-check:
            shell: |
              python3 -c 'import readline, time; value = input("READLINE> "); print("READLINE_RESULT:" + value); time.sleep(60)'
            autostart: true
        """,
    ) as tui:
        tui.wait_for_text("READLINE>")
        tui.press("Tab")
        tui.type("abcz")
        tui.press("Backspace")
        tui.type("de")
        tui.type("\b")
        tui.press("Ctrl+A")
        tui.type("X")
        tui.press("Ctrl+E")
        tui.type("Y")
        tui.press("Enter")

        snap = tui.wait_for_text("READLINE_RESULT:XabcdY")
        expect_contains(snap.server_text, "READLINE_RESULT:XabcdY")
        expect_not_contains(snap.server_text, "^?", "backspace was rendered literally instead of editing input")
        expect_not_contains(snap.server_text, "^H", "backspace was rendered literally instead of editing input")


@pytest.mark.go_name("TestPrimary_TtyProcessOutputVisible")
def test_primary_tty_process_output_visible(app: ProctmuxApp) -> None:
    with app.primary(
        "primary-tty-output",
        """
        log_file: proctmux.log
        procs:
          tty-check:
            shell: |
              if [ -t 0 ]; then printf 'PRIMARY_TTY_STDIN:YES\\n'; else printf 'PRIMARY_TTY_STDIN:NO\\n'; fi
              if [ -t 1 ]; then printf 'PRIMARY_TTY_STDOUT:YES\\n'; else printf 'PRIMARY_TTY_STDOUT:NO\\n'; fi
              if [ -t 2 ]; then printf 'PRIMARY_TTY_STDERR:YES\\n' >&2; else printf 'PRIMARY_TTY_STDERR:NO\\n' >&2; fi
              i=1
              while [ $i -le 12 ]; do
                printf 'PRIMARY_TTY_LINE_%02d\\n' "$i"
                i=$((i + 1))
              done
              sleep 60
            autostart: true
        """,
        rows=45,
    ) as tui:
        snap = tui.wait_until(
            "primary TTY status and output lines",
            lambda snap: "PRIMARY_TTY_STDIN:YES" in snap.text
            and "PRIMARY_TTY_STDOUT:YES" in snap.text
            and "PRIMARY_TTY_STDERR:YES" in snap.text
            and "PRIMARY_TTY_LINE_01" in snap.text
            and "PRIMARY_TTY_LINE_12" in snap.text,
        )
        expect_contains(snap.text, "PRIMARY_TTY_STDIN:YES")
        expect_contains(snap.text, "PRIMARY_TTY_STDOUT:YES")
        expect_contains(snap.text, "PRIMARY_TTY_STDERR:YES")
        expect_contains(snap.text, "PRIMARY_TTY_LINE_01")
        expect_contains(snap.text, "PRIMARY_TTY_LINE_12")
