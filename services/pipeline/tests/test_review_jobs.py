"""Tests for the review route a generation job's lookup id names."""

from __future__ import annotations

from pipeline.app.review_jobs import (
    ReviewRouteKind,
    candidate_lookup_id,
    replacement_lookup_id,
    review_route,
)


def test_a_reader_lookup_has_no_review_route() -> None:
    assert review_route("lk_abc") is None


def test_a_candidate_lookup_names_the_entry() -> None:
    route = review_route(candidate_lookup_id("le_1"))

    assert route is not None
    assert route.kind is ReviewRouteKind.CANDIDATE
    assert route.entry_id == "le_1"
    assert route.reader_lookup_id is None


def test_a_candidate_lookup_carries_the_reporting_reader() -> None:
    route = review_route(candidate_lookup_id("le_1", "lk_abc"))

    assert route is not None
    assert route.kind is ReviewRouteKind.CANDIDATE
    assert route.entry_id == "le_1"
    assert route.reader_lookup_id == "lk_abc"


def test_a_replacement_lookup_names_the_entry() -> None:
    route = review_route(replacement_lookup_id("le_1"))

    assert route is not None
    assert route.kind is ReviewRouteKind.REPLACEMENT
    assert route.entry_id == "le_1"
    assert route.reader_lookup_id is None


def test_an_empty_review_route_is_not_a_route() -> None:
    assert review_route("cand:") is None
    assert review_route("edit:") is None
