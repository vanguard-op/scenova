"""Lookup records and idempotency (schema "Lookup").

Records are held in memory for the foundations phase; the primary database
replaces this store behind the same port once persistence ships.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .models import Kind, LookupResponse, LookupStatus, Sense


@dataclass(frozen=True)
class StoredLookup:
    """A lookup as recorded, rebuilt into a response per request."""

    id: str
    subject: str
    client_lookup_id: str
    raw_selection: str
    kind: Kind
    normalised_lemma: str | None
    status: LookupStatus
    senses: tuple[Sense, ...]
    notice: str | None
    created_at: str

    def to_response(self, correlation_id: str) -> LookupResponse:
        return LookupResponse(
            lookupId=self.id,
            kind=self.kind,
            rawSelection=self.raw_selection,
            normalisedLemma=self.normalised_lemma,
            status=self.status,
            senses=list(self.senses),
            notice=self.notice,
            correlationId=correlation_id,
        )


class LookupStore(Protocol):
    """Port for lookup persistence."""

    async def add(self, lookup: StoredLookup) -> None: ...

    async def get(self, lookup_id: str) -> StoredLookup | None: ...

    async def find_by_client_id(
        self, subject: str, client_lookup_id: str
    ) -> StoredLookup | None: ...


class InMemoryLookupStore:
    """An in-memory lookup store, keyed by id and by caller plus idempotency key."""

    def __init__(self) -> None:
        self._by_id: dict[str, StoredLookup] = {}
        self._by_client: dict[tuple[str, str], StoredLookup] = {}

    async def add(self, lookup: StoredLookup) -> None:
        self._by_id[lookup.id] = lookup
        self._by_client[(lookup.subject, lookup.client_lookup_id)] = lookup

    async def get(self, lookup_id: str) -> StoredLookup | None:
        return self._by_id.get(lookup_id)

    async def find_by_client_id(self, subject: str, client_lookup_id: str) -> StoredLookup | None:
        return self._by_client.get((subject, client_lookup_id))
