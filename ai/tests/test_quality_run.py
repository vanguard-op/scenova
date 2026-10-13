"""The evaluation run: scoring, reporting, recording, and replay.

The run is driven with a fake producer and the deterministic rubric, so the
suite is offline. The run reports the metric and the bar; it never asserts a
release.
"""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from pathlib import Path

import pytest
from app.config import MAX_PHRASE_CHARS, MAX_PHRASE_WORDS
from app.data import load_common_words
from quality.bar import MODEL_PIN, bar_by_id, item_key
from quality.judge import Decide, phrase_judge
from quality.produce import Producer, ReplayProducer
from quality.run import (
    BarReport,
    load_ratings,
    load_replay,
    produce_all,
    run_bar,
    write_review_sheet,
)

_ITEMS: list[Mapping[str, object]] = [
    {"lemma": "key", "partOfSpeech": "noun", "senseHint": "opens a lock"},
    {"lemma": "justice", "partOfSpeech": "noun", "senseHint": "fair treatment"},
]


class FakeProducer:
    """A scripted producer: one outcome per lemma."""

    def __init__(self, outcomes: Mapping[str, dict[str, object]]) -> None:
        self._outcomes = outcomes
        self.calls: list[Mapping[str, object]] = []

    async def __call__(self, item: Mapping[str, object]) -> dict[str, object]:
        self.calls.append(item)
        return dict(self._outcomes[str(item["lemma"])])


def _generated(phrase: str) -> dict[str, object]:
    return {
        "phrase": phrase,
        "source": "generated",
        "bestGuess": False,
        "failed": False,
        "reason": None,
    }


def _fallback() -> dict[str, object]:
    return {
        "phrase": "a key",
        "source": "fallback",
        "bestGuess": True,
        "failed": False,
        "reason": None,
    }


def _decide(ratings: Mapping[str, object] | None = None) -> Decide:
    return phrase_judge(
        key=item_key(bar_by_id("NFR-050")),
        common_words=load_common_words(),
        max_words=MAX_PHRASE_WORDS,
        max_chars=MAX_PHRASE_CHARS,
        ratings=ratings,
    )


def _producer() -> FakeProducer:
    return FakeProducer({"key": _generated("a key in the door"), "justice": _fallback()})


def _run(
    *,
    decide: Decide | None = None,
    producer: Producer | None = None,
    record: Path | None = None,
) -> BarReport:
    return run_bar(
        bar_by_id("NFR-050"),
        decide=decide or _decide(),
        producer=producer or _producer(),
        judged_by="rubric only (pre-screen; raters required for the bar)",
        items=_ITEMS,
        record=record,
    )


def test_a_run_reports_the_measured_share_against_the_bar() -> None:
    report = _run()

    assert report.nfr_id == "NFR-050"
    assert report.threshold == 0.90
    assert report.model_pin == MODEL_PIN
    assert report.sample_size == 2
    assert report.passed == 1
    assert report.rate == 0.5
    assert report.meets_bar is False


def test_a_miss_carries_its_item_and_reason() -> None:
    report = _run()

    assert len(report.failures) == 1
    failure = report.failures[0]
    assert failure["key"] == "justice|noun|fair treatment"
    assert failure["reason"] == "fallback phrase"


def test_the_report_is_json_serialisable() -> None:
    payload = _run().as_dict()

    assert json.loads(json.dumps(payload))["nfrId"] == "NFR-050"


def test_a_run_does_not_assert_the_bar() -> None:
    # Below the bar is still a completed run: the gate owns the release decision.
    report = _run(
        decide=_decide({"key|noun|opens a lock": True, "justice|noun|fair treatment": True})
    )

    assert report.sample_size == 2
    assert report.meets_bar is False
    assert report.rate == 0.5


def test_a_rater_rejection_turns_a_mechanical_pass_into_a_miss() -> None:
    report = _run(
        decide=_decide({"key|noun|opens a lock": False, "justice|noun|fair treatment": False})
    )

    assert report.passed == 0
    assert report.rate == 0.0


def test_record_and_replay_reproduce_the_run(tmp_path: Path) -> None:
    record = tmp_path / "run.jsonl"
    first = _run(record=record)
    assert record.exists()

    outcomes = load_replay(record)
    replayed = _run(producer=ReplayProducer(item_key(bar_by_id("NFR-050")), outcomes))

    assert replayed.sample_size == first.sample_size
    assert replayed.passed == first.passed
    assert replayed.rate == first.rate


def test_produce_all_writes_a_review_sheet(tmp_path: Path) -> None:
    sheet = tmp_path / "sheet.jsonl"
    items, outputs = produce_all(bar_by_id("NFR-050"), _producer(), items=_ITEMS, sheet=sheet)

    assert len(items) == len(outputs) == 2
    rows = [json.loads(line) for line in sheet.read_text(encoding="utf-8").splitlines()]
    assert rows[0]["key"] == "key|noun|opens a lock"
    assert rows[0]["output"]["phrase"] == "a key in the door"


def test_the_review_sheet_can_be_written_directly(tmp_path: Path) -> None:
    path = tmp_path / "sheet.jsonl"
    items: Sequence[Mapping[str, object]] = _ITEMS
    outputs = [_generated("a key in the door"), _fallback()]

    write_review_sheet(path, items, outputs, item_key(bar_by_id("NFR-050")))

    assert len(path.read_text(encoding="utf-8").splitlines()) == 2


def test_load_ratings_reads_a_json_object(tmp_path: Path) -> None:
    path = tmp_path / "ratings.json"
    path.write_text(json.dumps({"key|noun|opens a lock": True}), encoding="utf-8")

    assert load_ratings(path) == {"key|noun|opens a lock": True}


def test_load_ratings_rejects_a_non_object(tmp_path: Path) -> None:
    path = tmp_path / "ratings.json"
    path.write_text(json.dumps([True]), encoding="utf-8")

    with pytest.raises(ValueError):
        load_ratings(path)
