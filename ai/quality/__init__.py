"""The quality-bar evaluation run for the model-backed capabilities.

This package runs the judged bar in `nfr.md`'s Model Quality & Cost section
(NFR-050, NFR-051, NFR-053) against the pinned model, over the fixed golden sets
in `qa/golden/`. It reuses QA's bar definition and scorer (`qa/quality_bar.py`)
rather than re-deriving the metric or the threshold, so the number a run reports
is the number the gate checks.

What this package owns: the golden-set shape checks, the producers that call the
generation path (C-004, C-005), the rubric and rater judges, and the run report.
What it does not own: the bar, the threshold, and the gate decision. A run
reports a metric and whether it meets the bar; QA decides the release.
"""

from __future__ import annotations

from .bar import (
    BARS,
    MODEL_PIN,
    Bar,
    GoldenSetInvalid,
    GoldenSetMissing,
    bar_by_id,
    item_key,
    load_items,
    required_fields,
)
from .judge import Judgement, clip_judge, phrase_judge, resolve_rating
from .produce import (
    ClipOutcome,
    ClipProducer,
    PhraseOutcome,
    PhraseProducer,
    ReplayMiss,
    ReplayProducer,
    live_clip_producer,
    live_phrase_producer,
)
from .run import (
    BarReport,
    load_ratings,
    load_replay,
    produce_all,
    run_bar,
    write_report,
)

__all__ = [
    "BARS",
    "MODEL_PIN",
    "Bar",
    "BarReport",
    "ClipOutcome",
    "ClipProducer",
    "GoldenSetInvalid",
    "GoldenSetMissing",
    "Judgement",
    "PhraseOutcome",
    "PhraseProducer",
    "ReplayMiss",
    "ReplayProducer",
    "bar_by_id",
    "clip_judge",
    "item_key",
    "live_clip_producer",
    "live_phrase_producer",
    "load_items",
    "load_ratings",
    "load_replay",
    "phrase_judge",
    "produce_all",
    "required_fields",
    "resolve_rating",
    "run_bar",
    "write_report",
]
