#!/usr/bin/env python3
"""Capture raw terminal key sequences for diagnosing proctmux key handling.

Run this from the same terminal environment where proctmux has the issue
(for example, inside the same tmux session/pane if that is where you use it).
"""

from __future__ import annotations

import json
import os
import select
import sys
import termios
import time
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Any


CAPTURE_STEPS = [
    ("plain j", "Press j"),
    ("plain k", "Press k"),
    ("plain s", "Press s"),
    ("plain x", "Press x"),
    ("enter", "Press Enter/Return"),
    ("ctrl+j", "Press Ctrl+J"),
    ("ctrl+k", "Press Ctrl+K"),
    ("ctrl+s", "Press Ctrl+S"),
    ("ctrl+x", "Press Ctrl+X"),
    ("up", "Press Up Arrow"),
    ("down", "Press Down Arrow"),
    ("ctrl+up", "Press Ctrl+Up Arrow"),
    ("ctrl+down", "Press Ctrl+Down Arrow"),
]

TIMEOUT_SECONDS = 8.0
SETTLE_SECONDS = 0.08


@dataclass
class CaptureResult:
    name: str
    prompt: str
    bytes_hex: list[str]
    bytes_int: list[int]
    python_repr: str
    timed_out: bool
    decoded_guess: str | None


def decode_guess(data: bytes) -> str | None:
    known = {
        b"j": "j",
        b"k": "k",
        b"s": "s",
        b"x": "x",
        b"\r": "enter/CR",
        b"\n": "ctrl+j/LF",
        b"\x0b": "ctrl+k/VT",
        b"\x13": "ctrl+s/DC3",
        b"\x18": "ctrl+x/CAN",
        b"\x1b[A": "up",
        b"\x1b[B": "down",
        b"\x1b[1;5A": "ctrl+up xterm",
        b"\x1b[1;5B": "ctrl+down xterm",
        b"\x1b[5A": "ctrl+up rxvt-ish",
        b"\x1b[5B": "ctrl+down rxvt-ish",
    }
    if data in known:
        return known[data]
    if data.startswith(b"\x1b[") and data.endswith(b"u"):
        return "CSI-u modified key sequence"
    if data.startswith(b"\x1b[27;") and data.endswith(b"~"):
        return "xterm modifyOtherKeys sequence"
    if data.startswith(b"\x1b"):
        return "escape sequence"
    if len(data) == 1 and data[0] < 0x20:
        return f"control byte 0x{data[0]:02x}"
    return None


def make_raw(fd: int) -> list[Any]:
    old_attrs = termios.tcgetattr(fd)
    raw = termios.tcgetattr(fd)

    # iflag: disable CR/LF translations and software flow control so Ctrl+S is capturable.
    raw[0] &= ~(termios.BRKINT | termios.ICRNL | termios.INPCK | termios.ISTRIP | termios.IXON)
    if hasattr(termios, "IXOFF"):
        raw[0] &= ~termios.IXOFF
    if hasattr(termios, "IXANY"):
        raw[0] &= ~termios.IXANY

    # oflag: no output post-processing.
    raw[1] &= ~termios.OPOST

    # cflag: 8-bit chars.
    raw[2] |= termios.CS8

    # lflag: raw input, no echo, no signals.
    raw[3] &= ~(termios.ECHO | termios.ICANON | termios.IEXTEN | termios.ISIG)

    raw[6][termios.VMIN] = 0
    raw[6][termios.VTIME] = 0

    termios.tcsetattr(fd, termios.TCSADRAIN, raw)
    return old_attrs


def read_key_event(fd: int, timeout: float) -> tuple[bytes, bool]:
    deadline = time.monotonic() + timeout
    chunks: list[bytes] = []

    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.1))
        if not ready:
            continue
        chunks.append(os.read(fd, 64))
        break

    if not chunks:
        return b"", True

    # Keep reading briefly so multi-byte escape sequences are captured together.
    settle_deadline = time.monotonic() + SETTLE_SECONDS
    while time.monotonic() < settle_deadline:
        ready, _, _ = select.select([fd], [], [], 0.01)
        if ready:
            chunks.append(os.read(fd, 64))
            settle_deadline = time.monotonic() + SETTLE_SECONDS

    return b"".join(chunks), False


def env_snapshot() -> dict[str, str | None]:
    keys = [
        "TERM",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "COLORTERM",
        "TMUX",
        "TMUX_PANE",
        "KITTY_WINDOW_ID",
        "WEZTERM_PANE",
        "ALACRITTY_WINDOW_ID",
        "GHOSTTY_RESOURCES_DIR",
    ]
    return {key: os.environ.get(key) for key in keys}


def main() -> int:
    if not sys.stdin.isatty():
        print("stdin is not a TTY; run this directly in the terminal with the issue", file=sys.stderr)
        return 2

    fd = sys.stdin.fileno()
    output_path = Path.cwd() / f"proctmux-key-capture-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    results: list[CaptureResult] = []

    print("proctmux key sequence capture", file=sys.stderr)
    print("Run this in the SAME terminal/tmux pane where proctmux misbehaves.", file=sys.stderr)
    print(f"Each prompt waits {TIMEOUT_SECONDS:.0f}s. If a key is swallowed, it records TIMEOUT.", file=sys.stderr)
    print("Do not hold the key down; press each combo once. Starting in 2 seconds...", file=sys.stderr)
    time.sleep(2)

    old_attrs = make_raw(fd)
    try:
        for index, (name, prompt) in enumerate(CAPTURE_STEPS, start=1):
            print(f"\r\n[{index}/{len(CAPTURE_STEPS)}] {prompt}: ", end="", file=sys.stderr, flush=True)
            data, timed_out = read_key_event(fd, TIMEOUT_SECONDS)
            result = CaptureResult(
                name=name,
                prompt=prompt,
                bytes_hex=[f"{byte:02x}" for byte in data],
                bytes_int=list(data),
                python_repr=repr(data),
                timed_out=timed_out,
                decoded_guess=None if timed_out else decode_guess(data),
            )
            results.append(result)
            if timed_out:
                print("TIMEOUT / no bytes", file=sys.stderr)
            else:
                hex_text = " ".join(result.bytes_hex)
                guess = f" ({result.decoded_guess})" if result.decoded_guess else ""
                print(f"{hex_text} {result.python_repr}{guess}", file=sys.stderr)
            time.sleep(0.25)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)

    payload = {
        "captured_at": datetime.now().isoformat(timespec="seconds"),
        "platform": sys.platform,
        "python": sys.version,
        "env": env_snapshot(),
        "results": [asdict(result) for result in results],
    }
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    print("\nSummary:", file=sys.stderr)
    for result in results:
        if result.timed_out:
            value = "TIMEOUT / no bytes"
        else:
            value = f"{' '.join(result.bytes_hex)} {result.python_repr}"
            if result.decoded_guess:
                value += f" ({result.decoded_guess})"
        print(f"  {result.name:10s} -> {value}", file=sys.stderr)
    print(f"\nWrote JSON results to: {output_path}", file=sys.stderr)
    print("Send me that JSON file or paste the Summary section.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
