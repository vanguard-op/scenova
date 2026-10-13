"""The quality bar's golden-set inputs and item identity (NFR-050 to NFR-053).

The bar itself — the metric, the threshold, and the golden-set loader — is
defined by QA in `qa/quality_bar.py`. This module reuses that definition and adds
only the two things an evaluation run needs on top of it: the input fields each
capability's golden set must carry, and a stable identity per item so a rating,
a recorded output, and a scored failure all address the same item.

The serving layer never imports this package; it is evaluation tooling, and the
cross-repo-root import below is the one seam where a run reaches QA's harness.
"""

from __future__ import annotations

import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from qa.quality_bar import (  # noqa: E402
    BARS,
    Bar,
    EvaluationResult,
    GoldenSetMissing,
    evaluate,
    load_golden_set,
)

__all__ = [
    "BARS",
    "Bar",
    "EvaluationResult",
    "GoldenSetInvalid",
    "GoldenSetMissing",
    "bar_by_id",
    "evaluate",
    "item_key",
    "load_items",
    "required_fields",
]

ItemKey = Callable[[Mapping[str, object]], str]

# The fields each capability's golden set must carry, matching the capability
# contract's input (C-004: lemma, part of speech, sense hint; C-005: a phrase).
_FIELDS: dict[str, tuple[str, ...]] = {
    "NFR-050": ("lemma", "partOfSpeech", "senseHint"),
    "NFR-051": ("word", "phrase"),
    "NFR-053": ("phrase",),
}


class GoldenSetInvalid(Exception):
    """A golden set does not carry the fields the capability's input needs."""


def required_fields(bar: Bar) -> tuple[str, ...]:
    """The input fields one bar's golden-set items must carry."""

    return _FIELDS.get(bar.nfr_id, ())


def item_key(bar: Bar) -> ItemKey:
    """A stable identity for an item, drawn from its input fields.

    Ratings, recorded outputs, and reported failures are all keyed by this, so a
    rater's judgement attaches to the exact item it judged.
    """

    fields = required_fields(bar)

    def key(item: Mapping[str, object]) -> str:
        return "|".join(str(item.get(field, "")) for field in fields)

    return key


def bar_by_id(nfr_id: str) -> Bar:
    """Resolve one bar from QA's declaration, or raise ``KeyError``."""

    for bar in BARS:
        if bar.nfr_id == nfr_id:
            return bar
    raise KeyError(f"unknown quality bar: {nfr_id}")


def validate_items(bar: Bar, items: Sequence[Mapping[str, object]]) -> None:
    """Check the golden set carries the fields and holds no duplicate items."""

    fields = required_fields(bar)
    if not fields:
        raise GoldenSetInvalid(f"{bar.nfr_id} is not measured from a golden set")

    key = item_key(bar)
    seen: set[str] = set()
    for index, item in enumerate(items):
        for field in fields:
            value = item.get(field)
            if not isinstance(value, str) or not value.strip():
                raise GoldenSetInvalid(
                    f"{bar.nfr_id} item {index} is missing a non-empty {field!r}"
                )
        identity = key(item)
        if identity in seen:
            raise GoldenSetInvalid(f"{bar.nfr_id} repeats an item: {identity}")
        seen.add(identity)


def load_items(bar: Bar) -> list[Mapping[str, object]]:
    """Load one bar's golden set through QA's loader, then check its shape."""

    items = load_golden_set(bar)
    validate_items(bar, items)
    return items
