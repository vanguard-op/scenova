"""Wire models for the analytics event intake (C-007).

The request is the contract's batch exactly: at most fifty events, each with the
common fields and a `properties` object. The pseudonymous `user_id` is not a
field — the intake takes it from the authenticated token subject, so the client
never sends an identity.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

# A taxonomy property is a scalar: an id, a count, an enum token, or a flag.
# A structured value is refused, so free text cannot be smuggled in.
PropertyValue = str | int | float | bool | None

# The contract's batch cap (`C-007`, at most fifty).
MAX_BATCH_SIZE = 50


class EventIn(BaseModel):
    """One event in the batch, as `POST /v1/events` takes it."""

    model_config = ConfigDict(extra="forbid")

    eventId: str
    name: str
    occurredAt: str
    anonymousId: str
    sessionId: str
    platform: Literal["android", "ios"]
    appVersion: str
    locale: str
    properties: dict[str, PropertyValue] = Field(default_factory=dict)


class IngestRequest(BaseModel):
    """The C-007 request body."""

    model_config = ConfigDict(extra="forbid")

    events: list[EventIn] = Field(default_factory=list, max_length=MAX_BATCH_SIZE)


class IngestResponse(BaseModel):
    """The C-007 202 response body: how many events were stored."""

    model_config = ConfigDict(extra="forbid")

    accepted: int
