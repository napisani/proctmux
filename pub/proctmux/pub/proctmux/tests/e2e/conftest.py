from __future__ import annotations

import os
import re

import pytest

from harness import AgentTuiRunner, ProctmuxApp


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "go_name(name): legacy Go-style e2e test name")
    config._proctmux_e2e_failed = False


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    pattern = os.environ.get("E2E_RUN") or ""
    if not pattern:
        return

    selected: list[pytest.Item] = []
    deselected: list[pytest.Item] = []
    for item in items:
        names = [item.name, item.nodeid]
        names.extend(str(mark.args[0]) for mark in item.iter_markers(name="go_name") if mark.args)
        if any(re.search(pattern, name) for name in names):
            selected.append(item)
        else:
            deselected.append(item)

    if deselected:
        config.hook.pytest_deselected(items=deselected)
        items[:] = selected


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo[object]):
    outcome = yield
    report = outcome.get_result()
    if report.failed:
        item.config._proctmux_e2e_failed = True


@pytest.fixture(scope="session")
def runner(request: pytest.FixtureRequest) -> AgentTuiRunner:
    tui_runner = AgentTuiRunner()
    tui_runner.validate_tools()
    yield tui_runner
    keep_tmp = bool(request.config._proctmux_e2e_failed) or os.environ.get("KEEP_E2E_TMP") == "1"
    tui_runner.cleanup(keep_tmp=keep_tmp)


@pytest.fixture
def app(runner: AgentTuiRunner) -> ProctmuxApp:
    return ProctmuxApp(runner)
