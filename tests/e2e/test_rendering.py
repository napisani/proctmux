from __future__ import annotations

import time

import pytest

from harness import ProctmuxApp
from harness.assertions import (
    ansi_colored_word_found,
    expect,
    expect_ansi_colored_word,
    expect_contains,
    expect_not_contains,
    is_mostly_blank,
)


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
