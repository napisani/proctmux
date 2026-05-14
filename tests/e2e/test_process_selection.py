from __future__ import annotations

import time

import pytest

from harness import ProctmuxApp
from harness.assertions import expect, expect_contains, expect_not_contains


@pytest.mark.go_name("TestUnified_ProcessSwitchToStoppedShowsOnlyPlaceholder")
def test_process_switch_to_stopped_shows_only_placeholder(app: ProctmuxApp) -> None:
    stopped_stale_tail = "STOPPED_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    alpha_token = "ABCDEFGHIJK" + stopped_stale_tail
    with app.unified(
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
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-stopped" in snap.text)
        tui.wait_for_text(alpha_token)
        tui.type("j")
        snap = tui.wait_for_text("IDLE BANNER")
        expect_not_contains(snap, stopped_stale_tail, "stale running-process output remained after selecting stopped process")


@pytest.mark.go_name("TestUnified_ProcessSwitchRunningToRunningShowsOnlyActiveOutput")
def test_process_switch_running_to_running_shows_only_active_output(app: ProctmuxApp) -> None:
    running_stale_tail = "RUNNING_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    beta_token = "BETA_OUTPUT"
    alpha_token = "ABCDEFGHIJK" + running_stale_tail
    with app.unified(
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
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-running" in snap.text)
        tui.wait_for_text(alpha_token)
        tui.type("j")
        snap = tui.wait_for_text(beta_token)
        expect_not_contains(snap, running_stale_tail, "stale first-process output remained after selecting second running process")
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after selecting running process")


@pytest.mark.go_name("TestUnified_SelectNeverRunProcessShowsNoProcessBanner")
def test_select_never_run_process_shows_no_process_banner(app: ProctmuxApp) -> None:
    stale_tail = "NEVER_RUN_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    running_token = "RUNNING_BEFORE_NEVER_RUN_" + stale_tail
    with app.unified(
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
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        tui.wait_for_text(running_token)
        tui.type("j")
        snap = tui.wait_for_text("NO PROCESS")
        expect_not_contains(snap, stale_tail, "previous running-process output remained after selecting never-run process")


@pytest.mark.go_name("TestUnified_SelectNeverRunProcessClearsMultilineRunningOutput")
def test_select_never_run_process_clears_multiline_running_output(app: ProctmuxApp) -> None:
    stale_tail = "BLEED_ALPHA_NEVER_RUN_120"
    with app.unified(
        "never-run-clears-multiline",
        """
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          alpha-running:
            shell: |
              i=1
              while [ $i -le 120 ]; do
                printf 'BLEED_ALPHA_NEVER_RUN_%03d\\n' "$i"
                i=$((i + 1))
              done
              sleep 60
            autostart: true
          beta-never-run:
            shell: "sleep 60"
            autostart: false
        """,
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        tui.wait_for_text(stale_tail)
        tui.type("j")
        tui.wait_for_text("NO PROCESS")
        snap = tui.wait_stable(timeout_ms=5_000)
        expect_contains(snap, "NO PROCESS")
        expect_not_contains(snap, stale_tail, "multiline running-process output bled into never-run process view")


@pytest.mark.go_name("TestUnified_SelectNeverRunProcessDoesNotReceiveLiveOutputFromPreviousProcess")
def test_select_never_run_process_does_not_receive_live_output_from_previous_process(app: ProctmuxApp) -> None:
    live_token = "LIVE_ALPHA_STILL_RUNNING_"
    with app.unified(
        "never-run-no-live-bleed",
        f"""
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          alpha-running:
            shell: |
              i=1
              while [ $i -le 200 ]; do
                printf '{live_token}%03d\\n' "$i"
                i=$((i + 1))
                sleep 0.03
              done
              sleep 60
            autostart: true
          beta-never-run:
            shell: "sleep 60"
            autostart: false
        """,
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        tui.wait_for_text(f"{live_token}005")
        tui.type("j")
        tui.wait_for_text("NO PROCESS")
        leaked = [sample for sample in tui.samples(duration=1.0, interval=0.05) if live_token in sample.text]
        expect(not leaked, "live output from previous running process appeared after selecting never-run process", leaked[0] if leaked else None)


@pytest.mark.go_name("TestUnified_UnifiedLeftRunningFirstWrapToInactiveShowsNoProcess")
def test_unified_left_running_first_wrap_to_inactive_shows_no_process(app: ProctmuxApp) -> None:
    with app.unified_left(
        "unified-left-running-first-wrap",
        """
        layout:
          hide_process_list_when_unfocused: true
          sort_process_list_running_first: true
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        shell_cmd:
          - "/bin/bash"
          - "-c"
        procs:
          "test ansi":
            shell: |
              while true; do
                echo -e '\\033[31mRed\\033[0m \\033[32mGreen\\033[0m \\033[33mYellow\\033[0m \\033[34mBlue\\033[0m'
                sleep 0.05
              done
            autostart: true
          "long running print":
            shell: "echo 'some text here' && sleep 60"
            autostart: true
          "inactive middle":
            shell: "printf 'INACTIVE_MIDDLE_OUTPUT\\n'"
            autostart: false
          "inactive wrap-target":
            shell: "printf 'INACTIVE_WRAP_OUTPUT\\n'"
            autostart: false
        """,
    ) as tui:
        tui.wait_until(
            "running output and inactive process list",
            lambda snap: ("Red Green Yellow Blue" in snap.text or "some text here" in snap.text)
            and "inactive wrap-target" in snap.text,
        )
        tui.type("k")
        snap = tui.wait_for_text("NO PROCESS")
        expect_contains(snap, "inactive wrap-target")
        expect_not_contains(snap, "Red Green Yellow Blue", "running process output remained after wrapping to inactive process")
        expect_not_contains(snap, "some text here", "running process output remained after wrapping to inactive process")


@pytest.mark.go_name("TestUnified_UnifiedLeftTestAnsiToInactiveFastOutputClearsServerPane")
def test_unified_left_test_ansi_to_inactive_fast_output_clears_server_pane(app: ProctmuxApp) -> None:
    with app.unified_left(
        "unified-left-test-ansi-fast-output",
        """
        layout:
          sort_process_list_running_first: true
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        shell_cmd:
          - "/bin/bash"
          - "-c"
        procs:
          "long running print":
            shell: "echo 'some text here' && sleep 60"
            autostart: true
          "test ansi":
            shell: |
              while true; do
                echo -e '\\033[31mRed\\033[0m \\033[32mGreen\\033[0m \\033[33mYellow\\033[0m \\033[34mBlue\\033[0m'
                sleep 0.05
              done
            autostart: true
          "fast output":
            shell: "printf 'FAST_OUTPUT_SHOULD_NOT_RUN\\n'"
            autostart: false
        """,
    ) as tui:
        tui.wait_until("initial running process list", lambda snap: "long running print" in snap.text and "test ansi" in snap.text)
        tui.type("j")
        test_ansi_snap = tui.wait_until(
            "test ansi selected with its output in server pane",
            lambda snap: "▶ ● test ansi" in snap.text and "Red Green Yellow Blue" in snap.server_text,
        )
        expect_contains(test_ansi_snap.server_text, "Red Green Yellow Blue")

        tui.type("j")
        fast_output_snap = tui.wait_until(
            "inactive fast output selected with server pane placeholder",
            lambda snap: "▶ ■ fast output" in snap.text and "NO PROCESS" in snap.server_text,
        )
        expect_contains(fast_output_snap.server_text, "NO PROCESS")
        expect_not_contains(
            fast_output_snap.server_text,
            "Red Green Yellow Blue",
            "test ansi output remained in the server pane after selecting inactive fast output",
        )


@pytest.mark.go_name("TestUnified_SelectNeverRunProcessAfterHiddenServerFocusClearsPreviousOutput")
def test_select_never_run_process_after_hidden_server_focus_clears_previous_output(app: ProctmuxApp) -> None:
    stale_tail = "HIDDEN_FOCUS_ALPHA_120"
    with app.unified(
        "hidden-focus-never-run-clean",
        """
        layout:
          hide_process_list_when_unfocused: true
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          alpha-running:
            shell: |
              i=1
              while [ $i -le 120 ]; do
                printf 'HIDDEN_FOCUS_ALPHA_%03d\\n' "$i"
                i=$((i + 1))
              done
              sleep 60
            autostart: true
          beta-never-run:
            shell: "sleep 60"
            autostart: false
        """,
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        tui.press("Ctrl+W")
        tui.wait_until("server pane focused with process list hidden", lambda snap: "process list hidden" in snap.text)
        tui.wait_for_text(stale_tail)
        tui.press("Ctrl+W")
        tui.wait_until("process list restored", lambda snap: "alpha-running" in snap.text and "beta-never-run" in snap.text)
        tui.type("j")
        tui.wait_for_text("NO PROCESS")
        snap = tui.wait_stable(timeout_ms=5_000)
        expect_contains(snap, "NO PROCESS")
        expect_not_contains(snap, stale_tail, "hidden server-focus output remained after selecting never-run process")


@pytest.mark.go_name("TestUnified_SelectExitedProcessShowsLastRunOutput")
def test_select_exited_process_shows_last_run_output(app: ProctmuxApp) -> None:
    stale_tail = "EXITED_SELECTION_STALE_SUFFIX_abcdefghijklmnopqrstuvwxyz"
    running_token = "RUNNING_BEFORE_EXITED_SELECTION_" + stale_tail
    exited_token = "EXITED_PROCESS_LAST_RUN_OUTPUT"
    with app.unified(
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
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-exited" in snap.text)
        tui.wait_for_text(running_token)
        time.sleep(0.25)
        tui.type("j")
        snap = tui.wait_for_text(exited_token)
        expect_not_contains(snap, stale_tail, "previous running-process output remained after selecting exited process")
        expect_not_contains(snap, "NO PROCESS", "NO PROCESS banner remained after selecting exited process with scrollback")


@pytest.mark.go_name("TestUnified_SelectExitedProcessClearsMultilineRunningOutput")
def test_select_exited_process_clears_multiline_running_output(app: ProctmuxApp) -> None:
    stale_tail = "BLEED_ALPHA_EXITED_120"
    exited_token = "EXITED_SHORT_OUTPUT"
    with app.unified(
        "exited-clears-multiline",
        f"""
        layout:
          placeholder_banner: "NO PROCESS"
        log_file: proctmux.log
        procs:
          alpha-running:
            shell: |
              i=1
              while [ $i -le 120 ]; do
                printf 'BLEED_ALPHA_EXITED_%03d\\n' "$i"
                i=$((i + 1))
              done
              sleep 60
            autostart: true
          beta-exited:
            shell: "printf '{exited_token}\\n'"
            autostart: true
        """,
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-running" in snap.text and "beta-exited" in snap.text)
        tui.wait_for_text(stale_tail)
        time.sleep(0.25)
        tui.type("j")
        tui.wait_for_text(exited_token)
        snap = tui.wait_stable(timeout_ms=5_000)
        expect_contains(snap, exited_token)
        expect_not_contains(snap, stale_tail, "multiline running-process output bled into exited process view")


@pytest.mark.go_name("TestUnified_StartSelectedStoppedProcessShowsItsOutput")
def test_start_selected_stopped_process_shows_its_output(app: ProctmuxApp) -> None:
    started_token = "START_SELECTED_OUTPUT"
    with app.unified(
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
    ) as tui:
        tui.wait_for_text("start-target")
        tui.type("j")
        tui.wait_for_text("IDLE BANNER")
        tui.type("s")
        snap = tui.wait_for_text(started_token)
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after starting selected process")


@pytest.mark.go_name("TestUnified_RestartSelectedProcessShowsRestartedOutput")
def test_restart_selected_process_shows_restarted_output(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_for_text("restart-target")
        tui.wait_for_text("RESTART_SELECTED_OUTPUT_1")
        tui.type("r")
        snap = tui.wait_for_text("RESTART_SELECTED_OUTPUT_2")
        expect_not_contains(snap, "IDLE BANNER", "placeholder remained after restarting selected process")
        expect_not_contains(snap, "RESTART_SELECTED_OUTPUT_1", "previous run output remained after restarting selected process")
