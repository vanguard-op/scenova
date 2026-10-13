"""Gate checks for the model quality bar (nfr.md, NFR-050 to NFR-053).

These do not judge model output themselves — a judged bar is measured by running
the golden set against the pinned model. They assert the inputs that measurement
requires are present, so a release cannot be declared green on a bar that was
never run. When an input is missing the failure names the doc gap.
"""

from __future__ import annotations

import os

import pytest

from qa.quality_bar import BARS, MODEL_PIN, Bar, GoldenSetMissing, load_golden_set

pytestmark = [pytest.mark.acceptance, pytest.mark.model]

_GOLDEN_BARS = [bar for bar in BARS if bar.golden_file is not None]


def test_the_quality_bar_is_declared() -> None:
    # nfr.md's Model Quality & Cost section fixes a metric and a threshold per
    # capability, measured against the pinned model version.
    declared = {bar.nfr_id for bar in BARS}
    assert declared == {"NFR-050", "NFR-051", "NFR-052", "NFR-053"}
    assert MODEL_PIN == "gemini-omni-1.1-flash"
    for bar in BARS:
        assert bar.metric
        assert 0.0 < bar.threshold <= 1.0


@pytest.mark.parametrize("bar", _GOLDEN_BARS, ids=[bar.nfr_id for bar in _GOLDEN_BARS])
def test_the_golden_set_a_bar_needs_is_present(bar: Bar) -> None:
    # Doc gap: the bar names a golden set (nfr.md) but the docs do not enumerate
    # its items and none is committed, so the evaluation cannot run.
    try:
        items = load_golden_set(bar)
    except GoldenSetMissing as exc:
        pytest.fail(
            f"{bar.nfr_id} cannot be evaluated: {exc}. "
            "The golden set is an evaluation input the bar requires "
            "(nfr.md, Model Quality & Cost) and must be provided before the gate."
        )
    assert len(items) >= bar.minimum_items


def test_the_pinned_model_is_reachable_for_a_judged_run() -> None:
    # A judged run needs the pinned model provider configured; without it no
    # output can be produced and the bar cannot be measured.
    if not os.environ.get("GEMINI_API_KEY"):
        pytest.fail(
            "GEMINI_API_KEY is not configured, so the NFR-050/051/053 golden-set "
            f"evaluation against {MODEL_PIN} cannot run. Configure the pinned "
            "model credential (or a recorded replay) before the gate."
        )
