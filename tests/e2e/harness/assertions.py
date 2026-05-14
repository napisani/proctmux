from __future__ import annotations

import re

from .agent_tui import Snapshot


def expect(condition: bool, message: str, snapshot: Snapshot | str | None = None) -> None:
    if condition:
        return
    if isinstance(snapshot, Snapshot):
        message = f"{message}\n\nSnapshot:\n{snapshot.text}"
    elif isinstance(snapshot, str):
        message = f"{message}\n\nSnapshot:\n{snapshot}"
    raise AssertionError(message)


def expect_contains(snapshot: Snapshot | str, needle: str, message: str | None = None) -> None:
    text = snapshot.text if isinstance(snapshot, Snapshot) else snapshot
    expect(needle in text, message or f"expected screenshot to contain {needle!r}", snapshot)


def expect_not_contains(snapshot: Snapshot | str, needle: str, message: str | None = None) -> None:
    text = snapshot.text if isinstance(snapshot, Snapshot) else snapshot
    expect(needle not in text, message or f"expected screenshot not to contain {needle!r}", snapshot)


def ansi_colored_word_found(text: str, color_code: int, word: str) -> bool:
    accepted_codes = [str(color_code)]
    if 30 <= color_code <= 37:
        accepted_codes.append(f"38;5;{color_code - 30}")

    ansi_between_color_and_word = r"(?:\x1b\[[0-9;]*m)*"
    return any(
        re.search(rf"\x1b\[[0-9;]*{re.escape(code)}m{ansi_between_color_and_word}{re.escape(word)}", text)
        is not None
        for code in accepted_codes
    )


def expect_ansi_colored_word(text: str, color_code: int, word: str) -> None:
    expect(
        ansi_colored_word_found(text, color_code, word),
        f"expected {word!r} to be rendered with ANSI color code {color_code}",
        text,
    )


def is_mostly_blank(text: str) -> bool:
    return sum(1 for ch in text if not ch.isspace()) < 8
