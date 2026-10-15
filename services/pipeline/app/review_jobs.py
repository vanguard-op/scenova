"""The review service's generation jobs, recognised from the job's lookup id.

A generation the content review service starts is not a reader's lookup, so it
has no lookup of its own. The job's `lookupId` therefore carries the review
route as a small internal convention, the way the lookup service's own job ids
encode their key:

- `cand:<entryId>` or `cand:<entryId>:<readerLookupId>` — a report-triggered
  generation. The clip produced is written to the shared library as the entry's
  candidate, not as a new entry; when the reporting reader's lookup is carried,
  the clip-ready notice reaches that reader (FEAT-011).
- `edit:<entryId>` — a curator's phrase edit. The clip produced is a normal
  replacement entry, generated from the curator's phrase (FEAT-015).

Any other lookup id is an ordinary reader lookup and takes the ordinary path.
The format is internal to the pipeline and the review service; it is not a
numbered contract.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

CANDIDATE_PREFIX = "cand:"
REPLACEMENT_PREFIX = "edit:"


class ReviewRouteKind(StrEnum):
    """What a review generation produces."""

    CANDIDATE = "candidate"
    REPLACEMENT = "replacement"


@dataclass(frozen=True)
class ReviewRoute:
    """The review route a generation job's lookup id names."""

    kind: ReviewRouteKind
    entry_id: str
    # The reporting reader's lookup, when the job carries one, so the finished
    # candidate reaches them; None for a curator's phrase edit.
    reader_lookup_id: str | None


def review_route(lookup_id: str) -> ReviewRoute | None:
    """The review route a job's lookup id names, or None for a reader lookup."""

    if lookup_id.startswith(CANDIDATE_PREFIX):
        rest = lookup_id[len(CANDIDATE_PREFIX) :]
        entry_id, _, reader = rest.partition(":")
        if not entry_id:
            return None
        return ReviewRoute(
            kind=ReviewRouteKind.CANDIDATE,
            entry_id=entry_id,
            reader_lookup_id=reader or None,
        )
    if lookup_id.startswith(REPLACEMENT_PREFIX):
        entry_id = lookup_id[len(REPLACEMENT_PREFIX) :]
        if not entry_id:
            return None
        return ReviewRoute(
            kind=ReviewRouteKind.REPLACEMENT,
            entry_id=entry_id,
            reader_lookup_id=None,
        )
    return None


def candidate_lookup_id(entry_id: str, reader_lookup_id: str | None = None) -> str:
    """The lookup id a report-triggered candidate job carries (FEAT-011)."""

    if reader_lookup_id is None:
        return f"{CANDIDATE_PREFIX}{entry_id}"
    return f"{CANDIDATE_PREFIX}{entry_id}:{reader_lookup_id}"


def replacement_lookup_id(entry_id: str) -> str:
    """The lookup id a curator's phrase-edit job carries (FEAT-015)."""

    return f"{REPLACEMENT_PREFIX}{entry_id}"
