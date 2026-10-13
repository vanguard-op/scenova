"""The versioned prompt artifact loads and renders (FEAT-004)."""

from __future__ import annotations

from pathlib import Path

import pytest
from app.prompt import load_prompt


def test_loads_the_versioned_artifact() -> None:
    prompt = load_prompt()

    assert prompt.version == "gloss-phrase-v2"
    assert "common" in prompt.system
    assert "six words" in prompt.system
    assert "{lemma}" in prompt.user


def test_render_fills_the_request_fields() -> None:
    system, user = load_prompt().render(
        lemma="key",
        part_of_speech="noun",
        sense_hint="a small metal object that opens a lock",
    )

    assert "key" in user
    assert "noun" in user
    assert "a small metal object that opens a lock" in user
    assert system


def test_malformed_artifact_is_rejected(tmp_path: Path) -> None:
    broken = tmp_path / "broken.txt"
    broken.write_text("version: x\n[system]\nhello\n", encoding="utf-8")

    with pytest.raises(ValueError):
        load_prompt(broken)
