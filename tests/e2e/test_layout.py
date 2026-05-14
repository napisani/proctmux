from __future__ import annotations

import time

import pytest

from harness import ProctmuxApp
from harness.assertions import expect, expect_contains, expect_not_contains


@pytest.mark.go_name("TestUnified_DefaultConfig_ProcessListStaysVisible")
def test_default_config_process_list_stays_visible(app: ProctmuxApp) -> None:
    with app.unified(
        "default-visible",
        """
        log_file: proctmux.log
        procs:
          echo-default:
            shell: "echo DEFAULT_OUTPUT && sleep 60"
            autostart: true
        """,
    ) as tui:
        tui.wait_for_text("echo-default")
        tui.press("Ctrl+W")
        time.sleep(0.5)
        expect_contains(tui.snapshot(), "echo-default")


@pytest.mark.go_name("TestUnified_ExplicitFalse_ProcessListStaysVisible")
def test_explicit_false_process_list_stays_visible(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_for_text("echo-explicit")
        tui.press("Ctrl+W")
        time.sleep(0.5)
        expect_contains(tui.snapshot(), "echo-explicit")


@pytest.mark.go_name("TestUnified_HideOnUnfocus_CtrlW")
def test_hide_on_unfocus_ctrlw(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_for_text("hide-test")
        tui.press("Ctrl+W")
        tui.wait_until(
            "process list hidden after ctrl+w",
            lambda snap: "hide-test" not in snap.text and "process list hidden" in snap.text,
        )
        tui.press("Ctrl+W")
        tui.wait_for_text("hide-test")


@pytest.mark.go_name("TestUnified_HideOnUnfocus_FocusKeys")
def test_hide_on_unfocus_focus_keys(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_for_text("focus-key-test")
        tui.type("\x1b[1;5C")
        tui.wait_until(
            "process list hidden after ctrl+right",
            lambda snap: "focus-key-test" not in snap.text and "process list hidden" in snap.text,
        )
        tui.type("\x1b[1;5D")
        tui.wait_for_text("focus-key-test")


@pytest.mark.go_name("TestUnified_HideOnUnfocus_RestoreNoCrossPaneLeakage")
def test_hide_on_unfocus_restore_no_cross_pane_leakage(app: ProctmuxApp) -> None:
    proc_label = "sentinel-proc-UNIQUELABEL"
    proc_output = "PROCESS_OUTPUT_UNIQUETOKEN"
    with app.unified(
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
    ) as tui:
        tui.wait_for_text(proc_label)
        tui.press("Ctrl+W")
        tui.wait_for_text("process list hidden")
        tui.press("Ctrl+W")
        snap = tui.wait_for_text(proc_label)
        expect_not_contains(snap.client_text, proc_output, "process output leaked into client pane")


@pytest.mark.go_name("TestUnified_SideBySidePanesStaySeparatedWithLongProcessLabels")
def test_side_by_side_panes_stay_separated_with_long_process_labels(app: ProctmuxApp) -> None:
    output_token = "SPLIT_OK"
    long_label = "process-list-label-that-is-long-enough-to-cross-the-client-pane"
    with app.unified(
        "split-boundary",
        f"""
        log_file: proctmux.log
        procs:
          {long_label}:
            shell: "printf '{output_token}\\n'; sleep 60"
            autostart: true
        """,
    ) as tui:
        tui.wait_until(
            "split panes render expected content",
            lambda snap: long_label in snap.text and output_token in snap.text,
        )
        tui.resize(cols=80, rows=24)
        tui.type("k")
        snap = tui.wait_until("output token after resize", lambda candidate: output_token in candidate.text)
        found = snap.column_of(output_token)
        expect(found is not None, "output token missing after resize", snap)
        col, line = found or (-1, "")
        expect(" | " in line, f"split boundary missing from rendered line\nLine: {line!r}", snap)
        expect(
            col == 51,
            f"server output started at column {col}, want split boundary plus server output at column 51\nLine: {line!r}",
            snap,
        )


@pytest.mark.go_name("TestUnified_HideOnUnfocus_RapidToggleNoCrossLeakage")
def test_hide_on_unfocus_rapid_toggle_no_cross_leakage(app: ProctmuxApp) -> None:
    proc_label = "sentinel-rapid-UNIQUELABEL"
    proc_output = "PROCESS_OUTPUT_RAPID_TOKEN"
    with app.unified(
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
    ) as tui:
        tui.wait_for_text(proc_label)
        for _ in range(10):
            tui.press("Ctrl+W")
            time.sleep(0.05)
        snap = tui.wait_for_text(proc_label)
        expect_not_contains(snap.client_text, proc_output, "process output leaked into client pane after rapid toggle")
