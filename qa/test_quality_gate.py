"""The judged model quality-bar gate (nfr.md, NFR-050 to NFR-053).

`test_quality_bar.py` guards the bar's inputs; this module is the run itself. At
the phase gate each model-backed capability's fixed golden set is produced against
the pinned model through the shipped generation path (C-004, C-005) and judged by
the bar's rubric and raters, and the measured share is asserted against the
threshold. It drives the shipped `python -m quality` run (`ai/quality`), so the
number asserted here is the number the release decision reads.

A run that cannot produce, or cannot be judged, fails here and names the missing
input: a bar that was never measured must not read as green. NFR-052 is measured
from live reader feedback over a rolling thirty days and has no golden set, so it
is not asserted from a run (nfr.md, Model Quality & Cost).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from quality.__main__ import main as quality_main

from qa.quality_bar import BARS, Bar

pytestmark = [pytest.mark.acceptance, pytest.mark.model]

_GOLDEN_BARS = [bar for bar in BARS if bar.golden_file is not None]
_HERE = Path(__file__).resolve().parent

# The two inputs a judged run needs beyond the golden set (nfr.md, Model Quality
# & Cost): the pinned-model credential or a recorded run, and the raters'
# judgements. Both are fixed, and neither lives in `qa/golden/`.
_REPLAY_DIR = _HERE / "replay"
_RATINGS_DIR = _HERE / "ratings"


def _replay_path(nfr_id: str) -> Path:
    return _REPLAY_DIR / f"{nfr_id}.jsonl"


def _ratings_path(nfr_id: str) -> Path:
    return _RATINGS_DIR / f"{nfr_id}.json"


@pytest.mark.parametrize("bar", _GOLDEN_BARS, ids=[bar.nfr_id for bar in _GOLDEN_BARS])
def test_the_golden_set_evaluation_meets_the_bar(bar: Bar, tmp_path: Path) -> None:
    replay = _replay_path(bar.nfr_id)
    ratings = _ratings_path(bar.nfr_id)

    if not replay.exists() and not os.environ.get("GEMINI_API_KEY"):
        pytest.fail(
            f"{bar.nfr_id}: the golden set cannot be produced against {bar.model_pin} — "
            f"there is no recorded run at {replay} and GEMINI_API_KEY is not set. A "
            "credential or a recorded replay is a judged-run input (nfr.md, Model "
            "Quality & Cost)."
        )
    if not ratings.exists():
        pytest.fail(
            f"{bar.nfr_id}: the golden set cannot be judged — there are no rater "
            f"judgements at {ratings}. Two trained raters with a third as adjudicator "
            "are a judged-run input (nfr.md, Model Quality & Cost)."
        )

    report_path = tmp_path / f"{bar.nfr_id}.json"
    argv = ["--bar", bar.nfr_id]
    if replay.exists():
        argv += ["--replay", str(replay)]
    argv += ["--ratings", str(ratings), "--out", str(report_path)]

    code = quality_main(argv)

    assert code == 0, f"{bar.nfr_id}: the evaluation run did not complete (exit {code})"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert report["sampleSize"] >= bar.minimum_items
    assert report["modelPin"] == bar.model_pin, (
        f"{bar.nfr_id} was measured against {report['modelPin']}, but the bar pins "
        f"{bar.model_pin}: the run did not measure the capability's pinned model "
        "(nfr.md, Model Quality & Cost)."
    )
    assert report["meetsBar"] is True, (
        f"{bar.nfr_id} measured {report['rate']:.3f} "
        f"({report['passed']}/{report['sampleSize']}) against the "
        f"{report['threshold']:.2f} bar: {len(report['failures'])} item(s) failed. The "
        "capability blocks release of the generation path until the pinned model or "
        "the phrase prompt moves it back above the bar (nfr.md, Model Quality & Cost)."
    )
