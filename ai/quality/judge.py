"""Judges for the quality bar: the rubric and the rater.

NFR-050's rubric has three parts — fewer than seven words, common words, one
clear meaning. The first two are mechanical and checked here against the same
guardrail the shipped phrase path uses; the third is a reader's judgement and
comes from a rater. The clip bars (NFR-051, NFR-053) are entirely a rater's
judgement. A run never invents a rater: with no ratings a phrase item is judged
on the mechanical rubric alone (a pre-screen, reported as such), and a clip item
cannot be judged at all.

Ratings follow `nfr.md`: two trained raters with a third as adjudicator. A rating
is a boolean, or a mapping of rater votes that resolves to one verdict — the
shared verdict when the raters agree, otherwise the adjudicator's. An unresolved
or missing rating is a miss, never a silent pass.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass

from app.phrase.guardrails import is_usable

from .bar import ItemKey

__all__ = ["Decide", "Judgement", "clip_judge", "phrase_judge", "resolve_rating"]


@dataclass(frozen=True, slots=True)
class Judgement:
    """One item's verdict, with the reason when it missed."""

    passed: bool
    reason: str | None = None


Decide = Callable[[Mapping[str, object], object], Judgement]


def _outcome(output: object) -> Mapping[str, object]:
    return output if isinstance(output, Mapping) else {}


def _text(outcome: Mapping[str, object], field: str) -> str:
    value = outcome.get(field)
    return value if isinstance(value, str) else ""


def _flag(outcome: Mapping[str, object], field: str) -> bool:
    return outcome.get(field) is True


def resolve_rating(entry: object) -> Judgement:
    """Resolve one item's rater entry to a verdict (two raters, one adjudicator)."""

    if entry is None:
        return Judgement(False, "unrated")
    if isinstance(entry, bool):
        return Judgement(entry, None if entry else "rater rejected")
    if isinstance(entry, Mapping):
        raw_votes = entry.get("raters")
        votes = (
            [vote for vote in raw_votes if isinstance(vote, bool)]
            if isinstance(raw_votes, list)
            else []
        )
        if votes and all(vote == votes[0] for vote in votes):
            return Judgement(votes[0], None if votes[0] else "raters rejected")
        adjudicator = entry.get("adjudicator")
        if isinstance(adjudicator, bool):
            return Judgement(adjudicator, None if adjudicator else "adjudicator rejected")
        return Judgement(False, "raters disagreed without an adjudicator")
    return Judgement(False, "unreadable rating")


def phrase_judge(
    *,
    key: ItemKey,
    common_words: frozenset[str],
    max_words: int,
    max_chars: int,
    ratings: Mapping[str, object] | None = None,
) -> Decide:
    """The NFR-050 rubric: mechanical checks, then the rater's meaning check.

    With no ratings the judge applies only the mechanical rubric — the part a
    run can settle deterministically — and the report labels it a pre-screen.
    """

    def decide(item: Mapping[str, object], output: object) -> Judgement:
        outcome = _outcome(output)
        if _flag(outcome, "failed"):
            return Judgement(False, f"generation failed: {_text(outcome, 'reason')}")
        if _text(outcome, "source") != "generated":
            # A fallback is the capability's failure path (FEAT-004), not a gloss.
            return Judgement(False, "fallback phrase")
        check = is_usable(
            _text(outcome, "phrase"),
            lemma=_text(item, "lemma") or None,
            common_words=common_words,
            max_words=max_words,
            max_chars=max_chars,
        )
        if not check.ok:
            return Judgement(False, f"rubric: {check.reason}")
        if ratings is None:
            return Judgement(True)
        return resolve_rating(ratings.get(key(item)))

    return decide


def clip_judge(*, key: ItemKey, ratings: Mapping[str, object]) -> Decide:
    """The clip bars: the clip must exist, and a rater must judge it as depicting."""

    def decide(item: Mapping[str, object], output: object) -> Judgement:
        outcome = _outcome(output)
        if not _flag(outcome, "produced"):
            return Judgement(False, f"no clip: {_text(outcome, 'reason')}")
        return resolve_rating(ratings.get(key(item)))

    return decide
