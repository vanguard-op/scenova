"""Command line for the quality-bar evaluation run (NFR-050 to NFR-053).

Run one bar against the pinned model over its golden set, from the repo root:

    PYTHONPATH=ai python -m quality --bar NFR-050 --ratings ratings.json --out report.json

Options:
  --bar       the bar to run (NFR-050, NFR-051, NFR-053)
  --replay    score a previously recorded run instead of calling the provider
  --record    write this run's outputs so it can be replayed offline
  --sheet     write a review sheet of items and outputs for the rater
  --ratings   the rater's judgement (with any adjudication), keyed by item identity
  --out       write the report here (JSON); printed to stdout otherwise

A phrase bar (NFR-050) runs its mechanical rubric with or without ratings; the
report says which. A clip bar (NFR-051, NFR-053) has no mechanical judge, so
without ratings it produces a sheet for the rater and stops.

Exit codes: 0 a run completed; 2 the run could not be completed (missing input,
unknown bar, or a clip bar with no ratings).
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from app.config import get_settings
from app.data import load_common_words

from .bar import Bar, GoldenSetMissing, bar_by_id, item_key
from .judge import Decide, clip_judge, phrase_judge
from .produce import Producer, ReplayProducer, live_clip_producer, live_phrase_producer
from .run import load_ratings, load_replay, produce_all, run_bar, write_report

_RUBRIC_ONLY = "rubric only (pre-screen; a rater is required for the bar)"
_RUBRIC_AND_RATER = "rubric and rater"
_RATER = "rater"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="quality", description="Run one quality bar.")
    parser.add_argument("--bar", required=True, help="NFR-050, NFR-051, or NFR-053")
    parser.add_argument("--replay", help="score a recorded run instead of calling the provider")
    parser.add_argument("--record", help="write this run's outputs for later replay")
    parser.add_argument("--sheet", help="write a review sheet for the rater")
    parser.add_argument("--ratings", help="the rater's judgement, keyed by item identity")
    parser.add_argument("--out", help="write the report here as JSON")
    return parser


def _resolve_bar(nfr_id: str) -> Bar | None:
    try:
        return bar_by_id(nfr_id)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return None


def _phrase_decide(bar: Bar, ratings: dict[str, object] | None) -> tuple[Decide, str]:
    settings = get_settings()
    decide = phrase_judge(
        key=item_key(bar),
        common_words=load_common_words(),
        max_words=settings.max_phrase_words,
        max_chars=settings.max_phrase_chars,
        ratings=ratings,
    )
    return decide, (_RUBRIC_AND_RATER if ratings else _RUBRIC_ONLY)


def _clip_decide(bar: Bar, ratings: dict[str, object] | None) -> Decide | None:
    if ratings is None:
        return None
    return clip_judge(key=item_key(bar), ratings=ratings)


def _resolve_producer(bar: Bar, replay: str | None) -> Producer:
    if replay:
        return ReplayProducer(item_key(bar), load_replay(Path(replay)))
    settings = get_settings()
    if bar.nfr_id == "NFR-050":
        return live_phrase_producer(settings)
    return live_clip_producer(settings)


def _capability_pin(bar: Bar) -> str:
    """The pinned model the bar was measured against (architecture "Model Version & Fallback").

    The gloss phrase is a text capability on its own pin; the clip bars are video
    capabilities on theirs. The report names the pin the run was measured against,
    whether it produced live or replayed a recorded run.
    """

    settings = get_settings()
    return settings.phrase_model_pin if bar.nfr_id == "NFR-050" else settings.clip_model_pin


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    bar = _resolve_bar(args.bar)
    if bar is None:
        return 2
    if bar.golden_file is None:
        print(
            f"{bar.nfr_id} is measured from live reader feedback, not a golden set",
            file=sys.stderr,
        )
        return 2

    ratings = load_ratings(Path(args.ratings)) if args.ratings else None
    record = Path(args.record) if args.record else None
    sheet = Path(args.sheet) if args.sheet else None
    producer = _resolve_producer(bar, args.replay)
    model_pin = _capability_pin(bar)

    if bar.nfr_id == "NFR-050":
        decide, judged_by = _phrase_decide(bar, ratings)
    else:
        clip_decide = _clip_decide(bar, ratings)
        if clip_decide is None:
            # No mechanical judge exists for a clip bar: produce the sheet for
            # the rater, and report that the bar was not measured.
            try:
                produce_all(bar, producer, record=record, sheet=sheet)
            except GoldenSetMissing as exc:
                print(str(exc), file=sys.stderr)
                return 2
            where = f" to {sheet}" if sheet else ""
            print(
                f"{bar.nfr_id} needs rater judgements; wrote a review sheet{where}. "
                "Re-run with --ratings.",
                file=sys.stderr,
            )
            return 2
        decide, judged_by = clip_decide, _RATER

    try:
        report = run_bar(
            bar,
            decide=decide,
            producer=producer,
            judged_by=judged_by,
            model_pin=model_pin,
            record=record,
            sheet=sheet,
        )
    except GoldenSetMissing as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.out:
        write_report(report, Path(args.out))
    else:
        print(json.dumps(report.as_dict(), indent=2))
    verdict = "meets" if report.meets_bar else "below"
    print(
        f"{bar.nfr_id}: {report.passed}/{report.sample_size} = {report.rate:.3f} "
        f"against {report.threshold:.2f} ({verdict} the bar; judged by {report.judged_by})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
