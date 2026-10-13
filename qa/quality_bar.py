"""Quality-bar harness for the model-backed capabilities (nfr.md, NFR-050 to NFR-053).

The bar for each model-backed capability is judged, not asserted: a fixed golden
set is run against the capability's own pinned model and the share that passes is
compared to the threshold. Each bar carries the pin it was measured against, so
the gloss phrase (a text capability) and the clips (video capabilities) never
collapse back onto one model. This module holds the bar's definition and the
loader the evaluation runs on. It deliberately does not fabricate a golden set or
a judge — those are the evaluation inputs the bar requires, and their absence is
a doc gap reported by `test_quality_bar.py`, not something to paper over.

Golden-set files live in `qa/golden/` as one JSON object per line:

- `gloss_phrase.jsonl`   (NFR-050): `{"lemma", "partOfSpeech", "senseHint"}`
- `word_clip.jsonl`      (NFR-051): `{"word", "phrase"}`
- `phrase_clip.jsonl`    (NFR-053): `{"phrase"}`

The judge for the bars is a rater (one trained rater with adjudication, per
nfr.md: the rater's misses and a fixed sample of the rest are re-judged, and the
adjudicated verdict is the one the run counts); the harness accepts a judge
callable so a run is reproducible, and reports the metric, the sample size, and
the failing cases.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path

GOLDEN_DIR = Path(__file__).resolve().parent / "golden"

# The two pinned models the bars are measured against (nfr.md, Model Quality &
# Cost; architecture.md, "Model Version & Fallback"). The gloss phrase is a text
# capability pinned to the text model; the clips are video capabilities pinned to
# the video model. Each bar carries the one its capability was measured on.
PHRASE_MODEL_PIN = "gemini-3.5-flash-lite"
CLIP_MODEL_PIN = "gemini-omni-1.1-flash"


@dataclass(frozen=True, slots=True)
class Bar:
    """One judged capability bar from nfr.md's Model Quality & Cost section."""

    nfr_id: str
    capability: str
    golden_file: str | None
    minimum_items: int
    metric: str
    threshold: float
    cost_ceiling: str
    # The pinned model this capability is measured against. Every bar declared in
    # `BARS` sets it; a bar that carries none cannot be measured (nfr.md).
    model_pin: str = ""


BARS: tuple[Bar, ...] = (
    Bar(
        nfr_id="NFR-050",
        capability="Gloss phrase generation",
        golden_file="gloss_phrase.jsonl",
        minimum_items=200,
        metric="Share of phrases that pass the rubric (seven words or fewer, common words, "
        "one clear meaning)",
        threshold=0.90,
        cost_ceiling="$0.01 per request",
        model_pin=PHRASE_MODEL_PIN,
    ),
    Bar(
        nfr_id="NFR-051",
        capability="Word-clip generation",
        golden_file="word_clip.jsonl",
        minimum_items=100,
        metric="Share of clips a rater judges to depict the phrase's meaning",
        threshold=0.80,
        cost_ceiling="$0.15 per generated clip",
        model_pin=CLIP_MODEL_PIN,
    ),
    Bar(
        nfr_id="NFR-052",
        capability="Word-clip usefulness",
        golden_file=None,  # live reader feedback, rolling 30 days
        minimum_items=0,
        metric="Share of served clips a reader marks as helpful",
        threshold=0.70,
        cost_ceiling="Not applicable",
        model_pin=CLIP_MODEL_PIN,
    ),
    Bar(
        nfr_id="NFR-053",
        capability="Phrase-clip generation",
        golden_file="phrase_clip.jsonl",
        minimum_items=50,
        metric="Share of clips a rater judges to depict the phrase's meaning",
        threshold=0.75,
        cost_ceiling="$0.15 per generated clip",
        model_pin=CLIP_MODEL_PIN,
    ),
)


class GoldenSetMissing(Exception):
    """The golden set an evaluation requires is not present."""


def golden_path(bar: Bar) -> Path | None:
    return None if bar.golden_file is None else GOLDEN_DIR / bar.golden_file


def load_golden_set(bar: Bar) -> list[Mapping[str, object]]:
    """Load one golden set, or raise when it is absent or short."""

    path = golden_path(bar)
    if path is None:
        raise GoldenSetMissing(f"{bar.nfr_id} is evaluated from live feedback, not a golden set")
    if not path.exists():
        raise GoldenSetMissing(
            f"{bar.nfr_id}: no golden set at {path.relative_to(path.parents[1])}"
        )
    items: list[Mapping[str, object]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped:
            items.append(json.loads(stripped))
    if len(items) < bar.minimum_items:
        raise GoldenSetMissing(
            f"{bar.nfr_id}: golden set has {len(items)} items, "
            f"the bar requires {bar.minimum_items}"
        )
    return items


@dataclass(frozen=True, slots=True)
class EvaluationResult:
    """The outcome of one judged run: the metric, the sample, and the misses."""

    nfr_id: str
    metric: str
    threshold: float
    sample_size: int
    passed: int
    failures: tuple[Mapping[str, object], ...]

    @property
    def rate(self) -> float:
        return self.passed / self.sample_size if self.sample_size else 0.0

    @property
    def meets_bar(self) -> bool:
        return self.sample_size > 0 and self.rate >= self.threshold


def evaluate(
    bar: Bar,
    items: Iterable[Mapping[str, object]],
    produce: Callable[[Mapping[str, object]], object],
    judge: Callable[[Mapping[str, object], object], bool],
) -> EvaluationResult:
    """Run one golden set: produce the output, judge it, and score the share.

    `produce` calls the pinned model; `judge` applies the bar's rubric or rater.
    Both are injected so the run is reproducible and the model call is swappable
    between the live pinned model and a recorded replay.
    """

    materialised = list(items)
    passed = 0
    failures: list[Mapping[str, object]] = []
    for item in materialised:
        output = produce(item)
        if judge(item, output):
            passed += 1
        else:
            failures.append({**item, "output": output})
    return EvaluationResult(
        nfr_id=bar.nfr_id,
        metric=bar.metric,
        threshold=bar.threshold,
        sample_size=len(materialised),
        passed=passed,
        failures=tuple(failures),
    )


def bars() -> Iterator[Bar]:
    return iter(BARS)
