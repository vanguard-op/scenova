"""Generation lifecycle events (`analytics.md` "Event Taxonomy", EVT-007 to EVT-009).

These three events are emitted service-side: only the pipeline knows the model
version, the cost, and the duration, so the client cannot report them. Each event
is written as one structured JSON log line whose `event` field is the taxonomy's
wire name. That is the signal the reliability metric matches (`generation_failed`,
`release.md` "Rollback & Roll-forward") and what "Error & Performance Monitoring"
uses to attribute a failure to the provider or the phrase.

The reader's selected word or gloss phrase is never part of an event: a
generation event carries the taxonomy's key properties and opaque identifiers
only. `properties` is bounded to that event's key-property set, so a call site
cannot drift into free text, which is where personal data would leak in.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal, Protocol

logger = logging.getLogger(__name__)

GenerationEventName = Literal["generation_started", "generation_completed", "generation_failed"]

GENERATION_STARTED: GenerationEventName = "generation_started"
GENERATION_COMPLETED: GenerationEventName = "generation_completed"
GENERATION_FAILED: GenerationEventName = "generation_failed"

# The taxonomy's "Key properties" column for each generation event, and the only
# keys an event of that name may carry.
KEY_PROPERTIES: dict[GenerationEventName, frozenset[str]] = {
    GENERATION_STARTED: frozenset({"kind", "model_version"}),
    GENERATION_COMPLETED: frozenset({"model_version", "duration_ms", "cost_units", "resolution"}),
    GENERATION_FAILED: frozenset({"reason", "model_version"}),
}

# Why a generation ended without a clip. The provider failures and the over-cap
# output are what "Error & Performance Monitoring" attributes to the provider or
# the phrase; the cap is the pipeline withholding a clip it cannot serve.
REASON_PROVIDER_DECLINED = "provider_declined"
REASON_PROVIDER_TIMEOUT = "provider_timeout"
REASON_PROVIDER_UNAVAILABLE = "provider_unavailable"
REASON_DURATION_OVER_CAP = "duration_over_cap"
REASON_UNEXPECTED_ERROR = "unexpected_error"


@dataclass(frozen=True)
class GenerationEvent:
    """One generation lifecycle event, ready to be recorded."""

    name: GenerationEventName
    correlation_id: str
    job_id: str
    lookup_id: str
    properties: Mapping[str, object]

    def __post_init__(self) -> None:
        unknown = set(self.properties) - KEY_PROPERTIES[self.name]
        if unknown:
            raise ValueError(
                f"'{self.name}' carries properties outside the taxonomy: "
                f"{', '.join(sorted(unknown))}."
            )

    def to_log_record(self) -> dict[str, object]:
        """The structured record the log sink reads.

        The taxonomy's key properties sit at the top level beside the event name
        and the correlation identifiers, so the reliability metric can match on
        `event` and the record still ties back to the pipeline job.
        """

        return {
            "event": self.name,
            "correlation_id": self.correlation_id,
            "job_id": self.job_id,
            "lookup_id": self.lookup_id,
            **self.properties,
        }


class GenerationEventEmitter(Protocol):
    """Port for recording a generation lifecycle event."""

    def emit(self, event: GenerationEvent) -> None: ...


class LoggingGenerationEventEmitter:
    """Writes each event as one structured JSON log line.

    Cloud Logging parses the JSON message into `jsonPayload`, which is what the
    `generation_failed` log metric and its alert filter on.
    """

    def emit(self, event: GenerationEvent) -> None:
        logger.info(json.dumps(event.to_log_record(), separators=(",", ":"), sort_keys=True))


def generation_started(
    *,
    correlation_id: str,
    job_id: str,
    lookup_id: str,
    kind: str,
    model_version: str,
) -> GenerationEvent:
    """EVT-007: a generation job starts."""

    return GenerationEvent(
        name=GENERATION_STARTED,
        correlation_id=correlation_id,
        job_id=job_id,
        lookup_id=lookup_id,
        properties={"kind": kind, "model_version": model_version},
    )


def generation_completed(
    *,
    correlation_id: str,
    job_id: str,
    lookup_id: str,
    model_version: str,
    duration_ms: int,
    cost_units: float,
    resolution: str,
) -> GenerationEvent:
    """EVT-008: a generation job succeeds, with its cost and latency."""

    return GenerationEvent(
        name=GENERATION_COMPLETED,
        correlation_id=correlation_id,
        job_id=job_id,
        lookup_id=lookup_id,
        properties={
            "model_version": model_version,
            "duration_ms": duration_ms,
            "cost_units": cost_units,
            "resolution": resolution,
        },
    )


def generation_failed(
    *,
    correlation_id: str,
    job_id: str,
    lookup_id: str,
    reason: str,
    model_version: str,
) -> GenerationEvent:
    """EVT-009: a generation job fails or is declined."""

    return GenerationEvent(
        name=GENERATION_FAILED,
        correlation_id=correlation_id,
        job_id=job_id,
        lookup_id=lookup_id,
        properties={"reason": reason, "model_version": model_version},
    )
