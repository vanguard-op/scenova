"""Judges: the NFR-050 rubric, the rater resolution, and the clip requirement.

The model is never called here: a judge is a pure function of an item and a
produced output, so these are deterministic and offline.
"""

from __future__ import annotations

from collections.abc import Mapping

from app.config import MAX_PHRASE_CHARS, MAX_PHRASE_WORDS
from app.data import load_common_words
from quality.judge import Decide, Judgement, clip_judge, phrase_judge, resolve_rating

_KEY = "key"
_ITEM: Mapping[str, object] = {"lemma": "key", "partOfSpeech": "noun", "senseHint": "opens a lock"}


def _decide(ratings: Mapping[str, object] | None = None) -> Decide:
    return phrase_judge(
        key=lambda _item: _KEY,
        common_words=load_common_words(),
        max_words=MAX_PHRASE_WORDS,
        max_chars=MAX_PHRASE_CHARS,
        ratings=ratings,
    )


def _generated(phrase: str) -> dict[str, object]:
    return {
        "phrase": phrase,
        "source": "generated",
        "bestGuess": False,
        "failed": False,
        "reason": None,
    }


def test_a_generated_phrase_passes_the_mechanical_rubric() -> None:
    assert _decide()(_ITEM, _generated("a key in the door")).passed is True


def test_a_fallback_phrase_misses() -> None:
    outcome = {
        "phrase": "a key",
        "source": "fallback",
        "bestGuess": True,
        "failed": False,
        "reason": None,
    }

    verdict = _decide()(_ITEM, outcome)

    assert verdict.passed is False
    assert verdict.reason == "fallback phrase"


def test_a_failed_generation_misses() -> None:
    outcome = {
        "phrase": "",
        "source": "fallback",
        "bestGuess": True,
        "failed": True,
        "reason": "timeout",
    }

    verdict = _decide()(_ITEM, outcome)

    assert verdict.passed is False
    assert verdict.reason is not None and "timeout" in verdict.reason


def test_an_uncommon_word_misses() -> None:
    verdict = _decide()(_ITEM, _generated("a key in the perambulator"))

    assert verdict.passed is False
    assert verdict.reason is not None and verdict.reason.startswith("rubric:")


def test_too_many_words_misses() -> None:
    verdict = _decide()(_ITEM, _generated("a key in the door of the old red house"))

    assert verdict.passed is False


def test_two_sentences_miss() -> None:
    verdict = _decide()(_ITEM, _generated("a key turns. a door opens"))

    assert verdict.passed is False


def test_a_rater_accepts_a_mechanically_valid_phrase() -> None:
    assert _decide({_KEY: True})(_ITEM, _generated("a key in the door")).passed is True


def test_a_rater_rejection_misses() -> None:
    verdict = _decide({_KEY: False})(_ITEM, _generated("a key in the door"))

    assert verdict.passed is False
    assert verdict.reason == "rater rejected"


def test_a_missing_rating_misses() -> None:
    verdict = _decide({})(_ITEM, _generated("a key in the door"))

    assert verdict.passed is False
    assert verdict.reason == "unrated"


def test_a_mechanical_miss_is_not_overridden_by_a_rater() -> None:
    verdict = _decide({_KEY: True})(_ITEM, _generated("a key in the perambulator"))

    assert verdict.passed is False


def test_the_adjudicated_verdict_is_counted_over_the_rater() -> None:
    ratings = {_KEY: {"rater": False, "adjudicator": True}}

    assert _decide(ratings)(_ITEM, _generated("a key in the door")).passed is True


def test_an_adjudicated_rejection_misses() -> None:
    ratings = {_KEY: {"rater": True, "adjudicator": False}}

    verdict = _decide(ratings)(_ITEM, _generated("a key in the door"))

    assert verdict.passed is False
    assert verdict.reason == "adjudicator rejected"


def test_a_lone_adjudicator_verdict_is_counted() -> None:
    ratings = {_KEY: {"adjudicator": True}}

    assert _decide(ratings)(_ITEM, _generated("a key in the door")).passed is True


def test_a_rater_verdict_stands_without_adjudication() -> None:
    assert _decide({_KEY: {"rater": True}})(_ITEM, _generated("a key in the door")).passed is True


def test_resolve_rating_reads_the_shapes() -> None:
    assert resolve_rating(True) == Judgement(True, None)
    assert resolve_rating(None).reason == "unrated"
    assert resolve_rating({"rater": False, "adjudicator": True}).passed is True
    assert resolve_rating({"rater": True, "adjudicator": False}).passed is False
    assert resolve_rating({"rater": True}).passed is True
    assert resolve_rating({}).passed is False
    assert resolve_rating("nonsense").passed is False


def _clip_decide(ratings: Mapping[str, object]) -> Decide:
    return clip_judge(key=lambda _item: _KEY, ratings=ratings)


def test_a_produced_clip_with_a_rater_pass_scores() -> None:
    outcome = {"produced": True, "reason": None}

    assert _clip_decide({_KEY: True})({"phrase": "break the ice"}, outcome).passed is True


def test_a_clip_that_was_not_produced_misses() -> None:
    outcome = {"produced": False, "reason": "declined"}

    verdict = _clip_decide({_KEY: True})({"phrase": "break the ice"}, outcome)

    assert verdict.passed is False
    assert verdict.reason == "no clip: declined"


def test_a_clip_without_a_rating_misses() -> None:
    outcome = {"produced": True, "reason": None}

    verdict = _clip_decide({})({"phrase": "break the ice"}, outcome)

    assert verdict.passed is False
    assert verdict.reason == "unrated"
