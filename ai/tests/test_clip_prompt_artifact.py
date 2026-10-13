"""The versioned word-clip prompt artifact loads and renders (FEAT-005)."""

from __future__ import annotations

from pathlib import Path

import pytest
from app.prompt import DEFAULT_CLIP_PROMPT_PATH, load_prompt


def test_loads_the_versioned_artifact() -> None:
    prompt = load_prompt(DEFAULT_CLIP_PROMPT_PATH)

    assert prompt.version == "word-clip-v1"
    assert "silent" in prompt.system
    assert "{phrase}" in prompt.user


def test_render_fills_the_phrase() -> None:
    _system, user = load_prompt(DEFAULT_CLIP_PROMPT_PATH).render(phrase="a key in the door")

    assert "a key in the door" in user


def test_malformed_artifact_is_rejected(tmp_path: Path) -> None:
    broken = tmp_path / "broken.txt"
    broken.write_text("version: x\n[system]\nhello\n", encoding="utf-8")

    with pytest.raises(ValueError):
        load_prompt(broken)
