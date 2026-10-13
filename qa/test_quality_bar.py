"""Gate checks for the model quality bar (nfr.md, NFR-050 to NFR-053).

These do not judge model output themselves — a judged bar is measured by running
the golden set against the capability's pinned model. They assert the inputs that
measurement requires are present, so a release cannot be declared green on a bar
that was never run. When an input is missing the failure names the doc gap.

Each bar carries its own pinned model (nfr.md, Model Quality & Cost): the gloss
phrase is a text capability measured on the text model, and the clips are video
capabilities measured on the video model, so the two never collapse onto one.
Each bar also names the feature it belongs to and the roadmap places that feature
in a phase, so the phase gate is scoped to the capabilities that phase delivers.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from app.config import CLIP_MODEL_PIN as SERVED_CLIP_PIN
from app.config import PHRASE_MODEL_PIN as SERVED_PHRASE_PIN

from qa.quality_bar import (
    BARS,
    CLIP_MODEL_PIN,
    CURRENT_PHASE,
    PHASE_FEATURES,
    PHRASE_MODEL_PIN,
    Bar,
    GoldenSetMissing,
    bars_for_phase,
    golden_bars_for_phase,
    load_golden_set,
)

pytestmark = [pytest.mark.acceptance, pytest.mark.model]

_GOLDEN_BARS = [bar for bar in BARS if bar.golden_file is not None]
_PHASE_GOLDEN_BARS = golden_bars_for_phase(CURRENT_PHASE)
_HERE = Path(__file__).resolve().parent
_REPLAY_DIR = _HERE / "replay"

# The pin nfr.md fixes per capability: the gloss phrase (text) on the text model,
# every clip capability (video) on the video model.
_DOCUMENTED_PINS = {
    "NFR-050": PHRASE_MODEL_PIN,
    "NFR-051": CLIP_MODEL_PIN,
    "NFR-052": CLIP_MODEL_PIN,
    "NFR-053": CLIP_MODEL_PIN,
}

# The capabilities each roadmap phase delivers (roadmap.md feature tables; nfr.md
# "Model Quality & Cost" feature column). The first phase's bar for the phrase
# clip (FEAT-007) belongs to the Reading Loop, and the gloss phrase (FEAT-004) and
# word clip (FEAT-005) belong to Foundations.
_DOCUMENTED_PHASE_BARS = {
    "Phase 1: Foundations": {"NFR-050", "NFR-051", "NFR-052"},
    "Phase 2: The Reading Loop": {"NFR-053"},
}


def test_the_quality_bar_is_declared() -> None:
    # nfr.md's Model Quality & Cost section fixes a metric and a threshold per
    # capability, measured against the capability's pinned model version.
    declared = {bar.nfr_id for bar in BARS}
    assert declared == {"NFR-050", "NFR-051", "NFR-052", "NFR-053"}
    for bar in BARS:
        assert bar.metric
        assert 0.0 < bar.threshold <= 1.0


@pytest.mark.parametrize("bar", BARS, ids=[bar.nfr_id for bar in BARS])
def test_each_bar_carries_its_own_pinned_model(bar: Bar) -> None:
    # The gloss phrase and the clips are separate model-backed capabilities, each
    # against its own pinned model (nfr.md; architecture.md "Model Version &
    # Fallback"). A bar that carries no pin, or the wrong one, cannot be measured.
    assert bar.model_pin, f"{bar.nfr_id} carries no pinned model"
    assert bar.model_pin == _DOCUMENTED_PINS[bar.nfr_id]


def test_the_two_pins_are_distinct_and_both_used() -> None:
    assert PHRASE_MODEL_PIN == "gemini-3.5-flash-lite"
    assert CLIP_MODEL_PIN == "gemini-omni-1.1-flash"
    assert PHRASE_MODEL_PIN != CLIP_MODEL_PIN
    assert {bar.model_pin for bar in BARS} == {PHRASE_MODEL_PIN, CLIP_MODEL_PIN}


def test_each_bar_is_measured_against_the_model_the_step_serves() -> None:
    # The pin a bar carries is the pin the generation step actually serves; if the
    # two drift, the run measures a model the product does not use.
    assert PHRASE_MODEL_PIN == SERVED_PHRASE_PIN
    assert CLIP_MODEL_PIN == SERVED_CLIP_PIN


def test_each_bar_names_the_feature_it_belongs_to() -> None:
    # Every bar carries the durable feature from nfr.md's "Feature" column; without
    # it the bar cannot be placed in a roadmap phase, so a phase gate could not
    # scope itself to what the phase delivers (roadmap.md).
    for bar in BARS:
        assert bar.feature_id.startswith("FEAT-"), f"{bar.nfr_id} names no feature"


def test_every_feature_is_placed_in_exactly_one_roadmap_phase() -> None:
    # roadmap.md assigns each feature to one phase; a bar whose feature is placed
    # in no phase, or in two, cannot be scoped to a gate.
    placed: dict[str, str] = {}
    for phase, features in PHASE_FEATURES.items():
        for feature in features:
            assert feature not in placed, f"{feature} is in two phases"
            placed[feature] = phase
    for bar in BARS:
        assert bar.feature_id in placed, f"{bar.nfr_id} names an unplaced feature {bar.feature_id}"


def test_the_gate_is_scoped_to_the_current_phase_capabilities() -> None:
    # The phase gate measures only the capabilities the phase delivers, so a
    # later phase's bar never blocks this one and this phase's bars are not lost.
    assert current_phase_bars() == _DOCUMENTED_PHASE_BARS[CURRENT_PHASE]


def test_the_reading_loop_phrase_clip_is_not_in_the_foundations_gate() -> None:
    # The phrase clip (FEAT-007, NFR-053) is delivered by the Reading Loop, so it
    # must not be asserted at the Foundations gate (roadmap.md).
    assert "NFR-053" not in {bar.nfr_id for bar in bars_for_phase("Phase 1: Foundations")}
    assert "NFR-053" in {bar.nfr_id for bar in bars_for_phase("Phase 2: The Reading Loop")}


def current_phase_bars() -> set[str]:
    return {bar.nfr_id for bar in bars_for_phase(CURRENT_PHASE)}


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


@pytest.mark.parametrize("bar", _PHASE_GOLDEN_BARS, ids=[bar.nfr_id for bar in _PHASE_GOLDEN_BARS])
def test_each_phase_bar_is_runnable_for_a_judged_run(bar: Bar) -> None:
    # A judged run needs a producer for the phased bar: a recorded run to replay,
    # or the pinned-model credential for a live run. Without either the bar cannot
    # be measured (nfr.md, Model Quality & Cost).
    replay = _REPLAY_DIR / f"{bar.nfr_id}.jsonl"
    if not replay.exists() and not os.environ.get("GEMINI_API_KEY"):
        pytest.fail(
            f"{bar.nfr_id}: the golden set cannot be produced against {bar.model_pin} — "
            f"there is no recorded run at {replay} and GEMINI_API_KEY is not set. A "
            "credential or a recorded replay is a judged-run input (nfr.md, Model "
            "Quality & Cost)."
        )
