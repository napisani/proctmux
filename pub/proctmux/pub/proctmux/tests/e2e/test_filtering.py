from __future__ import annotations

import time

import pytest

from harness import ProctmuxApp
from harness.assertions import expect_contains, expect_not_contains


@pytest.mark.go_name("TestUnified_Filter_TypeMatchSubmitEscape")
def test_filter_type_match_submit_escape(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_until(
            "all processes visible",
            lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text and "gamma-api" in snap.text,
        )
        tui.type("/")
        time.sleep(0.2)
        tui.type("alpha")
        snap = tui.wait_until("alpha filter", lambda s: "alpha-service" in s.text)
        expect_contains(snap, "alpha-service")
        tui.press("Enter")
        time.sleep(0.2)
        expect_contains(tui.snapshot(), "alpha-service")
        tui.type("/")
        time.sleep(0.2)
        tui.type("zzz")
        time.sleep(0.3)
        tui.press("Escape")
        snap = tui.wait_until(
            "all processes restored after escape",
            lambda s: "alpha-service" in s.text and "beta-worker" in s.text and "gamma-api" in s.text,
        )
        expect_contains(snap, "alpha-service")


@pytest.mark.go_name("TestUnified_Filter_NoMatchState")
def test_filter_no_match_state(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_until("process list", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)
        tui.type("/")
        time.sleep(0.2)
        tui.type("zzzzz")
        snap = tui.wait_until(
            "no matching process entries",
            lambda s: "alpha-service" not in s.client_text and "beta-worker" not in s.client_text,
        )
        expect_not_contains(snap.client_text, "alpha-service")
        expect_not_contains(snap.client_text, "beta-worker")
        tui.press("Enter")
        time.sleep(0.3)
        tui.type("/")
        time.sleep(0.2)
        tui.press("Escape")
        tui.wait_until("processes restored", lambda snap: "alpha-service" in snap.text and "beta-worker" in snap.text)


@pytest.mark.go_name("TestUnified_Filter_ControlModifiedProcessListBindings")
def test_filter_control_modified_process_list_bindings(app: ProctmuxApp) -> None:
    with app.unified(
        "filter-control-process-list",
        """
        layout:
          placeholder_banner: "IDLE BANNER"
        log_file: proctmux.log
        procs:
          alpha-one:
            shell: "sleep 600"
            autostart: false
          alpha-two:
            shell: "printf 'ALPHA_TWO_STARTED\\n'; sleep 600"
            autostart: false
          beta-only:
            shell: "sleep 600"
            autostart: false
        """,
    ) as tui:
        tui.wait_until(
            "all processes visible",
            lambda snap: "alpha-one" in snap.text and "alpha-two" in snap.text and "beta-only" in snap.text,
        )
        tui.type("/")
        time.sleep(0.2)
        tui.type("alpha")
        tui.wait_until(
            "active filter with alpha matches",
            lambda snap: "Filter: alpha" in snap.client_text
            and "alpha-one" in snap.client_text
            and "alpha-two" in snap.client_text,
        )

        tui.press("Ctrl+J")
        snap = tui.wait_until(
            "ctrl+j moved selection down while filtering",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-two" in snap.client_text,
        )
        expect_contains(snap.client_text, "Filter: alpha")
        expect_not_contains(snap.client_text, "ctrl+j", "ctrl+j was inserted into the filter text")

        tui.press("Ctrl+K")
        tui.wait_until(
            "ctrl+k moved selection up while filtering",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-one" in snap.client_text,
        )

        tui.press("ArrowDown")
        tui.wait_until(
            "down arrow moved selection down while filtering",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-two" in snap.client_text,
        )
        tui.press("ArrowUp")
        tui.wait_until(
            "up arrow moved selection up while filtering",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-one" in snap.client_text,
        )

        tui.press("Ctrl+J")
        tui.wait_until(
            "alpha-two selected before start",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-two" in snap.client_text,
        )
        tui.press("Ctrl+S")
        snap = tui.wait_until(
            "ctrl+s started selected process while filtering",
            lambda snap: "Filter: alpha" in snap.client_text
            and "▶ ● alpha-two" in snap.client_text
            and "ALPHA_TWO_STARTED" in snap.server_text,
        )
        expect_contains(snap.client_text, "Filter: alpha")

        tui.press("Ctrl+X")
        snap = tui.wait_until(
            "ctrl+x stopped selected process while filtering",
            lambda snap: "Filter: alpha" in snap.client_text and "▶ ■ alpha-two" in snap.client_text,
        )
        expect_contains(snap.client_text, "Filter: alpha")


@pytest.mark.go_name("TestUnified_Filter_NavigationWhileFiltered")
def test_filter_navigation_while_filtered(app: ProctmuxApp) -> None:
    with app.unified(
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
    ) as tui:
        tui.wait_until(
            "all processes visible",
            lambda snap: "alpha-one" in snap.text and "alpha-two" in snap.text and "beta-only" in snap.text,
        )
        tui.type("/")
        time.sleep(0.2)
        tui.type("alpha")
        tui.press("Enter")
        snap = tui.wait_until(
            "both alpha processes visible",
            lambda s: "alpha-one" in s.client_text and "alpha-two" in s.client_text,
        )
        expect_contains(snap.client_text, "alpha-one")
        expect_contains(snap.client_text, "alpha-two")
        tui.type("j")
        time.sleep(0.3)
        client = tui.snapshot().client_text
        expect_contains(client, "alpha-one", "expected alpha-one still visible after filtered navigation")
        expect_contains(client, "alpha-two", "expected alpha-two still visible after filtered navigation")
