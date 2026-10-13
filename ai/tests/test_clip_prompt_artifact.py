"""The versioned clip prompt artifact loads and renders (FEAT-005, FEAT-007).

One clip path serves both a word clip (a FEAT-004 gloss phrase) and a phrase
clip (the reader's own idiom selection), so the direction must depict the
phrase's meaning and cover idioms rather than read every phrase literally.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from app.prompt import DEFAULT_CLIP_PROMPT_PATH, PROMPT_DIR, load_prompt


def test_loads_the_versioned_artifact() -> None:
    prompt = load_prompt(DEFAULT_CLIP_PROMPT_PATH)

    assert prompt.version == "word-clip-v2"
    assert "silent" in prompt.system
    assert "{phrase}" in prompt.user


def test_direction_shows_the_phrase_meaning_not_the_literal_words() -> None:
    system, _user = load_prompt(DEFAULT_CLIP_PROMPT_PATH).render(phrase="break the ice")

    # An idiom must be depicted by what it means, not by its literal words
    # (NFR-053: the clip is judged on whether it depicts the phrase's meaning).
    assert "meaning" in system
    assert "idiom" in system
    assert "literal" in system


def test_render_fills_the_phrase() -> None:
    _system, user = load_prompt(DEFAULT_CLIP_PROMPT_PATH).render(phrase="a key in the door")

    assert "a key in the door" in user


def test_the_previous_direction_is_kept_for_rollback() -> None:
    # The prompt loader convention keeps the previous version so the pin can be
    # diffed and rolled back.
    previous = load_prompt(PROMPT_DIR / "word_clip.v1.txt")

    assert previous.version == "word-clip-v1"


def test_malformed_artifact_is_rejected(tmp_path: Path) -> None:
    broken = tmp_path / "broken.txt"
    broken.write_text("version: x\n[system]\nhello\n", encoding="utf-8")

    with pytest.raises(ValueError):
        load_prompt(broken)
