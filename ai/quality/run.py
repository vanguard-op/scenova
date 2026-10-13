"""The evaluation run: produce the golden set, judge it, and report the metric.

The run reuses QA's scorer (`qa.quality_bar.evaluate`) so the share it reports is
the share the gate checks; it adds the production pass, the reason per miss, and
a report the release decision can read. It never asserts a release: the report
carries the measured rate, the bar, and whether it was met, and the gate decides.

Outputs and ratings are addressed by item identity (`bar.item_key`), so a
recorded run replays exactly and a rater's verdict attaches to the item it judged.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import TypeVar

from .bar import (
    Bar,
    EvaluationResult,
    ItemKey,
    evaluate,
    item_key,
    load_items,
    required_fields,
)
from .judge import Decide, Judgement
from .produce import Producer

__all__ = [
    "BarReport",
    "load_ratings",
    "load_replay",
    "produce_all",
    "run_bar",
    "write_replay",
    "write_report",
    "write_review_sheet",
]

_T = TypeVar("_T")


class _EventLoop:
    """One loop for the whole production pass, so a client binds to it once."""

    def __init__(self) -> None:
        self._loop: asyncio.AbstractEventLoop | None = None

    def __enter__(self) -> _EventLoop:
        self._loop = asyncio.new_event_loop()
        return self

    def __exit__(self, *exc: object) -> None:
        if self._loop is not None:
            self._loop.close()
            self._loop = None

    def run(self, coro: Awaitable[_T]) -> _T:
        if self._loop is None:
            raise RuntimeError("event loop is not running")
        return self._loop.run_until_complete(coro)


@dataclass(frozen=True, slots=True)
class BarReport:
    """One judged run: the bar, the sample, the share, and the misses."""

    nfr_id: str
    capability: str
    metric: str
    threshold: float
    cost_ceiling: str
    model_pin: str
    sample_size: int
    passed: int
    rate: float
    meets_bar: bool
    judged_by: str
    failures: tuple[Mapping[str, object], ...]
    generated_at: str

    def as_dict(self) -> dict[str, object]:
        return {
            "nfrId": self.nfr_id,
            "capability": self.capability,
            "metric": self.metric,
            "threshold": self.threshold,
            "costCeiling": self.cost_ceiling,
            "modelPin": self.model_pin,
            "sampleSize": self.sample_size,
            "passed": self.passed,
            "rate": self.rate,
            "meetsBar": self.meets_bar,
            "judgedBy": self.judged_by,
            "failures": list(self.failures),
            "generatedAt": self.generated_at,
        }


def produce_all(
    bar: Bar,
    producer: Producer,
    *,
    items: Sequence[Mapping[str, object]] | None = None,
    record: Path | None = None,
    sheet: Path | None = None,
) -> tuple[list[Mapping[str, object]], list[dict[str, object]]]:
    """Produce one output per item, optionally recording it and a review sheet."""

    resolved = list(items) if items is not None else load_items(bar)
    key = item_key(bar)
    with _EventLoop() as loop:
        outputs = [dict(loop.run(producer(item))) for item in resolved]
    if record is not None:
        write_replay(record, resolved, outputs, key)
    if sheet is not None:
        write_review_sheet(sheet, resolved, outputs, key)
    return resolved, outputs


def run_bar(
    bar: Bar,
    *,
    decide: Decide,
    producer: Producer,
    judged_by: str,
    model_pin: str,
    items: Sequence[Mapping[str, object]] | None = None,
    record: Path | None = None,
    sheet: Path | None = None,
) -> BarReport:
    """Run one bar: produce the golden set, judge it, and score the share."""

    resolved, outputs = produce_all(bar, producer, items=items, record=record, sheet=sheet)
    key = item_key(bar)
    by_key = {key(item): output for item, output in zip(resolved, outputs, strict=True)}
    reasons: dict[str, Judgement] = {}

    def produce(item: Mapping[str, object]) -> object:
        return by_key[key(item)]

    def judge(item: Mapping[str, object], output: object) -> bool:
        verdict = decide(item, output)
        reasons[key(item)] = verdict
        return verdict.passed

    result = evaluate(bar, resolved, produce, judge)
    return _report(bar, result, reasons, judged_by=judged_by, model_pin=model_pin)


def _report(
    bar: Bar,
    result: EvaluationResult,
    reasons: Mapping[str, Judgement],
    *,
    judged_by: str,
    model_pin: str,
) -> BarReport:
    fields = required_fields(bar)
    key = item_key(bar)
    failures: list[Mapping[str, object]] = []
    for row in result.failures:
        identity = key(row)
        verdict = reasons.get(identity, Judgement(False, "unjudged"))
        item = {field: row[field] for field in fields if field in row}
        failures.append(
            {
                "key": identity,
                "item": item,
                "reason": verdict.reason,
                "output": row.get("output"),
            }
        )
    return BarReport(
        nfr_id=bar.nfr_id,
        capability=bar.capability,
        metric=bar.metric,
        threshold=bar.threshold,
        cost_ceiling=bar.cost_ceiling,
        model_pin=model_pin,
        sample_size=result.sample_size,
        passed=result.passed,
        rate=result.rate,
        meets_bar=result.meets_bar,
        judged_by=judged_by,
        failures=tuple(failures),
        generated_at=datetime.now(UTC).isoformat(),
    )


def write_report(report: BarReport, path: Path) -> None:
    """Write a run report as JSON."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report.as_dict(), indent=2) + "\n", encoding="utf-8")


def write_replay(
    path: Path,
    items: Sequence[Mapping[str, object]],
    outputs: Sequence[dict[str, object]],
    key: ItemKey,
) -> None:
    """Write the produced outputs so a later run can replay them offline."""

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for item, output in zip(items, outputs, strict=True):
            handle.write(json.dumps({"key": key(item), "output": output}) + "\n")


def write_review_sheet(
    path: Path,
    items: Sequence[Mapping[str, object]],
    outputs: Sequence[dict[str, object]],
    key: ItemKey,
) -> None:
    """Write the items and their outputs for the rater to judge."""

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for item, output in zip(items, outputs, strict=True):
            handle.write(json.dumps({"key": key(item), **item, "output": output}) + "\n")


def load_replay(path: Path) -> dict[str, dict[str, object]]:
    """Load a recorded run's outputs, keyed by item identity."""

    outcomes: dict[str, dict[str, object]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        row = json.loads(stripped)
        outcomes[str(row["key"])] = dict(row["output"])
    return outcomes


def load_ratings(path: Path) -> dict[str, object]:
    """Load a ratings file: item identity to a rater verdict, or adjudicated verdict."""

    loaded = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError(f"ratings file must be a JSON object: {path}")
    return {str(key): value for key, value in loaded.items()}
