"""Shared test doubles and builders for the feedback tests."""

from __future__ import annotations

from dataclasses import dataclass, field, replace

from fastapi.testclient import TestClient

from feedback.app.api import create_app
from feedback.app.config import Settings
from feedback.app.library import (
    EntryMissingError,
    LibraryEntryView,
    LibraryUnavailableError,
)
from feedback.app.lookups import LookupRecord, LookupUnavailableError
from feedback.app.models import LookupKind, LookupStatus
from feedback.app.ratelimit import InMemoryFixedWindowRateLimiter
from feedback.app.regeneration import RegenerationUnavailableError
from feedback.app.review import ReviewService
from feedback.app.service import FeedbackService
from feedback.app.store import InMemoryFeedbackStore

AUTH = {"Authorization": "Bearer dev:reader-1"}
SUBJECT = "reader-1"
# A curator session with a second factor, as the operator gate requires
# (C-014 to C-016 auth).
OPERATOR = {"Authorization": "Bearer dev:curator:mfa:priya"}
OPERATOR_NO_ROLE = {"Authorization": "Bearer dev:priya"}
OPERATOR_NO_MFA = {"Authorization": "Bearer dev:curator:priya"}


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
    """A library that records the entries it was asked to hold and move.

    `entries` maps an entry id to the view the review surface reads; a missing key
    is an entry the library no longer holds.
    """

    def __init__(
        self,
        *,
        unavailable: bool = False,
        entries: dict[str, LibraryEntryView] | None = None,
    ) -> None:
        self.held: list[str] = []
        self.statuses: list[tuple[str, str]] = []
        self.unavailable = unavailable
        self.entries: dict[str, LibraryEntryView] = dict(entries or {})

    async def hold(self, entry_id: str) -> None:
        if self.unavailable:
            raise LibraryUnavailableError("The shared library is unreachable.")
        self.held.append(entry_id)

    async def get_entry(self, entry_id: str) -> LibraryEntryView | None:
        if self.unavailable:
            raise LibraryUnavailableError("The shared library is unreachable.")
        return self.entries.get(entry_id)

    async def set_status(self, entry_id: str, status: str) -> None:
        if self.unavailable:
            raise LibraryUnavailableError("The shared library is unreachable.")
        current = self.entries.get(entry_id)
        if current is None:
            raise EntryMissingError("The shared library holds no such entry.")
        self.statuses.append((entry_id, status))
        self.entries[entry_id] = replace(current, status=status)

    async def aclose(self) -> None:
        return None


class FakeRegeneration:
    """A generation pipeline that records the regeneration jobs it accepted."""

    def __init__(self, *, unavailable: bool = False) -> None:
        self.calls: list[tuple[str, str | None]] = []
        self.unavailable = unavailable

    async def regenerate(
        self,
        *,
        entry_id: str,
        lemma: str,
        sense_label: str,
        part_of_speech: str,
        phrase: str | None,
    ) -> None:
        if self.unavailable:
            raise RegenerationUnavailableError("The generation pipeline is unreachable.")
        self.calls.append((entry_id, phrase))

    async def aclose(self) -> None:
        return None


def entry_view(
    entry_id: str = "le_1",
    *,
    lemma: str = "come",
    sense_label: str = "arrive",
    part_of_speech: str = "verb",
    gloss_phrase: str = "to move toward a place",
    status: str = "active",
    url: str = "https://cdn.example/clip_1.mp4",
    duration_seconds: float = 3.0,
    resolution: str = "360p",
    has_audio: bool = False,
) -> LibraryEntryView:
    """A library entry as the review surface reads it."""

    return LibraryEntryView(
        entry_id=entry_id,
        lemma=lemma,
        sense_label=sense_label,
        part_of_speech=part_of_speech,
        gloss_phrase=gloss_phrase,
        status=status,
        clip_url=url,
        clip_duration_seconds=duration_seconds,
        clip_resolution=resolution,
        clip_has_audio=has_audio,
    )


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


@dataclass
class FullRig:
    """The intake and the review surface sharing one store."""

    service: FeedbackService
    review: ReviewService
    store: InMemoryFeedbackStore
    lookups: FakeLookupDirectory
    library: FakeLibrary
    regeneration: FakeRegeneration


def full_rig(
    records: dict[tuple[str, str], LookupRecord] | None = None,
    *,
    entries: dict[str, LibraryEntryView] | None = None,
    lookup_unavailable: bool = False,
    library_unavailable: bool = False,
    regeneration_unavailable: bool = False,
    threshold: int = 3,
) -> FullRig:
    """Wire the intake and the review surface on one store.

    A report recorded through the intake is immediately visible to the review
    queue, exactly as the two share the store in the deployed service.
    """

    store = InMemoryFeedbackStore()
    lookups = FakeLookupDirectory(dict(records or {}), unavailable=lookup_unavailable)
    library = FakeLibrary(unavailable=library_unavailable, entries=entries)
    regeneration = FakeRegeneration(unavailable=regeneration_unavailable)
    service = FeedbackService(
        store=store,
        lookups=lookups,
        library=library,
        negative_feedback_threshold=threshold,
    )
    review = ReviewService(store=store, library=library, regeneration=regeneration)
    return FullRig(
        service=service,
        review=review,
        store=store,
        lookups=lookups,
        library=library,
        regeneration=regeneration,
    )


def make_review_client(
    rigged: FullRig,
    *,
    settings: Settings | None = None,
    rate_limit: int = 120,
) -> TestClient:
    """A client for the intake and review surface on the rig's shared store."""

    return TestClient(
        create_app(
            settings=settings or Settings(),
            service=rigged.service,
            review_service=rigged.review,
            store=rigged.store,
            limiter=InMemoryFixedWindowRateLimiter(
                limit=rate_limit, window_seconds=60, clock=lambda: 0.0
            ),
        )
    )


def queue_body(**overrides: object) -> dict[str, object]:
    """A valid `actions` body, with any field overridden."""

    body: dict[str, object] = {
        "action": "clear",
        "phrase": None,
        "notes": None,
        "expectedState": "queued",
    }
    body.update(overrides)
    return body
