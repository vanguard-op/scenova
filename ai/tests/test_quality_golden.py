"""The golden sets a judged bar needs are present, complete, and well-shaped.

These guard the evaluation inputs (NFR-050, NFR-051, NFR-053). They do not judge
model output: the share that passes is measured by running the set against the
pinned model at the gate.
"""

from __future__ import annotations

import pytest
from quality.bar import (
    GoldenSetInvalid,
    bar_by_id,
    item_key,
    load_items,
    validate_items,
)

from qa.quality_bar import BARS, load_golden_set

# nfr.md fixes the golden-set size per capability; the committed sets match.
_EXPECTED = {"NFR-050": 200, "NFR-051": 100, "NFR-053": 50}


@pytest.mark.parametrize("nfr_id", sorted(_EXPECTED))
def test_each_golden_set_loads_at_its_documented_size(nfr_id: str) -> None:
    bar = bar_by_id(nfr_id)

    items = load_items(bar)

    assert len(items) == _EXPECTED[nfr_id]
    assert len(items) >= bar.minimum_items


def test_the_live_feedback_bar_has_no_golden_set() -> None:
    bar = bar_by_id("NFR-052")

    assert bar.golden_file is None
    with pytest.raises(GoldenSetInvalid):
        validate_items(bar, [])


def test_the_word_clip_set_spans_concrete_and_abstract() -> None:
    words = {str(item["word"]) for item in load_items(bar_by_id("NFR-051"))}

    assert {"key", "ladder", "umbrella"} <= words  # concrete
    assert {"justice", "courage", "freedom"} <= words  # abstract


def test_the_phrase_clip_set_holds_idioms_and_phrasal_verbs() -> None:
    phrases = {str(item["phrase"]) for item in load_items(bar_by_id("NFR-053"))}

    assert all(" " in phrase for phrase in phrases)
    assert {"break the ice", "give up"} <= phrases


@pytest.mark.parametrize("nfr_id", sorted(_EXPECTED))
def test_every_item_is_addressable_by_identity(nfr_id: str) -> None:
    bar = bar_by_id(nfr_id)
    items = load_items(bar)
    key = item_key(bar)

    assert len({key(item) for item in items}) == len(items)


def test_the_loader_rejects_a_short_set() -> None:
    # QA's loader is the one the gate uses; a short set must not pass it.
    from quality.bar import Bar, GoldenSetMissing

    short = Bar(
        nfr_id="NFR-050",
        capability="x",
        golden_file="gloss_phrase.jsonl",
        minimum_items=10_000,
        metric="x",
        threshold=0.9,
        cost_ceiling="x",
    )

    with pytest.raises(GoldenSetMissing):
        load_golden_set(short)


def test_validation_rejects_a_missing_field() -> None:
    bar = bar_by_id("NFR-050")

    with pytest.raises(GoldenSetInvalid):
        validate_items(bar, [{"lemma": "key", "partOfSpeech": "noun"}])


def test_validation_rejects_a_duplicate_item() -> None:
    bar = bar_by_id("NFR-050")
    item = {"lemma": "key", "partOfSpeech": "noun", "senseHint": "a small metal object"}

    with pytest.raises(GoldenSetInvalid):
        validate_items(bar, [item, dict(item)])


def test_every_declared_bar_is_covered_by_a_golden_set_or_feedback() -> None:
    for bar in BARS:
        if bar.golden_file is not None:
            assert load_items(bar)
