#!/usr/bin/env python3
"""Compatibility launcher for the pytest-based agent-tui e2e suite."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    env = os.environ.copy()
    if len(sys.argv) > 1 and "AGENT_TUI_E2E_RUN" not in env:
        env["AGENT_TUI_E2E_RUN"] = "|".join(sys.argv[1:])

    tests_dir = Path(__file__).resolve().parent
    return subprocess.call([sys.executable, "-m", "pytest", "-q", "-s", str(tests_dir)], env=env)


if __name__ == "__main__":
    raise SystemExit(main())
