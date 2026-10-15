"""Lookup records and idempotency (schema "Lookup").

Records are held in memory for the foundations phase; the primary database
replaces this store behind the same port once persistence ships.

A lookup is personal data (schema "Lookup": `accountId`, `rawSelection`,
`normalisedLemma`), so a data-subject deletion anonymizes the reader's lookups
rather than keeping the selection beside a severed identity (nfr.md "Privacy &
Compliance"; analytics.md "Analytics Data Governance"). The record keeps its
outcome and timestamps so usage survives as an anonymized count, while the
selection and the identity that ties it to a reader are gone.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Protocol

from .models import Allowance, CreateLookupResponse, Kind, LookupResponse, LookupStatus, Sense

# The subject an anonymized lookup is left under. It is a sentinel no reader can
# hold, so ownership checks can never reattach the record to an identity.
ANONYMIZED_SUBJECT = "deleted"


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
    # The pipeline jobs this lookup is waiting on, so a poll can ask whether any
    # has stopped without a clip (C-006, FEAT-005).
    generation_job_ids: tuple[str, ...] = ()
    # The reader's allowance as it read when this lookup was made, kept so a
    # resent create replays the same body (C-001); null for a reader who is not
    # signed in.
    allowance: Allowance | None = None

    def to_response(self, correlation_id: str) -> LookupResponse:
        """The C-002 body: a lookup read by id, which carries no allowance."""

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

    def to_create_response(self, correlation_id: str) -> CreateLookupResponse:
        """The C-001 body: the lookup plus the allowance it was metered against."""

        return CreateLookupResponse(
            lookupId=self.id,
            kind=self.kind,
            rawSelection=self.raw_selection,
            normalisedLemma=self.normalised_lemma,
            status=self.status,
            senses=list(self.senses),
            notice=self.notice,
            correlationId=correlation_id,
            allowance=self.allowance,
        )


class LookupStore(Protocol):
    """Port for lookup persistence."""

    async def add(self, lookup: StoredLookup) -> None: ...

    async def get(self, lookup_id: str) -> StoredLookup | None: ...

    async def find_by_client_id(
        self, subject: str, client_lookup_id: str
    ) -> StoredLookup | None: ...

    async def anonymize_subject(self, subject: str) -> int:
        """Strip a subject's personal data from their lookups; return the count.

        The selection, the normalised lemma, and the senses that could restate
        the selection go, and the record is left under the anonymized sentinel so
        no identity is attached to it (schema "Lookup"; nfr.md "Privacy &
        Compliance"). The outcome and timestamps stay, so the reader's usage
        survives as an anonymized count.
        """
        ...


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

    async def anonymize_subject(self, subject: str) -> int:
        affected = [lookup for lookup in self._by_id.values() if lookup.subject == subject]
        for lookup in affected:
            anonymized = replace(
                lookup,
                subject=ANONYMIZED_SUBJECT,
                client_lookup_id="",
                raw_selection="",
                normalised_lemma=None,
                senses=(),
            )
            self._by_id[anonymized.id] = anonymized
            # The idempotency key belonged to the reader who made the lookup, so
            # it is dropped with them rather than left mapped to the record.
            self._by_client.pop((lookup.subject, lookup.client_lookup_id), None)
        return len(affected)
