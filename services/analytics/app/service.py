"""Event intake and the governance passes (C-007; `analytics.md` "Event Taxonomy"
and "Analytics Data Governance").

`ingest` validates a batch against the taxonomy and the personal-data scan, then
stores it. A batch is validated whole before anything is written, so an unknown
event name or a personal-data property refuses the batch rather than storing
half of it. A duplicate `event_id` is stored once, so a retried offline batch is
idempotent.

The same service exposes the two lifecycle operations the governance section
names — the fourteen-month retention pass and a data-subject deletion — so they
are exercised against the same store the intake writes to.
"""

from __future__ import annotations

import hashlib
import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from .config import Settings
from .consent import ConsentRegistry
from .errors import InvalidRequestError, PersonalDataError
from .models import EventIn, IngestRequest, IngestResponse, PropertyValue
from .personal_data import personal_data_reason
from .store import EventStore, InMemoryEventStore, StoredEvent, retention_cutoff
from .taxonomy import (
    CONSENT_EVENTS,
    CONSENT_PROPERTY,
    EventName,
    resolve_name,
    unknown_properties,
)

logger = logging.getLogger(__name__)

Clock = Callable[[], datetime]

_SAMPLE_BUCKETS = 1_000_000


@dataclass(frozen=True)
class _ValidatedEvent:
    """An event that passed taxonomy and personal-data validation."""

    event_id: str
    name: EventName
    occurred_at: datetime
    anonymous_id: str
    session_id: str
    platform: str
    app_version: str
    locale: str
    properties: dict[str, PropertyValue]


class EventService:
    """Validates and stores product events, and runs the governance passes."""

    def __init__(
        self,
        *,
        store: EventStore,
        settings: Settings,
        clock: Clock | None = None,
        consent: ConsentRegistry | None = None,
    ) -> None:
        self._store = store
        self._settings = settings
        self._clock = clock if clock is not None else _utcnow
        self._consent = consent if consent is not None else ConsentRegistry()

    async def ingest(self, request: IngestRequest, subject: str) -> IngestResponse:
        """Store a validated batch; report how many events were accepted.

        Events are processed in the order the client queued them, so a
        `consent_changed` withdrawal earlier in a batch stops the gated events
        after it.
        """

        validated = [self._validate(event) for event in request.events]
        received_at = self._clock()
        accepted = 0
        for event in validated:
            if event.name in CONSENT_EVENTS:
                self._record_consent(subject, event.properties)
            if self._suppressed(event.name, subject):
                continue
            if not self._sampled(event.event_id):
                continue
            stored = StoredEvent(
                event_id=event.event_id,
                name=event.name,
                occurred_at=event.occurred_at,
                user_id=subject,
                anonymous_id=event.anonymous_id,
                session_id=event.session_id,
                platform=event.platform,
                app_version=event.app_version,
                locale=event.locale,
                properties=event.properties,
                received_at=received_at,
                consent_gated=event.name in self._settings.consent_gated_events,
            )
            if await self._store.append(stored):
                accepted += 1
        return IngestResponse(accepted=accepted)

    async def purge_expired(self, now: datetime | None = None) -> dict[str, int]:
        """Aggregate and drop events past the retention window.

        Returns the counts that were aggregated, keyed by event name, so the
        roll-up can be recorded before the raw events go.
        """

        moment = now if now is not None else self._clock()
        cutoff = retention_cutoff(moment, self._settings.retention_months)
        aggregated = await self._store.purge_before(cutoff)
        if aggregated:
            logger.info("aggregated and dropped %d expired events", sum(aggregated.values()))
        return aggregated

    async def delete_subject(self, user_id: str) -> int:
        """Remove a subject's events for a data-subject request (NFR-040, NFR-041)."""

        return await self._store.delete_subject(user_id)

    @property
    def sample_rate(self) -> float:
        return self._settings.sample_rate

    def _validate(self, event: EventIn) -> _ValidatedEvent:
        name = resolve_name(event.name)
        occurred_at = _parse_occurred_at(event.occurredAt)
        unknown = unknown_properties(name, event.properties)
        if unknown:
            raise PersonalDataError(
                f"The event '{name.value}' carries properties outside the taxonomy: "
                f"{', '.join(sorted(unknown))}."
            )
        for key, value in event.properties.items():
            reason = personal_data_reason(key, value)
            if reason is not None:
                raise PersonalDataError(f"{reason} (event '{name.value}').")
        return _ValidatedEvent(
            event_id=event.eventId,
            name=name,
            occurred_at=occurred_at,
            anonymous_id=event.anonymousId,
            session_id=event.sessionId,
            platform=event.platform,
            app_version=event.appVersion,
            locale=event.locale,
            properties=dict(event.properties),
        )

    def _record_consent(self, subject: str, properties: dict[str, PropertyValue]) -> None:
        consent = properties.get(CONSENT_PROPERTY)
        if isinstance(consent, bool):
            self._consent.record(subject, consent)

    def _suppressed(self, name: EventName, subject: str) -> bool:
        if name not in self._settings.consent_gated_events:
            return False
        return self._consent.is_withdrawn(subject)

    def _sampled(self, event_id: str) -> bool:
        rate = self._settings.sample_rate
        if rate >= 1.0:
            return True
        if rate <= 0.0:
            return False
        digest = hashlib.sha256(event_id.encode("utf-8")).digest()
        bucket = int.from_bytes(digest[:8], "big") % _SAMPLE_BUCKETS
        return bucket < int(rate * _SAMPLE_BUCKETS)


def build_default_service(settings: Settings) -> EventService:
    """Build the intake with its in-memory store."""

    return EventService(store=InMemoryEventStore(), settings=settings)


def _parse_occurred_at(raw: str) -> datetime:
    """Parse the contract's UTC ISO-8601 timestamp, normalised to UTC."""

    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise InvalidRequestError("occurredAt is not an ISO-8601 timestamp.") from exc
    if parsed.tzinfo is None:
        raise InvalidRequestError("occurredAt must be a UTC timestamp with an offset.")
    return parsed.astimezone(UTC)


def _utcnow() -> datetime:
    return datetime.now(UTC)
