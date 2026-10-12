"""Bundled data resources for the model-serving layer."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent / "data"
DEFAULT_COMMON_WORDS_PATH = DATA_DIR / "common_words.txt"


@lru_cache(maxsize=4)
def load_common_words(path: str | None = None) -> frozenset[str]:
    """Load the common-word vocabulary the gloss guardrail checks against.

    The list is bundled so the check is offline and deterministic; `#` lines
    are provenance comments and are skipped.
    """

    source = Path(path) if path else DEFAULT_COMMON_WORDS_PATH
    words: set[str] = set()
    for line in source.read_text(encoding="utf-8").splitlines():
        token = line.strip().lower()
        if not token or token.startswith("#"):
            continue
        words.add(token)
    if not words:
        raise ValueError(f"common-word list is empty: {source}")
    return frozenset(words)
