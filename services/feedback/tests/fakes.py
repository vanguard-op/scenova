"""Shared test doubles and builders for the feedback tests."""

from __future__ import annotations

from dataclasses import dataclass, field

from fastapi.testclient import TestClient

from feedback.app.api import create_app
from feedback.app.config import Settings
from feedback.app.library import LibraryUnavailableError
from feedback.app.lookups import LookupRecord, LookupUnavailableError
from feedback.app.models import LookupKind, LookupStatus
from feedback.app.ratelimit import InMemoryFixedWindowRateLimiter
from feedback.app.service import FeedbackService
from feedback.app.store import InMemoryFeedbackStore

AUTH = {"Authorization": "Bearer dev:reader-1"}
SUBJECT = "reader-1"


class FakeLookupDirectory:
    """A directory with scripted lookups for a subject.

    `records` maps `(lookup_id, subject)` to a lookup; a missing key is an
    unknown lookup. `unavailable` makes every read raise, as an outage would.
    """

    def __init__(
        self,
        records: dict[tuple[str, str], LookupRecord] | None = None,
        *,
        unavailable: bool = False,
    ) -> None:
        self.records = dict(records or {})
        self.unavailable = unavailable
        self.calls: list[tuple[str, str]] = []

    async def read(self, lookup_id: str, subject: str) -> LookupRecord | None:
        self.calls.append((lookup_id, subject))
        if self.unavailable:
            raise LookupUnavailableError("The lookup service is unreachable.")
        return self.records.get((lookup_id, subject))

    async def aclose(self) -> None:
        return None


class FakeLibrary:
    """A library that records the entries it was asked to hold."""

    def __init__(self, *, unavailable: bool = False) -> None:
        self.held: list[str] = []
        self.unavailable = unavailable

    async def hold(self, entry_id: str) -> None:
        if self.unavailable:
            raise LibraryUnavailableError("The shared library is unreachable.")
        self.held.append(entry_id)

    async def aclose(self) -> None:
        return None


@dataclass
class Rig:
    """The service under test with the doubles it was built from."""

    service: FeedbackService
    store: InMemoryFeedbackStore
    lookups: FakeLookupDirectory
    library: FakeLibrary
    records: dict[tuple[str, str], LookupRecord] = field(default_factory=dict)


def rig(
    records: dict[tuple[str, str], LookupRecord] | None = None,
    *,
    lookup_unavailable: bool = False,
    library_unavailable: bool = False,
    threshold: int = 3,
) -> Rig:
    """Wire the service with a fake directory and library."""

    resolved = dict(records or {})
    lookups = FakeLookupDirectory(resolved, unavailable=lookup_unavailable)
    library = FakeLibrary(unavailable=library_unavailable)
    store = InMemoryFeedbackStore()
    service = FeedbackService(
        store=store,
        lookups=lookups,
        library=library,
        negative_feedback_threshold=threshold,
    )
    return Rig(
        service=service,
        store=store,
        lookups=lookups,
        library=library,
        records=resolved,
    )


def word_lookup(
    lookup_id: str = "lk_1",
    *,
    entries: tuple[str, ...] = ("le_1",),
    subjects: tuple[str, ...] = (SUBJECT,),
    status: LookupStatus = LookupStatus.SERVED,
) -> dict[tuple[str, str], LookupRecord]:
    """The lookup map for a word lookup that served the given entries.

    A record is made for each subject, so a test can have several readers look at
    the same lookup.
    """

    return {
        (lookup_id, subject): LookupRecord(
            lookup_id=lookup_id,
            kind=LookupKind.WORD,
            status=status,
            served_entry_ids=entries,
        )
        for subject in subjects
    }


def phrase_lookup(
    lookup_id: str = "lk_1",
    *,
    subjects: tuple[str, ...] = (SUBJECT,),
    status: LookupStatus = LookupStatus.GENERATING,
) -> dict[tuple[str, str], LookupRecord]:
    """The lookup map for a phrase lookup; it never carries a shared entry."""

    return {
        (lookup_id, subject): LookupRecord(
            lookup_id=lookup_id,
            kind=LookupKind.PHRASE,
            status=status,
            served_entry_ids=(),
        )
        for subject in subjects
    }


def make_client(
    *,
    service: FeedbackService | None = None,
    settings: Settings | None = None,
    rate_limit: int = 120,
) -> TestClient:
    """A client for the service with the dev verifier and a frozen-clock limiter."""

    resolved_settings = settings or Settings()
    resolved_service = service or rig().service
    return TestClient(
        create_app(
            settings=resolved_settings,
            service=resolved_service,
            limiter=InMemoryFixedWindowRateLimiter(
                limit=rate_limit, window_seconds=60, clock=lambda: 0.0
            ),
        )
    )


def feedback_body(**overrides: object) -> dict[str, object]:
    """A valid `feedback` body, with any field overridden."""

    body: dict[str, object] = {
        "lookupId": "lk_1",
        "rating": "helpful",
        "clientFeedbackId": "cf_1",
    }
    body.update(overrides)
    return body


def report_body(**overrides: object) -> dict[str, object]:
    """A valid `reports` body, with any field overridden."""

    body: dict[str, object] = {
        "lookupId": "lk_1",
        "reason": "wrong_meaning",
        "note": None,
        "clientReportId": "cr_1",
    }
    body.update(overrides)
    return body
